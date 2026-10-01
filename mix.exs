defmodule RudofElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :rudof_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "RudofElixir",
      description: "Elixir bindings for rudof: RDF, SPARQL, ShEx and SHACL.",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:rustler, "~> 0.38.0", runtime: false},
        {:ex_doc, "~> 0.38", only: :dev, runtime: false}
      ],
      docs: [main: "Rudof", extras: ["README.md", "API_COVERAGE.md", "KNOWN_ISSUES.md"]],
      package: [
        licenses: ["MIT"],
        links: %{"Upstream rudof" => "https://github.com/rudof-project/rudof"},
        files: [
          "lib",
          "livebooks",
          "scripts",
          "mix.exs",
          "README.md",
          "API_COVERAGE.md",
          "KNOWN_ISSUES.md",
          "LICENSE",
          ".formatter.exs",
          "native/rudof_nif/Cargo.toml",
          "native/rudof_nif/Cargo.lock",
          "native/rudof_nif/LICENSE-RUDOF-MIT",
          "native/rudof_nif/src"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
