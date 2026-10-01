defmodule Rudof.ConfigTest do
  use ExUnit.Case, async: true
  alias Rudof.{Error, Session}

  @settings [base_iri: "https://example.net/", rdf: [local_base: false]]
  @toml "base_iri = 'https://example.net/'\n[rdf]\nlocal_base = false\n"

  setup do
    path = Path.join(System.tmp_dir!(), "rudof-config-#{System.unique_integer([:positive])}.toml")
    File.write!(path, @toml)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "file, TOML text and nested keywords produce the same upstream settings and behavior", %{
    path: path
  } do
    configs =
      for opts <- [[path: path], [toml_str: @toml], [config: @settings]] do
        Session.with_session(
          fn session ->
            assert :ok = Session.read_data(session, "<alice> <knows> <bob> .")
            assert {:ok, rdf} = Session.serialize_data(session, :ntriples)
            assert rdf =~ "<https://example.net/alice>"
            assert {:ok, config} = Session.config(session)
            decoded = JSON.decode!(config)
            assert decoded["rdf"]["local_base"] == false
            decoded
          end,
          opts
        )
      end

    assert length(Enum.uniq(configs)) == 1
  end

  test "configuration forms also work through convenience functions", %{path: path} do
    for opts <- [[path: path], [toml_str: @toml], [config: @settings]] do
      assert {:ok, rdf} = Rudof.convert("<alice> <knows> <bob> .", :turtle, :ntriples, opts)
      assert rdf =~ "<https://example.net/alice>"
    end
  end

  test "invalid options and values return errors without starting a session", %{path: path} do
    for opts <- [
          [path: path, toml_str: @toml],
          [path: path, config: []],
          [toml_str: @toml, config: []],
          [path: path, path: path],
          [config: "base_iri = 'http://e/'"],
          [config: [base_iri: "http://e/", base_iri: "http://other/"]],
          [config: [rdf: [local_base: true, local_base: false]]],
          [config: [rdf: [local_base: :yes]]],
          [config: [base_iri: <<255>>]],
          [config: [auto_base: "yes"]],
          [config: [base_iri: nil]],
          [toml_str: "[broken"]
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = Session.new(opts)
      assert_raise Error, fn -> Session.new!(opts) end
    end

    assert {:error, %Error{message: message}} = Session.new(path: path <> ".missing")
    assert message =~ path <> ".missing"
  end

  test "configuration updates accept all forms and leave state intact on failure", %{path: path} do
    Session.with_session(fn session ->
      for opts <- [[path: path], [toml_str: @toml], [config: @settings]] do
        assert :ok = Session.update_config(session, opts)
        assert {:ok, before} = Session.config(session)
        assert JSON.decode!(before)["base_iri"] == "https://example.net/"

        assert {:error, %Error{kind: :config_error}} =
                 Session.update_config(session, config: [auto_base: "yes"])

        assert {:error, %Error{}} = Session.update_config(session, path: path <> ".missing")
        assert {:ok, ^before} = Session.config(session)
      end

      assert :ok = Session.read_data(session, "<alice> <knows> <bob> .")
      assert {:ok, rdf} = Session.serialize_data(session, :ntriples)
      assert rdf =~ "https://example.net/alice"
      assert :ok = Session.update_config(session, config: [])
      assert {:ok, config} = Session.config(session)
      refute Map.has_key?(JSON.decode!(config), "base_iri")
    end)
  end
end
