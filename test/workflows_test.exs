defmodule Rudof.WorkflowsTest do
  use ExUnit.Case, async: true
  alias Rudof.{Error, Session}

  @csv """
  shapeId,propertyId,Mandatory,Repeatable,valueDatatype,valueShape
  :Person,:name,true,false,xsd:string,
  ,:birthdate,false,false,xsd:date,
  ,:worksFor,false,true,,:Company
  :Company,:name,true,false,xsd:string,
  ,:employee,false,true,,:Person
  """
  @schema """
  PREFIX : <http://example.org/>
  PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
  :Person { :name xsd:string ; :age xsd:integer }
  """
  @shacl """
  @prefix : <http://example.org/> .
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  :PersonShape a sh:NodeShape ; sh:targetClass :Person ;
    sh:property [ sh:path :name ; sh:datatype xsd:string ; sh:minCount 1 ; sh:maxCount 1 ] .
  """
  @service """
  @prefix sd: <http://www.w3.org/ns/sparql-service-description#> .
  <#service> a sd:Service ; sd:endpoint <https://example.org/sparql> ;
    sd:supportedLanguage sd:SPARQL11Query ;
    sd:resultFormat <http://www.w3.org/ns/formats/SPARQL_Results_JSON> .
  """

  setup do
    s = Session.new!()
    on_exit(fn -> Session.close(s) end)
    %{session: s}
  end

  test "DCTAP parses, serializes, converts and validates through Rust", %{session: s} do
    assert :ok = Session.read_dctap(s, @csv)
    assert {:ok, json} = Session.serialize_dctap(s)
    assert length(JSON.decode!(json)["shapes"]) == 2
    assert {:ok, text} = Session.serialize_dctap(s, :internal)
    assert text =~ "Person"
    assert {:ok, schema} = Session.convert_schema(s, @csv, :dctap, :shex)
    data = ~S(PREFIX : <http://example.org/> :alice :name "Alice" . :bob :name 23 .)
    assert {:ok, report} = Rudof.validate_shex(data, schema, ":alice@:Person, :bob@:Person")
    refute report.conforms
    assert Enum.any?(report.entries, &(&1.node =~ "alice" and &1.status == :conformant))
    assert Enum.any?(report.entries, &(&1.node =~ "bob" and &1.status == :nonconformant))
    assert :ok = Session.reset(s, :dctap)
    assert {:error, %Error{kind: :dctap_error}} = Session.serialize_dctap(s)
    assert :ok = Session.read_dctap(s, @csv)
    assert :ok = Session.reset(s)
    assert {:error, %Error{}} = Session.serialize_dctap(s)
  end

  @tag :tmp_dir
  test "DCTAP CSV and Excel file inputs use upstream readers", %{session: s, tmp_dir: dir} do
    path = Path.join(dir, "profile.csv")
    File.write!(path, @csv)
    assert :ok = Session.read_dctap_file(s, path)
    assert {:ok, _} = Session.serialize_dctap(s)

    assert :ok =
             Session.read_dctap_file(
               s,
               Path.join(__DIR__, "fixtures/dctap_excel_profile.xlsx"),
               format: :xlsx
             )

    assert {:ok, json} = Session.serialize_dctap(s)
    assert length(JSON.decode!(json)["shapes"]) > 0
    assert {:error, %Error{kind: :dctap_error}} = Session.read_dctap_file(s, path, format: :xlsx)
    assert {:error, %Error{kind: :dctap_error}} = Session.read_dctap_file(s, path <> ".missing")
  end

  test "schema conversion supports ShEx JSON round trips and generated SPARQL", %{session: s} do
    assert {:ok, json} = Rudof.convert_schema(@schema, :shex, :shex, output_format: :shexj)
    assert JSON.decode!(json)["type"] == "Schema"
    assert {:ok, schema} = Session.convert_schema(s, json, :shex, :shex, input_format: :shexj)
    data = ~S(PREFIX : <http://example.org/> :alice :name "Alice" ; :age 42 .)
    assert {:ok, %{conforms: true}} = Rudof.validate_shex(data, schema, ":alice@:Person")

    assert {:ok, query} =
             Session.convert_schema(s, @schema, :shex, :sparql, shape: ":Person")

    assert {:ok, %{rows: [_]}} = Rudof.query(data, query)
  end

  test "SHACL converts to ShEx and preserves a simple datatype constraint" do
    assert {:ok, schema} = Rudof.convert_schema(@shacl, :shacl, :shex)

    assert {:ok, %{conforms: true}} =
             Rudof.validate_shex(
               ~S(<http://example.org/alice> <http://example.org/name> "Alice" .),
               schema,
               "<http://example.org/alice>@<http://example.org/PersonShape>"
             )

    assert {:ok, %{conforms: false}} =
             Rudof.validate_shex(
               "<http://example.org/bob> <http://example.org/name> 42 .",
               schema,
               "<http://example.org/bob>@<http://example.org/PersonShape>"
             )

    assert {:ok, turtle} = Rudof.convert_schema(@shacl, :shacl, :shacl)

    assert {:ok, %{conforms: true}} =
             Rudof.validate_shacl(
               ~S(PREFIX : <http://example.org/> :alice a :Person ; :name "Alice" .),
               turtle
             )
  end

  test "ShEx comparison reports shared and different properties", %{session: s} do
    changed = String.replace(@schema, ":age xsd:integer", ":birthDate xsd:date")
    opts = [shape1: "http://example.org/Person", shape2: "http://example.org/Person"]
    assert {:ok, json} = Session.compare_shex(s, @schema, changed, opts)
    diff = JSON.decode!(json)
    assert Map.has_key?(diff["equal_properties"], "http://example.org/name")
    assert Map.has_key?(diff["properties1"], "http://example.org/age")
    assert Map.has_key?(diff["properties2"], "http://example.org/birthDate")
    assert {:ok, same} = Rudof.compare_shex(@schema, @schema, opts)
    assert JSON.decode!(same)["properties1"] == %{}
    assert JSON.decode!(same)["properties2"] == %{}

    assert {:ok, text} =
             Session.compare_shex(s, @schema, changed, opts ++ [output_format: :internal])

    assert text =~ "name"
    assert {:ok, as_json} = Rudof.convert_schema(@schema, :shex, :shex, output_format: :shexj)
    assert {:ok, _} = Session.compare_shex(s, as_json, changed, opts ++ [format1: :shexj])
  end

  test "service descriptions serialize as JSON, MIE and text, and reset independently", %{
    session: s
  } do
    assert :ok = Session.read_data(s, "<http://e/s> <http://e/p> 1 .")
    assert :ok = Session.read_service_description(s, @service, base: "https://example.org/")
    assert {:ok, json} = Session.serialize_service_description(s)
    assert JSON.decode!(json)["endpoint"] == "https://example.org/sparql"
    assert JSON.decode!(json)["supported_language"] == ["SPARQL11Query"]
    assert {:ok, mie} = Session.serialize_service_description(s, :mie)
    assert JSON.decode!(mie)["schema_info"]["endpoint"] == "https://example.org/sparql"
    assert {:ok, _} = Session.serialize_service_description(s, :internal)
    assert :ok = Session.reset(s, :service_description)
    assert {:error, %Error{kind: :data_error}} = Session.serialize_service_description(s)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
    assert :ok = Session.read_service_description(s, @service)
    assert :ok = Session.reset(s)
    assert {:error, %Error{}} = Session.serialize_service_description(s)
  end

  @tag :tmp_dir
  test "generation writes parseable RDF and delegates schema conformance", %{
    session: s,
    tmp_dir: dir
  } do
    schema = Path.join(dir, "person.shex")
    output = Path.join(dir, "people.ttl")
    File.write!(schema, @schema)

    assert :ok =
             Session.generate(s, schema, output,
               entities: 3,
               seed: 42,
               parallel: 1,
               config_file: nil
             )

    data = File.read!(output)

    assert {:ok, %{rows: people}} =
             Rudof.query(
               data,
               "SELECT ?s WHERE { ?s a <http://example.org/Person> }"
             )

    assert length(people) == 3
    shapemap = Enum.map_join(people, ",", fn [node] -> node <> "@<http://example.org/Person>" end)
    assert {:ok, %{conforms: true}} = Rudof.validate_shex(data, @schema, shapemap)
    assert File.regular?(Path.join(dir, "people.stats.json"))
    assert {:error, %Error{kind: :data_error}} = Session.query(s, "ASK { ?s ?p ?o }")
  end

  @tag :tmp_dir
  test "generation accepts SHACL and TOML/JSON config with explicit overrides", %{tmp_dir: dir} do
    schema = Path.join(dir, "person.ttl")
    File.write!(schema, @shacl)

    for {extension, config} <- [
          {"toml", "[generation]\nentity_count = 2\n[output]\nwrite_stats = false\n"},
          {"json", ~S({"generation":{"entity_count":2},"output":{"write_stats":false}})}
        ] do
      config_path = Path.join(dir, "config." <> extension)
      output = Path.join(dir, extension <> ".nt")
      File.write!(config_path, config)

      assert :ok =
               Rudof.generate(schema, output,
                 schema_format: :shacl,
                 output_format: :ntriples,
                 config_file: config_path,
                 entities: nil,
                 seed: 0,
                 parallel: 1
               )

      data = File.read!(output)

      assert {:ok, %{rows: rows}} =
               Rudof.query(
                 data,
                 "SELECT DISTINCT ?s WHERE { ?s a <http://example.org/Person> ; <http://example.org/name> ?name }",
                 data_format: :ntriples
               )

      assert length(rows) == 2
      assert {:ok, %{conforms: true}} = Rudof.validate_shacl(data, @shacl, data_format: :ntriples)
      refute File.exists?(Path.join(dir, extension <> ".stats.json"))

      assert :ok =
               Rudof.generate(schema, output,
                 entities: 1,
                 config_file: config_path,
                 output_format: :ntriples,
                 parallel: 1
               )

      assert {:ok, %{rows: [_]}} =
               Rudof.query(
                 File.read!(output),
                 "SELECT ?s WHERE { ?s <http://example.org/name> ?name }",
                 data_format: :ntriples
               )
    end
  end

  test "invalid options and native errors leave the session usable", %{session: s} do
    for result <- [
          Session.convert_schema(s, "bad", :shex, :shex),
          Session.compare_shex(s, "bad", @schema),
          Session.read_service_description(s, "not RDF"),
          Session.generate(s, "/missing.shex", "/tmp/unused-rudof-output.ttl")
        ] do
      assert {:error, %Error{kind: kind}} = result

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
    end

    for opts <- [
          [entities: 0],
          [parallel: -1],
          [seed: -1],
          [seed: 18_446_744_073_709_551_616],
          [entities: 1.0],
          [output_format: :jsonld],
          [unknown: true]
        ] do
      assert {:error, %Error{kind: :invalid_argument}} =
               Session.generate(s, "in.shex", "out.ttl", opts)
    end

    assert {:error, %Error{kind: :invalid_argument}} =
             Session.convert_schema(s, @schema, :shex, :mermaid)

    assert {:error, %Error{kind: :invalid_argument}} =
             Session.compare_shex(s, @schema, @schema, format1: :turtle)

    assert {:error, %Error{kind: :invalid_argument}} =
             Session.read_dctap_file(s, "file", base: "http://e/")

    assert {:error, %Error{kind: :invalid_argument}} = Rudof.generate("a", "b", nil)

    for result <- [
          Session.convert_schema(s, {:string, @schema}, :shex, :shex),
          Session.compare_shex(s, @schema, {:string, @schema}),
          Session.check_shex(s, {:string, @schema}),
          Session.generate(s, {:file, "in.shex"}, "out.ttl"),
          Session.generate(s, "in.shex", "out.ttl", output: "override.ttl"),
          Session.compile_shex_to_file(s, nil)
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = result
    end

    assert {:ok, "0.3.24"} = Session.version(s)
  end

  test "endpoint queries use Rust HTTP and resetting restores local data", %{session: s} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)

    http =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 10_000)

        body =
          ~S({"head":{"vars":["name"]},"results":{"bindings":[{"name":{"type":"literal","value":"Alice"}}]}})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/sparql-results+json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
              body
          )

        :gen_tcp.close(socket)
        request
      end)

    assert :ok = Session.read_endpoint(s, "http://127.0.0.1:#{port}/sparql")

    assert {:ok, %{variables: ["name"], rows: [[~s("Alice")]]}} =
             Session.query(
               s,
               "SELECT ?name WHERE { ?s <http://example.org/name> ?name }"
             )

    assert Task.await(http) =~ "/sparql"
    assert {:ok, endpoints} = Session.list_endpoints(s)
    assert is_list(endpoints)
    assert :ok = Session.reset(s, :data)
    assert :ok = Session.read_data(s, "<http://e/s> <http://e/p> 1 .")
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
  end
end
