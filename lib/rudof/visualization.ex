defmodule Rudof.Visualization do
  @moduledoc """
  Adapts Rudof output and query results for Elixir visualization tools.

  Rudof's PlantUML serializers remain the source of diagram content. This module
  translates the RDF graph and ShEx/UML PlantUML forms currently emitted by
  upstream into Mermaid, which Livebook can display directly. It intentionally
  does not implement a general PlantUML parser.
  """

  alias Rudof.{Error, Session}

  @doc """
  Converts a SELECT result into rows of maps for table renderers such as Kino.

  The query result stays in the shape returned by `Rudof.Session.query/2`;
  this only adapts its variables and rows for consumers that expect maps.
  """
  def table_data(%{kind: :select, variables: variables, rows: rows}) do
    Enum.map(rows, &Map.new(Enum.zip(variables, &1)))
  end

  @doc """
  Serializes a session's RDF graph with Rudof and adapts the PlantUML to Mermaid.

  Serialization remains delegated to the native Rudof API. The returned
  Mermaid source can be passed directly to a renderer such as `Kino.Mermaid`.
  """
  def data_to_mermaid(session) do
    with {:ok, plantuml} <- Session.serialize_data(session, :plantuml),
         {:ok, diagram} <- plantuml_to_mermaid(plantuml) do
      {:ok, diagram}
    end
  end

  @doc """
  Translates supported Rudof RDF, RDF-star and ShEx PlantUML output to Mermaid.

  This is a focused adapter for the PlantUML forms Rudof currently emits in
  these tutorials, not a general PlantUML parser. Unsupported input returns a
  `Rudof.Error` with kind `:unsupported_operation`.
  """
  def plantuml_to_mermaid(plantuml) when is_binary(plantuml) do
    lines =
      plantuml
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    diagram =
      if rdf_plantuml?(lines),
        do: rdf_plantuml_to_mermaid(lines),
        else: schema_plantuml_to_mermaid(lines)

    {:ok, diagram}
  rescue
    error in ArgumentError ->
      {:error, %Error{kind: :unsupported_operation, message: Exception.message(error)}}
  end

  def plantuml_to_mermaid(_plantuml) do
    {:error, %Error{kind: :unsupported_operation, message: "PlantUML input must be a string"}}
  end

  defp rdf_plantuml?(lines),
    do: Enum.any?(lines, &String.starts_with?(&1, ["rectangle ", "cloud "]))

  defp rdf_plantuml_to_mermaid(lines) do
    {nodes, edges, in_style} = Enum.reduce(lines, {[], [], false}, &parse_rdf_plantuml_line/2)
    if in_style, do: raise(ArgumentError, "incomplete RDF PlantUML style block")

    node_ids = MapSet.new(Enum.map(nodes, &elem(&1, 0)))

    if MapSet.size(node_ids) != length(nodes),
      do: raise(ArgumentError, "duplicate RDF PlantUML node")

    Enum.each(edges, fn {from, to, _label, _kind} ->
      unless MapSet.member?(node_ids, from) and MapSet.member?(node_ids, to),
        do: raise(ArgumentError, "RDF PlantUML relation references an unknown node")
    end)

    node_lines =
      nodes
      |> Enum.reverse()
      |> Enum.map(fn {id, label, kind} ->
        shape =
          case kind do
            "literal" -> "[\"#{escape(label)}\"]"
            "asserted" -> "([\"annotated statement\"])"
            "non_asserted" -> "([\"quoted triple\"])"
            _ -> "([\"#{escape(label)}\"])"
          end

        "  n#{id}#{shape}"
      end)

    edge_lines =
      edges
      |> Enum.reverse()
      |> Enum.map(fn {from, to, label, kind} ->
        arrow = if kind == :component, do: "-.->", else: "-->"
        "  n#{from} #{arrow}|\"#{escape(label)}\"| n#{to}"
      end)

    Enum.join(["flowchart LR" | node_lines ++ edge_lines], "\n")
  end

  defp parse_rdf_plantuml_line("@startuml", state), do: state
  defp parse_rdf_plantuml_line("@enduml", state), do: state
  defp parse_rdf_plantuml_line("<style>", {nodes, edges, _}), do: {nodes, edges, true}
  defp parse_rdf_plantuml_line("</style>", {nodes, edges, _}), do: {nodes, edges, false}
  defp parse_rdf_plantuml_line("hide stereotype", state), do: state
  defp parse_rdf_plantuml_line(_style, {nodes, edges, true}), do: {nodes, edges, true}

  defp parse_rdf_plantuml_line(line, {nodes, edges, false}) do
    cond do
      Regex.match?(
        ~r/^rectangle \"(.*)\" <<(uri|literal|bnode|reifier|asserted)>> as (\d+)$/,
        line
      ) ->
        [_, raw_label, kind, id] =
          Regex.run(
            ~r/^rectangle \"(.*)\" <<(uri|literal|bnode|reifier|asserted)>> as (\d+)$/,
            line
          )

        {[{id, rdf_node_label(raw_label, kind), kind} | nodes], edges, false}

      Regex.match?(~r/^cloud \".*\" <<(asserted|non_asserted)>> as (\d+)$/, line) ->
        [_, kind, id] = Regex.run(~r/^cloud \".*\" <<(asserted|non_asserted)>> as (\d+)$/, line)
        label = if kind == "asserted", do: "annotated statement", else: "quoted triple"
        {[{id, label, kind} | nodes], edges, false}

      Regex.match?(~r/^(\d+) --> (\d+) : \[\[(.+)\]\]$/, line) ->
        [_, from, to, label] = Regex.run(~r/^(\d+) --> (\d+) : \[\[(.+)\]\]$/, line)
        {nodes, [{from, to, link_label(label), :asserted} | edges], false}

      Regex.match?(
        ~r/^(\d+)-->(\d+) #line:(?:blue|red|green);line\.dashed;text:(?:blue|red|green) : (subj|pred|obj)$/,
        line
      ) ->
        [_, from, to, role] =
          Regex.run(
            ~r/^(\d+)-->(\d+) #line:(?:blue|red|green);line\.dashed;text:(?:blue|red|green) : (subj|pred|obj)$/,
            line
          )

        role = %{"subj" => "subject", "pred" => "predicate", "obj" => "object"}[role]
        {nodes, [{from, to, role, :component} | edges], false}

      true ->
        raise ArgumentError, "unsupported RDF PlantUML line: #{line}"
    end
  end

  defp rdf_node_label(_raw, "bnode"), do: "blank node"

  defp rdf_node_label(raw, _kind) do
    case Regex.run(~r/^\[\[(.*)\]\]$/, raw) do
      [_, label] -> link_label(label)
      _ -> raw
    end
  end

  defp schema_plantuml_to_mermaid(lines) do
    {classes, relations} =
      lines
      |> Enum.reduce({[], [], nil, false}, &parse_plantuml_line/2)
      |> finish_plantuml()

    class_names = Map.new(classes, &{&1.id, &1.name})

    class_lines =
      Enum.flat_map(classes, fn %{name: name, fields: fields} ->
        case fields do
          [] -> ["  class #{name}"]
          _ -> ["  class #{name} {"] ++ Enum.map(fields, &"    #{&1}") ++ ["  }"]
        end
      end)

    relation_lines =
      Enum.map(relations, fn {from, cardinality, to, label} ->
        cardinality = if cardinality == "*", do: "0..*", else: "1"
        "  #{class_names[from]} --> \"#{cardinality}\" #{class_names[to]} : #{label}"
      end)

    Enum.join(["classDiagram" | class_lines ++ relation_lines], "\n")
  end

  defp parse_plantuml_line("@startuml", state), do: state
  defp parse_plantuml_line("@enduml", state), do: state
  defp parse_plantuml_line("hide empty members", state), do: state
  defp parse_plantuml_line("top to bottom direction", state), do: state
  defp parse_plantuml_line("hide circles", state), do: state
  defp parse_plantuml_line("skinparam shadowing true", state), do: state

  defp parse_plantuml_line("skinparam class {", {classes, relations, current, _}),
    do: {classes, relations, current, true}

  defp parse_plantuml_line("}", {classes, relations, current, true}),
    do: {classes, relations, current, false}

  defp parse_plantuml_line(_style, {classes, relations, current, true}),
    do: {classes, relations, current, true}

  defp parse_plantuml_line("}", {classes, relations, {name, id, fields}, false}),
    do: {[%{name: name, id: id, fields: Enum.reverse(fields)} | classes], relations, nil, false}

  defp parse_plantuml_line(line, {classes, relations, nil, false}) do
    cond do
      Regex.match?(~r/^class ":([^\"]+)" as (\d+) .+ \{$/, line) ->
        [_, name, id] = Regex.run(~r/^class ":([^\"]+)" as (\d+) .+ \{$/, line)
        {classes, relations, {name, id, []}, false}

      Regex.match?(~r/^(\d+) --> "([^"]*)" (\d+) : \[\[.*\s([^\]\s]+)\]\]$/, line) ->
        [_, from, cardinality, to, label] =
          Regex.run(~r/^(\d+) --> "([^"]*)" (\d+) : \[\[.*\s([^\]\s]+)\]\]$/, line)

        {classes, [{from, String.trim(cardinality), to, link_label(label)} | relations], nil,
         false}

      true ->
        raise ArgumentError, "unsupported PlantUML line: #{line}"
    end
  end

  defp parse_plantuml_line("--", {classes, relations, current, false}),
    do: {classes, relations, current, false}

  defp parse_plantuml_line(line, {classes, relations, {name, id, fields}, false}) do
    case Regex.run(~r/^\[\[(.+)\]\]\s*:\s*\[\[(.+)\]\](\s+\?)?$/, line) do
      [_, property, datatype, optional] ->
        property = property |> link_label() |> mermaid_identifier()
        datatype = datatype |> link_label() |> mermaid_identifier()
        suffix = if String.trim(optional) == "?", do: "_optional", else: ""
        {classes, relations, {name, id, ["#{property} #{datatype}#{suffix}" | fields]}, false}

      [_, property, datatype] ->
        property = property |> link_label() |> mermaid_identifier()
        datatype = datatype |> link_label() |> mermaid_identifier()
        {classes, relations, {name, id, ["#{property} #{datatype}" | fields]}, false}

      _ ->
        raise ArgumentError, "unsupported PlantUML class member: #{line}"
    end
  end

  defp finish_plantuml({classes, relations, nil, false}) when classes != [] do
    classes = Enum.reverse(classes)
    ids = MapSet.new(Enum.map(classes, & &1.id))

    Enum.each(relations, fn {from, _, to, _} ->
      unless MapSet.member?(ids, from) and MapSet.member?(ids, to),
        do: raise(ArgumentError, "PlantUML relation references an unknown class")
    end)

    {classes, Enum.reverse(relations)}
  end

  defp finish_plantuml(_), do: raise(ArgumentError, "incomplete or unsupported PlantUML diagram")

  defp link_label(link), do: link |> String.split() |> List.last() |> String.trim_leading(":")

  defp mermaid_identifier(identifier) do
    identifier = String.replace(identifier, ~r/[^A-Za-z0-9_]/, "_")

    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, identifier),
      do: identifier,
      else: raise(ArgumentError, "unsupported PlantUML identifier")
  end

  # Decimal entities preserve literal RDF text and prevent Markdown autolinks
  # (URLs/email) and formatting in Mermaid's HTML label renderer.
  defp escape(text) do
    text
    |> String.to_charlist()
    |> Enum.map_join(fn char ->
      if char in ~c"\"<>|&#[\\]{}.:@*_~`\n\r", do: "##{char};", else: <<char::utf8>>
    end)
  end
end
