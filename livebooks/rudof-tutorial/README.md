# Rudof in Elixir

Elixir Livebooks showcasing `rudof_elixir`: sessions, RDF data, SPARQL,
ShEx, SHACL and Mermaid diagrams. Examples are inspired by the excellent
[rudof tutorials](https://github.com/rudof-project/tutorials). Thanks to the Rudof project and tutorial
contributors for the original lessons and data!

Adapted from tutorial revision
[`7844621ea790`](https://github.com/rudof-project/tutorials/tree/7844621ea79069d3bc05977909b6e054bf7240f3)
(2026-04-14), against the wrapper's pinned rudof **0.3.24**.
The upstream [MIT license](LICENSE) is retained.

The [Livebook introduction](intro.livemd) links to every chapter in source order.
A plain Markdown index is available at [intro.md](intro.md). For an API-focused
overview, start with the parent folder's [Getting Started Livebook](../getting_started.livemd).

Original chapter headings and text-cell order are (mostly) retained. Each notebook adds
an `Introduction` section for setup and wrapper context, and closes its native
session at the end. Setup lives in Livebook's setup cell. API instructions are
adapted to `Rudof.Session`, configuration files and Elixir result maps. Livebook
diagrams use Mermaid (via the library module `Rudof.Visualization`) to visualize 
Rudof's native PlantUML output without requiring an external renderer.

## Examples

| Livebook | What it shows |
| --- | --- |
| [Short introduction to Rudof](rudof.livemd) | Initialize Rudof, then tour one-off operations, scoped sessions, validation, repair and native visualization |
| [RDF](rdf.livemd) | Triples, vocabularies, literals, blank nodes, merging, native graph visualization, formats and local plus DBpedia neighborhood queries |
| [SPARQL](sparql.livemd) | Local SELECT and CONSTRUCT, plus live Wikidata SELECT and CONSTRUCT queries |
| [ShEx](shex.livemd) | ShapeMaps, conforming and nonconforming data, Wikidata validation, and Rudof-generated Mermaid schema diagrams |
| [SHACL](shacl.livemd) | Shapes, targets and validation reports |
| [DCTAP](dctap.livemd) | CSV profiles, native ShEx conversion, validation and schema visualization |
| [RDF 1.2](rdf12.livemd) | Triple terms, reifiers and annotations |
| [SPARQL 1.2](sparql12.livemd) | Querying triple terms and OPTIONAL annotations |
| [Comparison](compare.livemd) | Structural ShEx differences and shared properties |
| [Service descriptions](service_description.livemd) | Fetch UniProt service metadata and export JSON/MIE |
| [Generation](rudof_generate.livemd) | Native ShEx/SHACL generation, TOML/JSON configuration, querying and validation |

## Run them

Open a `.livemd` in a local Livebook runtime and evaluate top to bottom. Keep
this repository's layout intact: setup installs `rudof_elixir` from the local
checkout and Kino **0.19.0**. You need Elixir 1.19+, Erlang/OTP and the Rust/C
build toolchain used by the project. Installing dependencies needs network
access. The RDF, SPARQL, ShEx and service-description chapters make the same
live requests as their upstream examples. Live requests depend on those
services being available. The original tutorials checkout is not needed.

## Checks (Advanced)

To repeat the checks, start an isolated local server with your own cookie:

```sh
mix escript.install hex livebook 0.19.9 --force
epmd -daemon
LIVEBOOK_IFRAME_PORT=8192 ~/.mix/escripts/livebook server --ip 127.0.0.1 --port 8191 \
  --name rudof_livebooks@127.0.0.1 --cookie YOUR_LOCAL_COOKIE
```

In another terminal, from the project root:

```sh
elixir --name rudof_checker@127.0.0.1 --cookie YOUR_LOCAL_COOKIE \
  scripts/check_livebooks.exs rudof_livebooks@127.0.0.1
```

The checker rejects import warnings, non-Elixir code and executable TODOs;
it evaluates fresh disposable copies of supported chapters and closes each
session. Autosaves are confined to those copies; authoritative notebooks are
never attached to checker sessions. Temporary copies are removed afterward. It uses Livebook
internals, hence the pinned version. `mix test` checks the Elixir-only notebook
structure and Mermaid escaping against the real NIF.
