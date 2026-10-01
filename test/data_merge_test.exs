defmodule Rudof.DataMergeTest do
  use ExUnit.Case, async: true
  alias Rudof.Session

  @initial "<http://e/a> <http://e/p> <http://e/old> ."
  @added "<http://e/b> <http://e/p> <http://e/new> ."
  @ask "ASK { <http://e/b> <http://e/p> <http://e/new> }"
  @select "SELECT ?o WHERE { ?s <http://e/p> ?o } ORDER BY ?o"
  @construct "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }"

  setup do
    session = Session.new!()
    on_exit(fn -> Session.close(session) end)
    %{session: session}
  end

  test "successive merges preserve RDF data and links", %{session: session} do
    for load <- [
          &Session.read_data(&1, &2),
          &Session.read_data(&1, &2, merge: true),
          &Session.load_data(&1, [&2]),
          &Session.load_data(&1, [&2], merge: true)
    ] do
      assert :ok = Session.read_data(session, @initial, merge: false)
      assert {:ok, %{rows: [["<http://e/old>"]]}} = Session.query(session, @select)
      assert :ok = load.(session, @added)

      assert {:ok, %{boolean: true}} = Session.query(session, @ask)

      assert {:ok, %{rows: [["<http://e/new>"], ["<http://e/old>"]]}} =
               Session.query(session, @select)

      assert {:ok, %{kind: :graph, graph: graph}} = Session.query(session, @construct)

      # Parse the CONSTRUCT output and check both triples; formatting and prefix
      # choices are upstream details, so do not compare serialized bytes.
      assert {:ok, %{boolean: true}} =
               Rudof.query(graph, "ASK { #{@initial} #{@added} }")
    end
  end

  test "blank nodes remain linked to their properties after more data is loaded", %{
    session: session
  } do
    source = "<http://e/a> <http://e/p> _:original . _:original <http://e/name> \"A\" ."

    query =
      "SELECT ?node ?name WHERE { <http://e/a> <http://e/p> ?node . ?node <http://e/name> ?name }"

    for query_before_merge? <- [false, true] do
      assert :ok = Session.read_data(session, source, merge: false)

      if query_before_merge? do
        assert {:ok, %{rows: [["_:original", "\"A\""]]}} = Session.query(session, query)
      end

      assert :ok = Session.read_data(session, @added, merge: true)
      assert {:ok, %{rows: [[node, "\"A\""]]}} = Session.query(session, query)
      assert String.starts_with?(node, "_:")
      assert {:ok, %{boolean: true}} = Session.query(session, @ask)
    end
  end
end
