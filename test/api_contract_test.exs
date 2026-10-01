defmodule Rudof.APIContractTest do
  use ExUnit.Case, async: true
  alias Rudof.{Error, Session}

  @data "<http://e/a> <http://e/p> <http://e/b> ."
  @schema "PREFIX : <http://e/> :S { :p IRI }"

  setup do
    s = Session.new!()
    on_exit(fn -> Session.close(s) end)
    %{session: s}
  end

  test "in-memory graph queries retain upstream Turtle output despite requested format", %{
    session: s
  } do
    :ok = Session.load_data(s, [@data])

    for query <- ["CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", "DESCRIBE <http://e/a>"],
        format <- [:rdfxml, :jsonld, :ntriples] do
      assert :ok = Session.load_sparql_query(s, query)
      assert :ok = Session.run_query(s, format: format)
      assert {:ok, %{kind: :graph, graph: graph}} = Session.query_results(s)

      assert {:ok, %{boolean: true}} =
               Rudof.query(graph, "ASK { <http://e/a> <http://e/p> <http://e/b> }",
                 data_format: :turtle
               )
    end
  end

  test "graph format reaches the endpoint Accept header", %{session: s} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, xml} = Rudof.convert(@data, :turtle, :rdfxml)

    http =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 10_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/rdf+xml\r\nContent-Length: #{byte_size(xml)}\r\nConnection: close\r\n\r\n" <>
              xml
          )

        :gen_tcp.close(socket)
        request
      end)

    assert :ok = Session.read_endpoint(s, "http://127.0.0.1:#{port}/sparql")
    assert :ok = Session.load_sparql_query(s, "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
    assert :ok = Session.run_query(s, format: :rdfxml)
    assert {:ok, %{kind: :graph, graph: ^xml}} = Session.query_results(s)
    assert String.downcase(Task.await(http)) =~ "accept: application/rdf+xml"
  end

  test "dereferencing adds returned RDF to the loaded graph", %{session: s} do
    :ok = Session.read_data(s, @data)
    assert {:ok, %{boolean: false}} = Session.query(s, "ASK { <http://e/new> ?p ?o }")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    body = "<http://e/new> <http://e/p> <http://e/b> ."

    http =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 10_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/turtle\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
              body
          )

        :gen_tcp.close(socket)
      end)

    assert :ok = Session.dereference(s, "http://127.0.0.1:#{port}/data")
    assert :ok = Task.await(http)

    assert {:ok, %{boolean: true}} =
             Session.query(s, "ASK { <http://e/new> ?p ?o . <http://e/a> ?p ?o }")
  end

  test "known unfinished comparisons return errors without closing or changing state", %{
    session: s
  } do
    :ok = Session.load_shex_schema(s, @schema)
    {:ok, before} = Session.shex_schema(s)

    for key <- [:format1, :format2], format <- [:turtle, :rdfxml, :ntriples] do
      assert {:error, %Error{kind: :unsupported_operation}} =
               Session.show_schema_comparison(s, @schema, @schema, [{key, format}])

      assert {:ok, ^before} = Session.shex_schema(s)
    end

    for key <- [:mode1, :mode2], mode <- [:shacl, :dctap, :service] do
      assert {:error, %Error{kind: :unsupported_operation}} =
               Session.show_schema_comparison(s, @schema, @schema, [{key, mode}])
    end

    assert {:ok, _} = Session.version(s)
  end

  test "all upstream ShapeMap formats are represented and unfinished ones are harmless", %{
    session: s
  } do
    :ok = Session.read_data(s, @data)
    :ok = Session.read_shex(s, @schema)
    :ok = Session.read_shapemap(s, "<http://e/a>@<http://e/S>")
    {:ok, before} = Session.serialize_shapemap(s)

    for format <- [:json, :internal, :details, :csv],
        loader <- [&Session.read_shapemap/3, &Session.load_shapemap/3] do
      assert {:error, %Error{kind: :unsupported_operation}} = loader.(s, "[]", format: format)
      assert {:ok, ^before} = Session.serialize_shapemap(s)
    end

    for format <- [:internal, :details, :csv] do
      assert {:error, %Error{kind: :unsupported_operation}} =
               Session.serialize_shapemap(s, format)

      assert {:error, %Error{kind: :unsupported_operation}} =
               Session.serialize_shapemap(s, format, show_colors: false)
    end

    assert {:ok, json} = Session.serialize_shapemap(s, :json)
    assert {:ok, _} = JSON.decode(json)
  end

  test "both loading APIs refresh queries after explicit and default merges", %{session: s} do
    # This also protects prefixes, blank-node links, and query-based shape-map
    # selection across the full Turtle round trip used to refresh the store.
    for loader <- [
          &Session.read_data(&1, &2),
          &Session.load_data(&1, [&2]),
          &Session.load_data(&1, [&2], merge: true),
          &Session.read_data(&1, &2, merge: true)
        ] do
      :ok = Session.reset_data(s)
      :ok = Session.read_data(s, @data)
      assert {:ok, %{boolean: false}} = Session.query(s, "ASK { <http://e/new> ?p ?o }")
      assert :ok = loader.(s, "@prefix ex: <http://e/> . ex:new ex:p [ ex:p ex:b ] .")

      assert {:ok, %{boolean: true}} =
               Session.query(
                 s,
                 "ASK { <http://e/new> <http://e/p> [ <http://e/p> <http://e/b> ] }"
               )

      assert {:ok, turtle} = Session.serialize_data(s)
      assert turtle =~ "ex:"
      assert {:ok, %{boolean: true}} = Session.query(s, "ASK { <http://e/a> ?p ?o }")
      :ok = Session.read_shex(s, @schema)
      :ok = Session.read_shapemap(s, "{FOCUS <http://e/p> <http://e/b>}@<http://e/S>")
      assert {:ok, %{conforms: true, entries: entries}} = Session.validate_shex(s)
      assert length(entries) == 2
    end
  end

  test "both loading APIs merge by upstream default and replace only when requested", %{
    session: s
  } do
    added = "<http://e/c> <http://e/p> 1 ."

    for load <- [&Session.read_data/3, fn s, data, opts -> Session.load_data(s, [data], opts) end] do
      assert :ok = Session.reset_data(s)
      assert :ok = load.(s, @data, [])
      assert {:ok, %{boolean: false}} = Session.query(s, "ASK { <http://e/c> ?p ?o }")
      assert :ok = load.(s, added, [])
      assert {:ok, stats} = Session.data_stats(s)
      assert JSON.decode!(stats)["triples"] == 2

      assert {:ok, %{boolean: true}} =
               Session.query(s, "ASK { <http://e/a> ?p ?old . <http://e/c> ?p ?new }")

      assert :ok = load.(s, added, merge: false)
      assert {:ok, stats} = Session.data_stats(s)
      assert JSON.decode!(stats)["triples"] == 1
      assert {:ok, %{boolean: false}} = Session.query(s, "ASK { <http://e/a> ?p ?o }")
      assert {:ok, %{boolean: true}} = Session.query(s, "ASK { <http://e/c> ?p ?o }")
    end
  end

  test "UML conversion keeps shape and timing options out of its transport", %{session: s} do
    for opts <- [[shape: ":S"], [show_time: true], [shape: ":S", show_time: true]] do
      assert {:ok, svg} =
               Session.show_schema_conversion(
                 s,
                 @schema,
                 :shex,
                 :uml,
                 [input_format: :shexc, output_format: :svg, viz_engine: :graphviz] ++ opts
               )

      assert String.starts_with?(svg, "<?xml")
      assert svg =~ "<svg"
      refute svg =~ "elapsed:"
      assert {:ok, schema} = Session.shex_schema(s)
      assert JSON.decode!(schema)["type"] == "Schema"
    end
  end
end
