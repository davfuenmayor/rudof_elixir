defmodule Rudof.PublicWorkflowsTest do
  use ExUnit.Case, async: false
  alias Rudof.{Error, Session}

  @schema "PREFIX : <http://e/> :S { :p IRI }"
  @data "<http://e/a> <http://e/p> <http://e/b> ."

  setup do
    s = Session.new!()
    on_exit(fn -> Session.close(s) end)
    %{session: s}
  end

  test "property graph loading, schema, typemap and validation are native", %{session: s} do
    pg =
      ~S|(n1 {"Student"}["name": "Alice", "age": 23]) (n2 {"Student"}["name": "Bob", "age": 12])|

    schema = "CREATE NODE TYPE (Adult: Student { name: STRING, age: INTEGER CHECK > 18 })"
    assert :ok = Session.load_data(s, [pg], format: :pg)
    assert {:ok, stats} = Session.data_stats(s)
    assert JSON.decode!(stats) == %{"kind" => "pg", "nodes" => 2, "edges" => 0}
    assert :ok = Session.load_pg_schema(s, schema)
    assert {:ok, object} = Session.pg_schema(s)
    assert {:ok, text} = Rudof.Object.text(object)
    assert text =~ "Student"
    assert :ok = Session.load_typemap(s, "n1: Adult, n2: Adult")
    assert :ok = Session.validate_pgschema(s)
    assert {:ok, json} = Session.pgschema_validation_results(s)
    report = JSON.decode!(json)
    refute report["is_valid"]
    assert length(report["associations"]) == 2
    assert {:ok, csv} = Session.serialize_pgschema_validation_results(s, :csv, show_colors: false)
    assert csv =~ "n2"
    refute csv =~ "\e["
    assert {:ok, pg_json} = Session.serialize_data(s, :json, [])
    assert {:ok, _} = JSON.decode(pg_json)
    assert {:ok, compact} = Session.serialize_pg_schema(s)
    assert compact =~ "Student"
    assert :ok = Session.reset_pg_schema_validation(s)
    assert {:ok, nil} = Session.pgschema_validation_results(s)
    assert :ok = Session.reset_typemap(s)
    assert {:error, %Error{kind: :pg_schema_error}} = Session.validate_pgschema(s)
    assert :ok = Session.reset_pg_schema(s)
    assert {:ok, nil} = Session.pg_schema(s)
    assert {:ok, _} = Rudof.Object.text(object)
  end

  test "RDF-config documents round trip through upstream YAML", %{session: s} do
    yaml = """
    - Person ex:person1:
      - a: ex:Person
      - rdfs:label:
        - name: "Alice"
    """

    assert :ok = Session.load_rdf_config(s, yaml, format: :yaml)
    assert {:ok, text} = Session.serialize_rdf_config(s)
    assert text =~ "Person"
    assert :ok = Session.load_rdf_config(s, text)
    assert {:ok, _} = Session.serialize_rdf_config(s, :internal)
    assert :ok = Session.reset_rdf_config(s)
    assert {:error, %Error{kind: :rdf_config_error}} = Session.serialize_rdf_config(s)
  end

  @tag :tmp_dir
  test "Map state from validation can be saved, loaded and materialized", %{
    session: s,
    tmp_dir: dir
  } do
    schema = """
    PREFIX : <http://e/>
    START = @:S
    :S { :p IRI %<http://shex.io/extensions/Map/>{ <http://e/value> %} }
    """

    assert :ok = Session.load_data(s, [@data])
    assert :ok = Session.load_shex_schema(s, schema)
    assert :ok = Session.add_node_shape_to_shapemap(s, "http://e/a")
    assert {:ok, %{conforms: true}} = Session.validate_shex(s)
    assert {:ok, state} = Session.serialize_map_state(s)
    assert map_size(JSON.decode!(state)) == 1
    file = Path.join(dir, "map.json")
    File.write!(file, state)
    assert :ok = Session.reset_shex_schema(s)
    assert {:error, %Error{kind: :map_state_error}} = Session.serialize_map_state(s)
    assert :ok = Session.load_shex_schema(s, schema)
    assert :ok = Session.load_map_state(s, file)

    assert {:ok, rdf} =
             Session.materialize(s, initial_node_iri: "http://e/new", format: :ntriples)

    assert rdf =~ "<http://e/new> <http://e/p> <http://e/b>"
    File.write!(file, "broken")
    assert {:error, %Error{kind: :map_state_error}} = Session.load_map_state(s, file)
  end

  @tag :tmp_dir
  test "conversion accepts Excel files and emits native SVG and PNG", %{session: s} do
    excel = Path.join(__DIR__, "fixtures/dctap_excel_profile.xlsx")

    assert {:ok, shex} =
             Session.show_schema_conversion(s, {:file, excel}, :dctap, :shex,
               input_format: :xlsx,
               output_format: :shexc
             )

    assert shex =~ "Researcher"

    assert {:ok, svg} =
             Session.show_schema_conversion(s, @schema, :shex, :uml,
               input_format: :shexc,
               output_format: :svg,
               viz_engine: :graphviz
             )

    assert svg =~ "<svg"

    assert {:ok, <<137, "PNG", _::binary>>} =
             Session.show_schema_conversion(s, @schema, :shex, :uml,
               input_format: :shexc,
               output_format: :png,
               viz_engine: :graphviz
             )
  end

  test "data and schema serializers expose native visualization options", %{session: s} do
    assert :ok = Session.load_data(s, [@data])
    assert {:ok, svg} = Session.serialize_data(s, :svg, viz_engine: :graphviz)
    assert svg =~ "<svg"
    assert :ok = Session.load_shex_schema(s, @schema)
    assert {:ok, png} = Session.serialize_shex_schema(s, :png, viz_engine: :graphviz)
    assert <<137, "PNG", _::binary>> = png

    assert {:ok, stats} =
             Session.serialize_shex_schema(s, :shexc, show_schema: false, show_statistics: true)

    assert byte_size(stats) > 0
  end

  test "native comparison accepts independent input sources and reader options", %{session: s} do
    assert {:ok, json} =
             Session.show_schema_comparison(s, {:string, @schema}, @schema,
               output_format: :json,
               reader_mode: :strict,
               shape1: "http://e/S",
               shape2: "http://e/S",
               show_time: false
             )

    assert {:ok, _} = JSON.decode(json)
  end

  @tag :tmp_dir
  test "database connect, DDL, load, query and reset use a local database", %{
    session: s,
    tmp_dir: dir
  } do
    db = Path.join(dir, "graph.db")

    data = """
    @prefix : <http://e/> .
    :alice a :Person ; :name "Alice" ; :knows :bob .
    :bob a :Person ; :name "Bob" .
    """

    assert {:ok, ddl} = Session.pg_db_ddl(s, [data], dialect: :cypher)
    assert ddl =~ "CREATE NODE TABLE"
    assert {:ok, gql} = Session.pg_db_ddl(s, [data], dialect: :gql, graph_type_name: "People")
    assert gql =~ "People"
    assert {:ok, false} = Session.has_data?(s)
    assert {:ok, info} = Session.connect_pg_db(s, db)
    assert is_integer(JSON.decode!(info)["storage_version"])
    assert {:ok, connection} = Session.pg_db_connection(s)
    assert JSON.decode!(connection)["path"] == db

    assert {:ok, {nodes, relationships, log}} =
             Session.load_pg_db(s, [data], skip_validation: true)

    assert nodes >= 2
    assert relationships >= 1
    assert log =~ "Load complete"
    assert {:ok, result} = Session.query_cypher(s, "MATCH (n) RETURN count(n) AS count")
    assert JSON.decode!(result)["rows"] == [[nodes]]
    assert :ok = Session.reset_pg_db_connection(s)
    assert {:ok, nil} = Session.pg_db_connection(s)
    assert {:error, %Error{kind: :pg_db_error}} = Session.query_cypher(s, "RETURN 1")
    assert {:ok, result} = Session.query_cypher(s, "RETURN 7 AS value", db: db, read_only: true)
    assert JSON.decode!(result)["rows"] == [[7]]
  end

  @tag :tmp_dir
  test "direct generation retains optional builder defaults", %{session: s, tmp_dir: dir} do
    schema = Path.join(dir, "schema.shex")
    output = Path.join(dir, "data.ttl")
    File.write!(schema, @schema)

    assert :ok =
             Session.generate_data(s, {:file, schema},
               output: output,
               entities: 2,
               schema_format: :shex,
               output_format: :turtle,
               seed: 42,
               parallel: 1
             )

    assert byte_size(File.read!(output)) > 0
  end

  test "URL loading and dereferencing use real local HTTP", %{session: s} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    http =
      Task.async(fn ->
        for _ <- 1..2 do
          {:ok, socket} = :gen_tcp.accept(listener, 10_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 10_000)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nContent-Length: #{byte_size(@data)}\r\nConnection: close\r\n\r\n" <>
              @data
          )

          :gen_tcp.close(socket)
          request
        end
      end)

    url = "http://127.0.0.1:#{port}/graph"
    assert :ok = Session.load_data(s, [{:url, url}], reader_mode: :strict)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
    assert :ok = Session.reset_data(s)
    assert :ok = Session.dereference(s, url, merge: false, reader_mode: :strict)
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
    assert length(Task.await(http)) == 2
  end
end
