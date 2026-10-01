defmodule RudofTest do
  use ExUnit.Case, async: true
  doctest Rudof

  alias Rudof.{Error, Session}

  @data """
  @prefix : <http://example.org/> .
  :alice :name "Alice" ; :age 42 .
  :bob :age 23 .
  """
  @shex """
  PREFIX : <http://example.org/>
  PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
  :Person { :name xsd:string ; :age xsd:integer }
  """
  @shacl """
  @prefix : <http://example.org/> .
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  :Person a sh:NodeShape ;
    sh:targetNode :alice, :bob ;
    sh:property [ sh:path :name ; sh:minCount 1 ; sh:message "Name required"@en ] .
  """

  setup do
    session = Session.new!()
    on_exit(fn -> Session.close(session) end)
    %{session: session}
  end

  test "returns the pinned upstream version", %{session: s} do
    assert {:ok, "0.3.24"} = Session.version(s)
  end

  test "reads, serializes, replaces and merges RDF", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert {:ok, nt} = Session.serialize_data(s, :ntriples)
    assert nt =~ "<http://example.org/alice>"
    assert nt =~ "Alice"

    assert :ok = Session.read_data(s, "<http://e/s> <http://e/p> 1 .", merge: false)

    assert {:ok, %{rows: [["\"1\"" <> _]]}} =
             Session.query(s, "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")

    assert :ok = Session.read_data(s, @data, merge: true)

    assert {:ok, %{rows: [["\"4\"" <> _]]}} =
             Session.query(s, "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
  end

  test "resolves relative IRIs using an explicit base", %{session: s} do
    assert :ok = Session.read_data(s, "<alice> <name> \"Alice\" .", base: "https://example.com/")
    assert {:ok, nt} = Session.serialize_data(s, :ntriples)
    assert nt =~ "<https://example.com/alice> <https://example.com/name>"
  end

  test "accepts TOML configuration and rejects malformed configuration" do
    assert {:ok, s} = Session.new(toml_str: "base_iri = 'https://example.net/'")
    assert :ok = Session.read_data(s, "<s> <p> <o> .")
    assert {:ok, nt} = Session.serialize_data(s, :ntriples)
    assert nt =~ "https://example.net/s"
    assert :ok = Session.close(s)
    assert {:error, %Error{kind: :invalid_argument} = error} = Session.new(toml_str: "[broken")
    assert error.__exception__ == true
    assert_raise Error, fn -> Session.new!(toml_str: "[broken") end
  end

  test "SELECT preserves variable order, literals, and unbound values" do
    query = """
    SELECT ?s ?name WHERE {
      ?s <http://example.org/age> ?age .
      OPTIONAL { ?s <http://example.org/name> ?name }
    } ORDER BY ?s
    """

    assert {:ok, %{kind: :select, variables: ["s", "name"], rows: [alice, bob]}} =
             Rudof.query(@data, query)

    assert ["<http://example.org/alice>", "\"Alice\""] = alice
    assert ["<http://example.org/bob>", nil] = bob
  end

  test "empty SELECT results reflect upstream's missing header" do
    assert {:ok, %{kind: :select, variables: [], rows: []}} =
             Rudof.query(@data, "SELECT ?s WHERE { ?s <http://example.org/missing> ?o }")
  end

  test "ASK supports true and false" do
    assert {:ok, %{kind: :ask, boolean: true}} = Rudof.query(@data, "ASK { ?s ?p ?o }")

    assert {:ok, %{kind: :ask, boolean: false}} =
             Rudof.query(@data, "ASK { ?s <http://e/missing> ?o }")
  end

  test "CONSTRUCT and DESCRIBE return parseable RDF" do
    for query <- [
          "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }",
          "DESCRIBE <http://example.org/alice>"
        ] do
      assert {:ok, %{kind: :graph, graph: graph}} = Rudof.query(@data, query)
      assert {:ok, %{boolean: true}} = Rudof.query(graph, "ASK { ?s ?p ?o }")
    end
  end

  test "queries use the latest data after replacement and merging", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
    assert :ok = Session.read_data(s, "<http://e/new> <http://e/p> 1 .", merge: false)
    assert {:ok, %{boolean: false}} = Session.query(s, "ASK { <http://example.org/alice> ?p ?o }")
    assert :ok = Session.read_data(s, @data, merge: true)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { <http://example.org/alice> ?p ?o }")
  end

  test "merging preserves blank node links and prefixes after querying", %{session: s} do
    assert :ok = Session.read_data(s, "@prefix : <http://e/> . :a :p [ :name \"A\" ] .")
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")

    assert :ok =
             Session.read_data(s, "@prefix : <http://e/> . :b :p [ :name \"B\" ] .", merge: true)

    assert {:ok, %{rows: [["\"A\""], ["\"B\""]]}} =
             Session.query(
               s,
               "SELECT ?name WHERE { ?s <http://e/p>/<http://e/name> ?name } ORDER BY ?name"
             )

    assert :ok = Session.read_shex(s, "PREFIX : <http://e/> :S { :p . }")
    assert :ok = Session.read_shapemap(s, ":b@:S")
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
  end

  test "native guard rejects unimplemented ShapeMap input without poisoning" do
    {:ok, ref} = Rudof.Native.new(nil)

    try do
      assert {:error, %Error{kind: :unsupported_operation}} =
               Rudof.Native.api_call(
                 ref,
                 "load_shapemap",
                 JSON.encode!(%{input: "[]", format: "json"})
               )

      assert {:ok, "0.3.24"} = Rudof.Native.version(ref)
    after
      Rudof.Native.close(ref)
    end
  end

  test "ShEx reports both conformant and nonconformant associations" do
    shapemap =
      "<http://example.org/alice>@<http://example.org/Person>, <http://example.org/bob>@<http://example.org/Person>"

    assert {:ok, %{conforms: false, entries: entries}} =
             Rudof.validate_shex(@data, @shex, shapemap)

    assert [alice, bob] = entries
    assert alice.status == :conformant
    assert bob.status == :nonconformant
    assert alice.node =~ "alice"
    assert bob.node =~ "bob"
    assert is_binary(bob.details)
  end

  test "ShEx validates an entirely conformant ShapeMap" do
    assert {:ok, %{conforms: true, entries: [_]}} =
             Rudof.validate_shex(
               @data,
               @shex,
               "<http://example.org/alice>@<http://example.org/Person>"
             )
  end

  test "ShEx query selectors resolve against RDF" do
    assert {:ok, %{conforms: false, entries: [_, _]}} =
             Rudof.validate_shex(
               @data,
               @shex,
               "{FOCUS <http://example.org/age> _}@<http://example.org/Person>"
             )
  end

  test "ShEx schemas round trip through ShExJ", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert :ok = Session.read_shex(s, @shex)
    assert {:ok, json} = Session.serialize_shex(s, :shexj)
    assert :ok = Session.read_shex(s, json, format: :shexj)

    assert :ok =
             Session.read_shapemap(s, "<http://example.org/alice>@<http://example.org/Person>")

    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
    assert {:ok, compact} = Session.serialize_shex(s)
    assert compact =~ "Person"
  end

  test "ShapeMaps round trip through compact syntax and export JSON", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert :ok = Session.read_shex(s, @shex)

    assert :ok =
             Session.read_shapemap(s, "<http://example.org/alice>@<http://example.org/Person>")

    assert {:ok, json} = Session.serialize_shapemap(s, :json)
    assert json =~ "alice"
    assert {:ok, compact} = Session.serialize_shapemap(s)
    assert :ok = Session.reset(s, :shapemap)

    assert {:error, %Error{kind: :unsupported_operation}} =
             Session.read_shapemap(s, json, format: :json)

    assert :ok = Session.read_shapemap(s, compact)
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
  end

  for mode <- [:native, :sparql] do
    test "SHACL #{mode} returns structured violations" do
      assert {:ok, %{conforms: false, results: [result]}} =
               Rudof.validate_shacl(@data, @shacl, mode: unquote(mode))

      assert result.focus_node =~ "bob"
      assert result.path =~ "name"
      assert result.constraint_component =~ "MinCount"
      assert result.severity =~ "Violation"
      assert %{lang: "en", text: "Name required"} in result.messages
    end
  end

  test "SHACL conformant report has no violations" do
    data = @data <> "<http://example.org/bob> <http://example.org/name> \"Bob\" ."
    assert {:ok, %{conforms: true, results: []}} = Rudof.validate_shacl(data, @shacl)
  end

  test "SHACL schemas round trip as RDF", %{session: s} do
    assert :ok = Session.read_shacl(s, @shacl)
    assert {:ok, nt} = Session.serialize_shacl(s, :ntriples)
    assert {:ok, %{conforms: false}} = Rudof.validate_shacl(@data, nt, shapes_format: :ntriples)
  end

  for format <- [:turtle, :ntriples, :rdfxml, :jsonld, :trig, :nquads, :n3] do
    test "RDF round trips through #{format}" do
      assert {:ok, encoded} = Rudof.convert(@data, :turtle, unquote(format))

      assert {:ok, %{boolean: true}} =
               Rudof.query(
                 encoded,
                 "ASK { <http://example.org/alice> <http://example.org/name> \"Alice\" }",
                 data_format: unquote(format)
               )
    end
  end

  test "N-Quads and TriG follow upstream's graph flattening semantics" do
    nq = "<http://e/s> <http://e/p> <http://e/o> <http://e/g> ."
    assert {:ok, trig} = Rudof.convert(nq, :nquads, :trig)

    assert {:ok, %{boolean: false}} =
             Rudof.query(trig, "ASK { GRAPH <http://e/g> { ?s ?p ?o } }", data_format: :trig)

    assert {:ok, %{boolean: true}} = Rudof.query(trig, "ASK { ?s ?p ?o }", data_format: :trig)
  end

  test "empty and malformed state produce structured errors", %{session: s} do
    for operation <- [
          fn -> Session.query(s, "ASK { ?s ?p ?o }") end,
          fn -> Session.validate_shex(s) end,
          fn -> Session.validate_shacl(s) end,
          fn -> Session.serialize_data(s) end,
          fn -> Session.read_data(s, "this is not Turtle") end,
          fn -> Session.read_shex(s, "this is not ShEx") end,
          fn -> Session.read_shacl(s, "this is not Turtle") end,
          fn -> Session.read_shapemap(s, "@@@") end
        ] do
      assert {:error, %Error{kind: kind, message: message}} = operation.()

      assert kind in [
               :data_error,
               :shex_error,
               :shacl_error,
               :shapemap_error,
               :validation_error,
               :conversion_error,
               :comparison_error,
               :service_error,
               :generate_error,
               :input_error
             ]

      assert is_binary(message) and byte_size(message) > 0
    end
  end

  test "invalid queries do not prevent later valid queries", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert {:error, %Error{kind: :query_error}} = Session.query(s, "BROKEN QUERY")
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
  end

  test "reset removes loaded state but keeps the resource usable", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert :ok = Session.reset(s)
    assert {:error, %Error{kind: :data_error}} = Session.query(s, "ASK { ?s ?p ?o }")
    assert :ok = Session.read_data(s, @data)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
  end

  test "selective reset keeps unrelated data", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    assert :ok = Session.read_shex(s, @shex)
    assert :ok = Session.reset(s, :shex)
    assert {:error, %Error{kind: :shex_error}} = Session.serialize_shex(s)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
  end

  test "close is idempotent and affects aliases", %{session: s} do
    alias_of_s = s
    assert :ok = Session.close(s)
    assert :ok = Session.close(s)
    assert {:error, %Error{kind: :closed}} = Session.version(alias_of_s)
    assert {:error, %Error{kind: :closed}} = Session.read_data(s, @data)
    assert {:error, %Error{kind: :closed}} = Session.reset(s)
  end

  test "with_session closes the handle after return or exception" do
    s = Session.with_session(& &1)
    assert {:error, %Error{kind: :closed}} = Session.version(s)

    assert_raise RuntimeError, "boom", fn ->
      Session.with_session(fn s ->
        send(self(), {:session, s})
        raise "boom"
      end)
    end

    assert_received {:session, s}
    assert {:error, %Error{kind: :closed}} = Session.version(s)
  end

  test "rejects invalid options and input before native decoding", %{session: s} do
    for operation <- [
          fn -> Session.new(config: 42) end,
          fn -> Session.read_data(s, @data, format: :unknown) end,
          fn -> Session.read_data(s, @data, merge: :yes) end,
          fn -> Session.read_data(s, @data, base: 42) end,
          fn -> Session.read_data(s, @data, formatt: :turtle) end,
          fn -> Session.read_data(s, @data, %{}) end,
          fn -> Session.read_data(s, @data, [:bad]) end,
          fn -> Session.read_data(s, <<255>>) end,
          fn -> Session.read_data(s, nil) end,
          fn -> Session.serialize_data(s, "turtle") end,
          fn -> Session.query(s, nil) end,
          fn -> Session.reset(s, :unknown) end,
          fn -> Session.validate_shacl(s, mode: :unknown) end,
          fn -> Rudof.query(@data, "ASK {}", unknown: true) end,
          fn -> Rudof.validate_shex(@data, @shex, "", schema_format: :bad) end
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = operation.()
    end
  end

  test "independent sessions do not share data", %{session: s} do
    assert :ok = Session.read_data(s, @data)

    Session.with_session(fn other ->
      assert {:error, %Error{kind: :data_error}} = Session.query(other, "ASK { ?s ?p ?o }")
    end)
  end

  test "independent one-call queries run concurrently" do
    query = fn n ->
      data = "<http://e/s> <http://e/p> #{n} ."
      Rudof.query(data, "ASK { <http://e/s> <http://e/p> #{n} }")
    end

    results =
      1..8
      |> Task.async_stream(query, max_concurrency: 4, timeout: 15_000)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{boolean: true}}}, &1))
  end

  test "concurrent calls on the same resource remain coherent", %{session: s} do
    assert :ok = Session.read_data(s, @data)

    results =
      1..24
      |> Task.async_stream(fn _ -> Session.query(s, "ASK { ?s ?p ?o }") end, max_concurrency: 8)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{kind: :ask, boolean: true}}}, &1))
  end

  test "close racing with queries returns complete results or closed errors", %{session: s} do
    assert :ok = Session.read_data(s, @data)
    tasks = for _ <- 1..16, do: Task.async(fn -> Session.query(s, "ASK { ?s ?p ?o }") end)
    assert :ok = Session.close(s)

    for task <- tasks do
      result = Task.await(task)

      assert match?({:ok, %{boolean: true}}, result) or
               match?({:error, %Error{kind: :closed}}, result)
    end
  end
end
