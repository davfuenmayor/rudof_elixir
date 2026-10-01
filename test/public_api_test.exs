defmodule Rudof.PublicAPITest do
  use ExUnit.Case, async: true
  alias Rudof.{Error, Session}

  @data "<http://e/a> <http://e/p> <http://e/b> ."
  @schema "PREFIX : <http://e/> START = @:S :S { :p IRI }"
  @shacl """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  <http://e/S> a sh:NodeShape ; sh:targetNode <http://e/a> ;
    sh:property [ sh:path <http://e/p> ; sh:minCount 1 ] .
  """

  setup do
    s = Session.new!()
    on_exit(fn -> Session.close(s) end)
    %{session: s}
  end

  test "state distinguishes absent, empty, loaded and reset data", %{session: s} do
    assert {:ok, false} = Session.has_data?(s)
    assert {:ok, nil} = Session.data_stats(s)
    assert :ok = Session.load_data(s, [""])
    assert {:ok, true} = Session.has_data?(s)
    assert stats(s) == %{"kind" => "rdf", "triples" => 0}
    assert :ok = Session.load_data(s, [@data, "<http://e/b> <http://e/p> 1 ."])
    assert stats(s)["triples"] == 2
    assert :ok = Session.reset_data(s)
    assert {:ok, false} = Session.has_data?(s)
  end

  test "query loading, execution, retrieval and granular resets are independent", %{session: s} do
    assert {:ok, false} = Session.has_sparql_query?(s)
    assert {:ok, nil} = Session.query_results(s)
    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.load_sparql_query(s, "ASK { ?s ?p ?o }", query_type: :ask)
    assert {:ok, true} = Session.has_sparql_query?(s)
    assert {:ok, nil} = Session.query_results(s)
    assert {:ok, source} = Session.serialize_sparql_query(s)
    assert source =~ "ASK"
    assert :ok = Session.run_query(s)
    assert {:ok, %{kind: :ask, boolean: true}} = Session.query_results(s)
    assert :ok = Session.reset_sparql_query(s)
    assert {:ok, false} = Session.has_sparql_query?(s)
    assert {:ok, %{boolean: true}} = Session.query_results(s)
    assert :ok = Session.load_sparql_query(s, source)
    assert :ok = Session.reset_query_results(s)
    assert {:ok, false} = Session.has_sparql_query?(s)
    assert {:ok, nil} = Session.query_results(s)
    assert {:error, %Error{kind: :query_error}} = Session.run_query(s)
  end

  @tag :tmp_dir
  test "compiled schema counts and absent ASTs reflect native state", %{session: s, tmp_dir: dir} do
    assert {:ok, nil} = Session.shex_schema(s)
    assert {:ok, nil} = Session.shex_schema_shapes_count(s)
    assert :ok = Session.load_shex_schema(s, @schema)
    assert {:ok, json} = Session.shex_schema(s)
    assert JSON.decode!(json)["type"] == "Schema"
    assert {:ok, count} = Session.shex_schema_shapes_count(s)
    assert count >= 1
    cache = Path.join(dir, "schema.bin")
    assert :ok = Session.compile_shex_schema_to_file(s, cache)
    assert {:ok, binary} = Session.serialize_shex_schema(s, :binary)
    assert binary == File.read!(cache)
    assert :ok = Session.reset_shex_schema(s)
    assert :ok = Session.load_shex_schema_precompiled(s, {:file, cache}, reader_mode: :strict)
    assert {:ok, nil} = Session.shex_schema(s)
    assert {:ok, ^count} = Session.shex_schema_shapes_count(s)
    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.add_node_shape_to_shapemap(s, "http://e/a", shape: "http://e/S")
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
  end

  test "incremental ShapeMaps validate START, prefixes and separate bases", %{session: s} do
    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.load_shex_schema(s, @schema)
    assert :ok = Session.add_node_shape_to_shapemap(s, "http://e/a")

    assert :ok =
             Session.add_node_shape_to_shapemap(s, "<a>",
               shape: "<S>",
               base_nodes: "http://e/",
               base_shapes: "http://e/"
             )

    assert {:ok, %{conforms: true, entries: entries}} = Session.validate_shex(s)
    assert length(entries) >= 1
    assert {:ok, %{conforms: true}} = Session.shex_validation_results(s)

    assert {:error, %Error{kind: :shex_error}} =
             Session.add_node_shape_to_shapemap(s, "http://e/a", iri_mode: :strict)

    assert :ok =
             Session.load_shapemap(s, "<a>@<S>",
               base_nodes: "http://e/",
               base_shapes: "http://e/"
             )

    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
    assert {:ok, csv} = Session.serialize_shex_validation_results(s, :csv, sort_by: :shape)
    assert csv =~ "S"
    assert :ok = Session.reset_shex_schema(s)
    assert {:ok, nil} = Session.shex_schema_shapes_count(s)
    assert {:ok, _} = Session.serialize_shapemap(s)
    assert {:error, %Error{}} = Session.validate_shex(s)
  end

  test "configuration replacement parses before mutation and affects subsequent reads", %{
    session: s
  } do
    assert :ok = Session.update_config(s, toml_str: "base_iri = 'http://changed/'")
    assert {:ok, before} = Session.config(s)
    assert JSON.decode!(before)["base_iri"] == "http://changed/"
    assert {:error, %Error{kind: :config_error}} = Session.update_config(s, toml_str: "[broken")
    assert {:ok, ^before} = Session.config(s)
    assert :ok = Session.load_data(s, ["<a> <p> <b> ."])
    assert {:ok, rdf} = Session.serialize_data(s, :ntriples)
    assert rdf =~ "http://changed/a"
    assert :ok = Session.reset_all(s)
    assert {:ok, ^before} = Session.config(s)
  end

  test "SHACL getter returns an owned snapshot and shape reset preserves reports", %{session: s} do
    assert {:ok, nil} = Session.shacl_shapes(s)
    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.load_shacl_shapes(s, @shacl)
    assert {:ok, object} = Session.shacl_shapes(s)
    assert object.kind == "shacl_shapes"
    assert {:ok, %{conforms: true}} = Session.validate_shacl(s)
    assert {:ok, %{conforms: true}} = Session.shacl_validation_results(s)
    assert :ok = Session.reset_shacl_shapes(s)
    assert {:ok, nil} = Session.shacl_shapes(s)
    assert {:ok, %{conforms: true}} = Session.shacl_validation_results(s)
    assert :ok = Session.close(s)
    assert {:ok, text} = Rudof.Object.text(object)
    assert text =~ "http://e/S"
    assert {:ok, _} = Rudof.Object.text(object, debug: true)
  end

  test "SHACL shapes can be loaded from the session's RDF", %{session: s} do
    assert :ok = Session.load_data(s, [@data, @shacl])
    assert :ok = Session.load_shacl_shapes(s, nil)
    assert {:ok, %{conforms: true}} = Session.validate_shacl(s)
  end

  test "options cannot override positional arguments or hide invalid values", %{session: s} do
    assert :ok = Session.load_data(s, [@data])

    for result <- [
          Session.load_data(s, [], inputs: [@data]),
          Session.load_shex_schema(s, @schema, input: @schema),
          Session.serialize_data(s, :turtle, format: :ntriples),
          Session.load_data(s, [], format: :bad, format: :turtle),
          Session.load_data(s, [], merge: false, merge: :bad)
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = result
    end

    for opts <- [nil, %{}, [:format], [{"format", :turtle}], [{:format, :turtle} | :invalid]] do
      assert {:error, %Error{kind: :invalid_argument}} = Session.load_data(s, [], opts)
    end

    assert stats(s) == %{"kind" => "rdf", "triples" => 1}
  end

  @tag :tmp_dir
  test "external resolver registry supports local schemas and clearing", %{
    session: s,
    tmp_dir: dir
  } do
    assert {:ok, json} = Session.list_external_resolvers(s)
    assert Enum.any?(JSON.decode!(json), &(&1["name"] == "schema"))
    path = Path.join(dir, "external.shex")
    File.write!(path, @schema)
    assert :ok = Session.add_external_resolver(s, "schema:" <> path)
    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.load_shex_schema(s, "PREFIX : <http://e/> :S EXTERNAL")
    assert :ok = Session.add_node_shape_to_shapemap(s, "http://e/a", shape: "http://e/S")
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
    assert :ok = Session.clear_external_resolvers(s)
    assert {:error, %Error{kind: :shex_error}} = Session.add_external_resolver(s, "unknown:kind")
    assert :ok = Session.reset_shex(s)
    assert :ok = Session.load_shex_schema(s, "PREFIX : <http://e/> :S EXTERNAL")
    assert :ok = Session.add_node_shape_to_shapemap(s, "http://e/a", shape: "http://e/S")
    assert {:ok, %{conforms: false}} = Session.validate_shex(s)
  end

  @tag :tmp_dir
  test "native file inputs and prefix inputs feed reads and queries", %{session: s, tmp_dir: dir} do
    data = Path.join(dir, "data.ttl")
    prefixes = Path.join(dir, "prefixes.ttl")
    File.write!(data, @data)
    File.write!(prefixes, "ex: <http://e/>")

    assert :ok =
             Session.load_data(s, [{:file, data}],
               prefixes: [{:file, prefixes}],
               reader_mode: :strict
             )

    assert {:ok, turtle} = Session.serialize_data(s)
    assert turtle =~ "ex:"

    assert {:ok, %{boolean: true}} =
             Session.query(s, "PREFIX ex: <http://e/> ASK { ex:a ex:p ex:b }")

    assert {:error, %Error{}} = Session.load_data(s, [{:file, Path.join(dir, "missing")}])
  end

  test "new APIs validate arguments and respect closed sessions", %{session: s} do
    for result <- [
          Session.load_data(s, [{:file, 12}]),
          Session.load_data(s, [@data], unknown: true),
          Session.load_shex_schema(s, @schema, reader_mode: :bad),
          Session.add_node_shape_to_shapemap(s, 1),
          Session.update_config(s, 1),
          Session.connect_pg_db(s, 1),
          Session.serialize_data(s, :png, viz_engine: :bad),
          Session.load_shacl_shapes(s, @shacl, opts: false)
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = result
    end

    assert {:error, %Error{kind: :unsupported_operation}} =
             Session.load_shapemap(s, "[]", format: :json)

    assert {:error, %Error{kind: :unsupported_operation}} =
             Session.show_schema_comparison(s, @shacl, @shacl, mode1: :shacl)

    assert {:ok, _} = Session.version(s)
    assert :ok = Session.close(s)
    assert {:error, %Error{kind: :closed}} = Session.has_data?(s)
    assert {:error, %Error{kind: :closed}} = Session.load_data(s, [@data])
  end

  defp stats(s) do
    {:ok, json} = Session.data_stats(s)
    JSON.decode!(json)
  end
end
