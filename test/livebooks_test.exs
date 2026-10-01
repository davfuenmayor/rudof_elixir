defmodule Rudof.LivebooksTest do
  use ExUnit.Case, async: true
  alias Rudof.Visualization

  @root Path.expand("../livebooks/rudof-tutorial", __DIR__)
  test "every notebook is native Elixir and TODO chapters contain no code" do
    notebooks =
      Path.wildcard(Path.join(@root, "*.livemd"))
      |> Enum.reject(&(Path.basename(&1) == "intro.livemd"))

    assert length(notebooks) == 11

    for path <- notebooks do
      text = File.read!(path)
      refute text =~ "/tmp/rudof-mermaid-render/", "audit capture leaked into #{path}"

      languages =
        Regex.scan(~r/^```([^\n`]+)\n/m, text, capture: :all_but_first) |> List.flatten()

      assert Enum.all?(languages, &(&1 == "elixir"))

      if String.contains?(hd(String.split(text, "\n")), "TODO") do
        assert languages == []
      else
        assert languages != []
        assert text =~ ~r/Session\.close\(\w+\)/
      end
    end
  end

  test "Livebook introduction links to each chapter" do
    intro = File.read!(Path.join(@root, "intro.livemd"))

    links =
      Regex.scan(~r/\[[^\]]+\]\(([^)]+\.livemd)\)/, intro, capture: :all_but_first)
      |> List.flatten()

    assert length(links) == 11
    assert Enum.all?(links, &File.regular?(Path.join(@root, &1)))
    assert intro =~ "https://rudof-project.github.io/tutorials/intro.html"
  end

  test "Getting Started documents the wrapper's main API behaviors" do
    path = Path.expand("../livebooks/getting_started.livemd", __DIR__)
    text = File.read!(path)
    assert String.starts_with?(text, "# Getting Started")

    languages =
      Regex.scan(~r/^```([^\n`]+)\n/m, text, capture: :all_but_first) |> List.flatten()

    assert Enum.all?(languages, &(&1 == "elixir"))
    assert text =~ "Session.new!"
    assert text =~ "toml_str:"
    assert text =~ "merge: false"
    assert text =~ "Session.with_session"
    assert text =~ "Session.close(session)"
  end

  test "RDF visualizations render Rudof's native PlantUML serialization" do
    rdf = File.read!(Path.join(@root, "rdf.livemd"))
    intro = File.read!(Path.join(@root, "rudof.livemd"))

    rdf12 = File.read!(Path.join(@root, "rdf12.livemd"))

    assert length(Regex.scan(~r/Session\.serialize_data\(rudof, :plantuml\)/, rdf)) == 8
    assert length(Regex.scan(~r/Rudof\.Visualization\.plantuml_to_mermaid\(plantuml\)/, rdf)) == 8
    assert intro =~ ~r/Session\.serialize_data\(\w+, :plantuml\)/
    assert intro =~ "Rudof.Visualization.plantuml_to_mermaid(plantuml)"
    assert length(Regex.scan(~r/Session\.serialize_data\(rudof, :plantuml\)/, rdf12)) == 5

    assert length(Regex.scan(~r/Rudof\.Visualization\.plantuml_to_mermaid\(plantuml\)/, rdf12)) ==
             5

    refute rdf =~ "Tutorial.mermaid(rudof)"
    refute rdf12 =~ "Tutorial.mermaid(rudof)"
    refute intro =~ "Tutorial.mermaid(rudof)"
  end

  test "Mermaid preserves distinct namespaces and escapes RDF literal syntax" do
    Rudof.Session.with_session(fn session ->
      assert :ok =
               Rudof.Session.read_data(session, ~S"""
               <http://one/s> <http://one/p> "A \"quote\" | [box] & <tag> #" .
               <http://two/s> <http://two/p> <http://one/s> .
               """)

      {:ok, diagram} = Visualization.data_to_mermaid(session)
      assert diagram =~ "flowchart LR"
      assert diagram =~ "http#58;//one/s"
      assert diagram =~ "http#58;//two/s"

      for escaped <- ["#34;", "#124;", "#91;box#93;", "#38;", "#60;tag#62;", "#35;"] do
        assert diagram =~ escaped
      end

      assert length(Regex.scan(~r/ -->/, diagram)) == 2
    end)
  end

  test "Mermaid URLs and email addresses stay literal rather than becoming Markdown links" do
    Rudof.Session.with_session(fn session ->
      assert :ok =
               Rudof.Session.read_data(session, ~S"""
               <http://example.org/alice> <http://example.org/email> "alice@example.org" .
               <http://example.org/alice> <http://example.org/name> "*Alice* _Smith_ `code`" .
               """)

      {:ok, diagram} = Visualization.data_to_mermaid(session)
      assert diagram =~ "#60;http#58;//example#46;org/alice#62;"
      assert diagram =~ "#60;http#58;//example#46;org/email#62;"
      assert diagram =~ "alice#64;example#46;org"
      assert diagram =~ "#42;Alice#42; #95;Smith#95; #96;code#96;"
      refute diagram =~ "http://"
      refute diagram =~ "alice@example.org"
    end)
  end

  test "native schema PlantUML becomes a Mermaid class diagram" do
    plantuml = """
    @startuml
    hide empty members
    top to bottom direction
    hide circles
    skinparam shadowing true
    skinparam class {
    BorderColor Black
    BackgroundColor LightBlue
    ArrowColor Black
    }
    class ":Person" as 1 <<(S,#FF7700)>> [[http://example.org/Person :Person]] {
    [[http://example.org/name :name]] : [[http://www.w3.org/2001/XMLSchema#string xsd:string]]
    --
    [[http://example.org/birthdate :birthdate]] : [[http://www.w3.org/2001/XMLSchema#date xsd:date]] ?
    --
    }
    class ":Company" as 2 <<(S,#FF7700)>> [[http://example.org/Company :Company]] {
    [[http://example.org/name :name]] : [[http://www.w3.org/2001/XMLSchema#string xsd:string]]
    --
    }
    1 --> "*" 2 : [[http://example.org/worksFor :worksFor]]
    @enduml
    """

    assert {:ok, diagram} = Visualization.plantuml_to_mermaid(plantuml)

    assert diagram ==
             """
             classDiagram
               class Person {
                 name xsd_string
                 birthdate xsd_date_optional
               }
               class Company {
                 name xsd_string
               }
               Person --> "0..*" Company : worksFor
             """
             |> String.trim()
  end

  test "native RDF PlantUML becomes an edge-labeled Mermaid graph" do
    Rudof.Session.with_session(fn session ->
      assert :ok =
               Rudof.Session.read_data(session, ~S"""
               prefix : <http://example.org/>
               prefix xsd: <http://www.w3.org/2001/XMLSchema#>
               :alice :email "alice@example.org" ;
                 :knows _:friend ;
                 :since "2020-01-01"^^xsd:date .
               _:friend :name "A Friend" .
               """)

      assert {:ok, plantuml} = Rudof.Session.serialize_data(session, :plantuml)
      {:ok, diagram} = Visualization.plantuml_to_mermaid(plantuml)

      assert diagram =~ "flowchart LR"
      assert diagram =~ "blank node"
      assert diagram =~ "alice#64;example#46;org"
      assert diagram =~ "A Friend"
      assert length(Regex.scan(~r/^  n\d+(?:\[|\(\[)/m, diagram)) == 5
      assert length(Regex.scan(~r/ -->\|/, diagram)) == 4
    end)
  end

  test "native RDF-star PlantUML keeps triple-term components structural" do
    Rudof.Session.with_session(fn session ->
      assert :ok =
               Rudof.Session.read_data(session, ~S"""
               prefix : <http://example.org/>
               prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
               :aliceBelief rdf:reifies <<( :bob :knows :dave )>> .
               """)

      assert {:ok, plantuml} = Rudof.Session.serialize_data(session, :plantuml)
      {:ok, diagram} = Visualization.plantuml_to_mermaid(plantuml)

      assert diagram =~ "quoted triple"
      assert diagram =~ "-.->|\"subject\"|"
      assert diagram =~ "-.->|\"predicate\"|"
      assert diagram =~ "-.->|\"object\"|"
    end)
  end

  test "SELECT results become rows of maps for data table renderers" do
    assert [%{"name" => "Alice", "email" => nil}] =
             Visualization.table_data(%{
               kind: :select,
               variables: ["name", "email"],
               rows: [["Alice", nil]]
             })
  end

  test "PlantUML outside the supported Rudof subset returns a clear error" do
    assert {:error, %Rudof.Error{kind: :unsupported_operation, message: message}} =
             Visualization.plantuml_to_mermaid("@startuml\nnote right of Foo\n@enduml")

    assert message =~ "unsupported PlantUML line"
  end
end
