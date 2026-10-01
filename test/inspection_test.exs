defmodule Rudof.InspectionTest do
  use ExUnit.Case, async: true
  alias Rudof.{Error, Session}

  @data "@prefix ex: <http://example.org/> . ex:a ex:p ex:b ; ex:q 42 . ex:c ex:p ex:a ."
  @schema "PREFIX ex: <http://example.org/> ex:S { ex:p IRI ; ex:q . }"

  setup do
    s = Session.new!()
    on_exit(fn -> Session.close(s) end)
    %{session: s}
  end

  test "prefix changes feed native parsing and preserve upstream overwrite semantics", %{
    session: s
  } do
    assert :ok = Session.add_prefix(s, "ex", "http://example.org/")
    assert :ok = Session.add_prefix(s, "ex", "http://other/")
    assert {:ok, changed} = Session.prefixes(s)
    assert {"ex", "http://other/"} in changed
    assert :ok = Session.add_prefix(s, "ex", "http://example.org/")
    assert :ok = Session.copy_prefix(s, "ex", "copy")
    assert :ok = Session.rename_prefix(s, "copy", "renamed")
    assert {:ok, prefixes} = Session.prefixes(s)
    assert {"renamed", "http://example.org/"} in prefixes
    refute List.keymember?(prefixes, "copy", 0)
    assert :ok = Session.read_data(s, "ex:a ex:p ex:b .")
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ex:a ex:p ex:b }")
    assert :ok = Session.remove_prefix(s, "renamed")
    assert {:error, %Error{kind: :prefixes_error}} = Session.remove_prefix(s, "renamed")
  end

  test "neighborhood traversal delegates direction, depth, filters and truncation", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert {:ok, %{arcs: arcs, truncated: false}} = Session.node_neighborhood(s, "ex:a")
    assert length(arcs) == 3
    assert Enum.count(arcs, &(&1.direction == :incoming)) == 1

    assert {:ok, %{arcs: [arc], truncated: false}} =
             Session.node_neighborhood(s, "ex:a", mode: :outgoing, predicates: ["ex:p"], limit: 1)

    assert arc.predicate == "http://example.org/p"
    assert arc.depth == 1
    assert arc.neighbor =~ "http://example.org/b"
    assert {:ok, %{arcs: [_], truncated: true}} = Session.node_neighborhood(s, "ex:a", limit: 1)
    assert {:ok, info} = Session.node_info(s, "ex:a", mode: :incoming)
    assert info =~ "ex:c"
    refute info =~ "\e["
    assert {:ok, %{arcs: deeper}} = Session.node_neighborhood(s, "ex:b", depth: 2)
    assert Enum.any?(deeper, &(&1.depth == 2))
  end

  test "query exports retain Rust output semantics", %{session: s} do
    assert {:error, %Error{kind: :query_error}} = Session.serialize_query_results(s)
    assert :ok = Session.read_data(s, @data)
    assert {:ok, _} = Session.query(s, "SELECT ?s WHERE { ?s <http://example.org/p> ?o }")

    for format <- [:json, :csv, :markdown, :internal] do
      assert {:ok, text} = Session.serialize_query_results(s, format)
      assert text =~ "http://example.org/a" or text =~ "ex:a"
      if format == :json, do: assert({:ok, _} = JSON.decode(text))
    end

    assert {:error, %Error{kind: :query_error}} = Session.serialize_query_results(s, :turtle)
    assert {:ok, _} = Session.query(s, "ASK { ?s ?p ?o }")
    assert {:ok, "true\n"} = Session.serialize_query_results(s)
    assert {:ok, _} = Session.query(s, "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
    assert {:ok, graph} = Session.serialize_query_results(s, :turtle)
    assert :ok = Session.read_data(s, graph)
  end

  @tag :tmp_dir
  test "ShEx checks preserve state and compiled caches validate", %{session: s, tmp_dir: dir} do
    assert :ok = Session.read_shex(s, @schema)
    assert {:ok, before} = Session.serialize_shex(s)
    assert {:ok, {true, _}} = Session.check_shex(s, @schema)
    assert {:ok, {false, message}} = Session.check_shex(s, "broken schema")
    assert byte_size(message) > 0
    assert {:ok, ^before} = Session.serialize_shex(s)
    path = Path.join(dir, "schema.cache")
    assert :ok = Session.compile_shex_to_file(s, path)
    assert :ok = Session.reset(s, :shex)
    assert :ok = Session.read_shex_precompiled(s, path)
    assert :ok = Session.read_data(s, @data)
    assert :ok = Session.read_shapemap(s, "<http://example.org/a>@<http://example.org/S>")
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)

    for format <- [:json, :csv, :compact, :details] do
      assert {:ok, text} = Session.serialize_shex_validation_results(s, format)
      assert byte_size(text) > 0
      if format == :json, do: assert({:ok, _} = JSON.decode(text))
    end

    assert :ok = Session.reset(s, :shex)
    File.write!(path, "keep me")
    assert {:error, %Error{kind: :shex_error}} = Session.compile_shex_to_file(s, path)
    assert File.read!(path) == "keep me"
    assert {:error, %Error{kind: :shex_error}} = Session.read_shex_precompiled(s, path)
  end

  @tag :tmp_dir
  test "compiled schema output reports file errors", %{session: s, tmp_dir: dir} do
    assert :ok = Session.read_shex(s, @schema)
    assert {:error, %Error{kind: :native_error}} = Session.compile_shex_to_file(s, dir)
  end

  test "SHACL exports a native RDF report", %{session: s} do
    assert :ok = Session.read_data(s, @data)

    assert :ok =
             Session.read_shacl(s, """
             @prefix sh: <http://www.w3.org/ns/shacl#> .
             <http://example.org/S> a sh:NodeShape ; sh:targetNode <http://example.org/a> ;
               sh:property [ sh:path <http://example.org/missing> ; sh:minCount 1 ] .
             """)

    assert {:ok, %{conforms: false}} = Session.validate_shacl(s)
    assert {:ok, rdf} = Session.serialize_shacl_validation_results(s)
    assert :ok = Session.read_data(s, rdf)

    assert {:ok, %{boolean: true}} =
             Session.query(s, """
             PREFIX sh: <http://www.w3.org/ns/shacl#>
             ASK { ?r a sh:ValidationReport ; sh:conforms false }
             """)

    assert {:ok, text} = Session.serialize_shacl_validation_results(s, :minimal)
    assert text =~ "Does not conform"

    assert {:error, %Error{kind: :shacl_error}} =
             Session.serialize_shacl_validation_results(s, :json)

    assert {:ok, _} = Session.version(s)
  end

  test "invalid inspection options never enter native code", %{session: s} do
    for opts <- [[depth: 0], [mode: :sideways], [predicates: [42]], [limit: 0]] do
      assert {:error, %Error{kind: :invalid_argument}} =
               Session.node_neighborhood(s, "ex:a", opts)
    end

    assert {:error, %Error{kind: :invalid_argument}} = Session.node_info(s, "ex:a", limit: 1)
    assert {:ok, _} = Session.version(s)
  end
end
