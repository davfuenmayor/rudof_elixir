# Public API coverage

Status: **2026-10-01**, against rudof **0.3.24**, pinned Rust revision
`393f45e9d79ff18abc6ed237c675e4a9f8809bcd`.

Scope: every public method on `rudof_lib::Rudof`, its public builder setters,
and the input/output types needed to call them. This is not an inventory of
all public APIs of every workspace crate. Update this file whenever a binding,
option, upstream limitation or verification status changes.

Features enabled: `sparql`, `dctap`, `conversion`, `comparison`, `rdf-config`,
`pgschema`, `pg-db`, `qlever`. Existing convenience functions remain available.
All facade bindings below are on `Rudof.Session`; names generally match Rust.
The inventory contains **87 facade methods** and **108 public setters across
37 builders**, checked against the pinned source, not a sibling checkout.
Units return `:ok`, values return `{:ok, value}`, and missing optional state
returns `{:ok, nil}`. Errors use `%Rudof.Error{}` and retain native categories.
Complex newly exposed serializable models use upstream JSON text; call
`JSON.decode/1` in the application. SHACL IR and PG schemas use immutable native
`Rudof.Object` snapshots because upstream does not implement Serde for them.

Convenience conversion, comparison, generation, schema checking and compilation
functions delegate to the same bindings as their full API counterparts. Direct
methods retain upstream defaults unless their module documentation states
otherwise; convenience helpers may choose defaults or restrict formats. For
example, `generate/4` requires an explicit output path and defaults to Turtle,
and `serialize_shex/2` accepts ShExC/ShExJ while `serialize_shex_schema/3` exposes
the broader upstream format set. Known unfinished formats are accepted by the
API and return structured errors.

## Public functions

**Implemented** means a callable binding exists, not that every input/option combination is verified; upstream restrictions and
external-runtime verification TODOs remain explicitly listed below. A combined
convenience operation does not substitute for independent method coverage.

| Public Rust method | Elixir surface | Status / semantics |
| --- | --- | --- |
| `new` | `new/1; new!/1` | Implemented. Defaults, or one of path: filename, toml_str: text, config: keywords; Rust parses configuration. Elixir owns session lifetime. Zero-argument forms are available. |
| `version` | `version/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `config` | `config/1` | Implemented. Upstream JSON; runtime-only resolver registries are omitted by Serde. |
| `update_config` | `update_config/2` | Implemented. `path`, `toml_str`, or keyword `config` → upstream RudofConfig; full replacement after successful parsing; loaded state is not rebuilt. |
| `reset_all` | `reset_all/1` | Implemented. Clears all enabled runtime subsystems; retains configuration. |
| `add_external_resolver` | `add_external_resolver/2` | Implemented. Upstream spec grammar and ordering; configure before constructing a validator. |
| `clear_external_resolvers` | `clear_external_resolvers/1` | Implemented. Restores the default reject-all registry; configure before constructing a validator. |
| `list_external_resolvers` | `list_external_resolvers/1` | Implemented. JSON catalogue of built-in kinds, not the configured chain. Session argument only for lifecycle consistency. |
| `load_data` | `load_data/3 (defaults)` | Implemented. List of native input specifications; all builder options. Both load_data/3 and read_data/3 retain upstream's merge default; explicit merge: false replaces. |
| `serialize_data` | `serialize_data/2 (defaults)` | Implemented. /2 and /3 share all native formats; /3 adds viz_engine. Binary outputs preserved. |
| `load_map_state` | `load_map_state/2` | Implemented. JSON file path, as required upstream. |
| `serialize_map_state` | `serialize_map_state/1` | Implemented. Upstream JSON text. |
| `materialize` | `materialize/2 (defaults)` | Implemented. RDF bytes from loaded schema and Map state; initial node IRI and output format. |
| `reset_data` | `reset_data/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `load_service_description` | `load_service_description/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_service_description` | `serialize_service_description/2 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_service_description` | `reset_service_description/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `show_node_info` | `show_node_info/3 (defaults)` | Implemented. All native options; node_info/3 remains an alias. |
| `node_neighborhood` | `node_neighborhood/3 (defaults)` | Implemented. All native options plus optional output limit. Traversal can allocate upstream adjacency data. |
| `list_endpoints` | `list_endpoints/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `has_data` | `has_data?/1` | Implemented. True even for an initialized empty graph. |
| `data_stats` | `data_stats/1` | Implemented. Upstream counts encoded as JSON or nil; RDF counts are local, not remote endpoint cardinality. |
| `has_sparql_query` | `has_sparql_query?/1` | Implemented. Independent of stored results. |
| `shex_schema` | `shex_schema/1` | Implemented. Source AST JSON or nil; absent for precompiled-only schemas. |
| `shex_schema_shapes_count` | `shex_schema_shapes_count/1` | Implemented. Compiled shape count including imports; available for precompiled caches. |
| `shacl_shapes` | `shacl_shapes/1` | Implemented. Owned immutable Rudof.Object snapshot; upstream Display/Debug via Object.text/2. |
| `dctap` | `dctap/1` | Implemented. Upstream JSON or nil. |
| `pg_schema` | `pg_schema/1` | Implemented. Owned immutable Rudof.Object snapshot; upstream Display/Debug via Object.text/2. |
| `service_description` | `service_description/1` | Implemented. Upstream JSON or nil. |
| `dereference` | `dereference/3 (defaults)` | Implemented. Native content negotiation/redirects, reader mode and merge. |
| `load_shex_schema` | `load_shex_schema/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `check_shex_schema` | `check_shex_schema/3 (defaults)` | Implemented. Native input → {valid?, diagnostics}; does not replace loaded schema. |
| `serialize_shex_schema` | `serialize_shex_schema/3 (defaults)` | Implemented. All public builder options; binary output preserved. |
| `reset_shex_schema` | `reset_shex_schema/1` | Implemented. Clears AST, compiled IR, validator and Map state; preserves ShapeMap and saved report. |
| `compile_shex_schema_to_file` | `compile_shex_schema_to_file/2` | Implemented. Writes binary cache; file opened only after successful native compilation. |
| `load_shex_schema_precompiled` | `load_shex_schema_precompiled/3 (defaults)` | Implemented. Native input and reader_mode; source AST is not restored. |
| `load_shapemap` | `load_shapemap/3 (defaults)` | Implemented. Separate node/shape bases; all upstream formats exposed; unfinished inputs return unsupported_operation before mutation. |
| `add_node_shape_to_shapemap` | `add_node_shape_to_shapemap/3 (defaults)` | Implemented. Incremental associations; optional shape defaults to START; strict/lax IRI normalization. |
| `serialize_shapemap` | `serialize_shapemap/2 (defaults)` | Implemented. Existing /2 helper; /3 adds show_colors; all upstream formats exposed; noncompact/non-JSON formats return unsupported_operation before mutation. |
| `reset_shapemap` | `reset_shapemap/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `validate_shex` | `validate_shex/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_shex_validation_results` | `serialize_shex_validation_results/2 (defaults)` | Implemented. /3 adds sort_by. JSON does not apply sorting upstream. |
| `shex_validation_results` | `shex_validation_results/1` | Implemented. Existing report map or nil; does not validate. |
| `shacl_validation_results` | `shacl_validation_results/1` | Implemented. Existing report map or nil; does not validate. |
| `pgschema_validation_results` | `pgschema_validation_results/1` | Implemented. Upstream JSON or nil; does not validate. |
| `reset_shex` | `reset_shex/1` | Implemented. Clears ShEx/ShapeMap validation state but retains Map state upstream. |
| `load_shacl_shapes` | `load_shacl_shapes/3 (defaults)` | Implemented. Pass nil to read embedded shapes from loaded data. |
| `serialize_shacl_shapes` | `serialize_shacl_shapes/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_shacl_shapes` | `reset_shacl_shapes/1` | Implemented. Clears shapes and preserves saved validation report. |
| `validate_shacl` | `validate_shacl/2 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_shacl_validation_results` | `serialize_shacl_validation_results/2 (defaults)` | Implemented. /3 adds sort_by, currently ignored upstream. JSON/CSV exports are unfinished upstream. |
| `reset_shacl` | `reset_shacl/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `load_sparql_query` | `load_sparql_query/3 (defaults)` | Implemented. Independent load; query_type is accepted but ignored upstream. |
| `serialize_sparql_query` | `serialize_sparql_query/1` | Implemented. Normalized query source. |
| `reset_sparql_query` | `reset_sparql_query/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `run_query` | `run_query/2 (defaults)` | Implemented and regression-tested. Independent execution; graph format is forwarded (verified against endpoint HTTP Accept). The memory backend ignores it and always emits Turtle. |
| `serialize_query_results` | `serialize_query_results/2 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_query_results` | `reset_query_results/1` | Implemented. Also clears the stored query upstream. |
| `query_results` | `query_results/1` | Implemented. Existing result map or nil; does not execute. |
| `show_schema_comparison` | `show_schema_comparison/4 (defaults)` | Implemented. All builder options; only ShExC/ShExJ comparison is implemented upstream. Other native modes/formats return unsupported_operation without closing the session. |
| `show_schema_conversion` | `show_schema_conversion/5 (defaults)` | Implemented. Native inputs including Excel; HTML directories, UML/images; all builder options. |
| `load_dctap` | `load_dctap/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_dctap` | `serialize_dctap/2 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_dctap` | `reset_dctap/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `load_rdf_config` | `load_rdf_config/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_rdf_config` | `serialize_rdf_config/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_rdf_config` | `reset_rdf_config/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `load_pg_schema` | `load_pg_schema/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_pg_schema` | `serialize_pg_schema/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_pg_schema` | `reset_pg_schema/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `load_typemap` | `load_typemap/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_typemap` | `reset_typemap/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `validate_pgschema` | `validate_pgschema/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `serialize_pgschema_validation_results` | `serialize_pgschema_validation_results/3 (defaults)` | Implemented. Direct delegation; preserves upstream behavior. |
| `reset_pg_schema_validation` | `reset_pg_schema_validation/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `connect_pg_db` | `connect_pg_db/3 (defaults)` | Implemented. Path or nil plus options; returns upstream connection info as JSON. In-memory verification is not retained upstream. |
| `pg_db_ddl` | `pg_db_ddl/3 (defaults)` | Implemented. Native RDF inputs → Cypher/GQL DDL; does not replace session data. |
| `load_pg_db` | `load_pg_db/3 (defaults)` | Implemented. All builder options; returns {nodes, relationships, diagnostics}. |
| `query_cypher` | `query_cypher/3 (defaults)` | Implemented. Native input and optional db/read_only override → upstream JSON rows/timing. |
| `reset_pg_db_connection` | `reset_pg_db_connection/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `pg_db_connection` | `pg_db_connection/1` | Implemented. Stored connection settings as JSON or nil; native connection opens per operation. |
| `generate_data` | `generate_data/3 (defaults)` | Implemented. All builder options; native input must currently be a file; omitted output uses upstream default. |
| `prefixes` | `prefixes/1` | Implemented. Direct delegation; preserves upstream behavior. |
| `add_prefix` | `add_prefix/3` | Implemented. Direct delegation; preserves upstream behavior. |
| `remove_prefix` | `remove_prefix/2` | Implemented. Direct delegation; preserves upstream behavior. |
| `rename_prefix` | `rename_prefix/3` | Implemented. Direct delegation; preserves upstream behavior. |
| `copy_prefix` | `copy_prefix/3` | Implemented. Direct delegation; preserves upstream behavior. |

## Builder options

The following are exposed by the direct methods above (usually as keyword
options without the `with_` prefix). Positional inputs/formats are noted in
module docs. Builder rows use facade method names; upstream builder filenames
may differ (for example, `load_pgschema.rs`). `reset/2` also accepts every
corresponding reset target. Generation schema format and entity count are
constructor arguments, exposed as `schema_format` and `entities`; they are not
builder setters. Database `with_db(path, read_only)` maps to `db` and `read_only`.

| Builder | Public setters | Status |
| --- | --- | --- |
| `show_schema_comparison` | `with_base1`, `with_base2`, `with_reader_mode`, `with_shape1`, `with_shape2`, `with_show_time`, `with_result_format` | Implemented; restrictions below. |
| `show_schema_conversion` | `with_base`, `with_reader_mode`, `with_shape`, `with_show_time`, `with_templates_folder`, `with_output_folder`, `with_viz_engine` | Implemented; restrictions below. |
| `dereference` | `with_reader_mode`, `with_merge` | Implemented; restrictions below. |
| `load_data` | `with_backend`, `with_endpoint_strategy`, `with_data`, `with_data_format`, `with_base`, `with_reader_mode`, `with_endpoint`, `with_merge`, `with_prefixes` | Implemented; restrictions below. |
| `load_service_description` | `with_data_format`, `with_reader_mode`, `with_base` | Implemented; restrictions below. |
| `node_neighborhood` | `with_predicates`, `with_mode`, `with_depth`, `with_iri_mode` | Implemented; restrictions below. |
| `serialize_data` | `with_result_data_format`, `with_viz_engine` | Implemented; restrictions below. |
| `serialize_service_description` | `with_result_service_format` | Implemented; restrictions below. |
| `show_node_info` | `with_predicates`, `with_show_node_mode`, `with_depth`, `with_show_hyperlinks`, `with_show_colors`, `with_iri_mode` | Implemented; restrictions below. |
| `load_dctap` | `with_dctap_format` | Implemented; restrictions below. |
| `serialize_dctap` | `with_result_dctap_format` | Implemented; restrictions below. |
| `generate_data` | `with_result_generation_format`, `with_seed`, `with_parallel`, `with_output`, `with_config_file` | Implemented; restrictions below. |
| `materialize` | `with_initial_node_iri`, `with_result_format` | Implemented; restrictions below. |
| `connect_pg_db` | `with_in_memory`, `with_read_only`, `with_engine` | Implemented; restrictions below. |
| `load_pg_db` | `with_db`, `with_shapes`, `with_shapes_format`, `with_base_shapes`, `with_skip_validation`, `with_data_format`, `with_base_data`, `with_reader_mode` | Implemented; restrictions below. |
| `pg_db_ddl` | `with_dialect`, `with_graph_type_name`, `with_data_format`, `with_base_data`, `with_reader_mode` | Implemented; restrictions below. |
| `query_cypher` | `with_db` | Implemented; restrictions below. |
| `load_pg_schema` | `with_pg_schema_format` | Implemented; restrictions below. |
| `serialize_pg_schema` | `with_result_pg_schema_format` | Implemented; restrictions below. |
| `serialize_pgschema_validation_results` | `with_result_pg_schema_validation_format`, `with_show_colors` | Implemented; restrictions below. |
| `load_sparql_query` | `with_query_type` | Implemented; restrictions below. |
| `run_query` | `with_result_query_format` | Implemented; restrictions below. |
| `serialize_query_results` | `with_result_query_format` | Implemented; restrictions below. |
| `load_rdf_config` | `with_rdf_config_format` | Implemented; restrictions below. |
| `serialize_rdf_config` | `with_result_rdf_config_format` | Implemented; restrictions below. |
| `load_shacl_shapes` | `with_shacl_schema`, `with_shacl_schema_format`, `with_base`, `with_reader_mode` | Implemented; restrictions below. |
| `serialize_shacl_shapes` | `with_shacl_result_format` | Implemented; restrictions below. |
| `serialize_shacl_validation_results` | `with_shacl_validation_sort_order_mode`, `with_result_shacl_validation_format` | Implemented; restrictions below. |
| `validate_shacl` | `with_shacl_validation_mode` | Implemented; restrictions below. |
| `add_node_shape_to_shapemap` | `with_shape`, `with_base_nodes`, `with_base_shapes`, `with_iri_mode` | Implemented; restrictions below. |
| `check_shex_schema` | `with_shex_schema_format`, `with_base` | Implemented; restrictions below. |
| `load_shapemap` | `with_shapemap_format`, `with_base_nodes`, `with_base_shapes` | Implemented; restrictions below. |
| `load_shex_schema` | `with_shex_schema_format`, `with_base`, `with_reader_mode` | Implemented; restrictions below. |
| `load_shex_schema_precompiled` | `with_reader_mode` | Implemented; restrictions below. |
| `serialize_shapemap` | `with_result_shapemap_format`, `with_show_colors` | Implemented; restrictions below. |
| `serialize_shex_schema` | `with_shape`, `with_show_schema`, `with_show_statistics`, `with_show_dependencies`, `with_show_time`, `with_result_shex_format`, `with_viz_engine` | Implemented; restrictions below. |
| `serialize_shex_validation_results` | `with_shex_validation_sort_order_mode`, `with_result_shex_validation_format` | Implemented; restrictions below. |


## Upstream and environment TODOs

- **RDF visualization subprocesses:** Graphviz SVG/PNG renders run through the
  compiled `rudof_render` helper launched by `System.cmd/3`. The helper delegates
  graph/schema generation and image rendering to upstream rudof. Snapshots contain
  clean RDF/ShExJ; UML conversion options are applied to the native conversion
  in the helper, separately from transport serialization. Selected-shape and
  timing options are regression-tested with Graphviz. PlantUML image
  rendering uses the same helper, but needs Java and the JAR selected by `PLANTUML`
  or upstream configuration. PlantUML and DCTAP-to-HTML image rendering
  remain outside the verified integration coverage.
- **Conversion limitations:** only upstream routes work. ShEx-to-SHACL and
  ShEx-to-HTML can return upstream errors; ShEx-to-HTML does not support every
  ShEx constraint. DCTAP-to-HTML needs an output directory, Java and PlantUML.
- **ShEx external resolvers:** only upstream built-in resolver spec strings are
  constructible. Registry updates apply when a validator is built; reload the
  schema after changing resolvers. Resolver callbacks from arbitrary Elixir code
  are outside the Rust API.
- **Map state:** upstream loads it from and serializes it to JSON files/text.
  Materialization depends on the loaded ShEx schema and Map state. The direct
  `load_shex_schema_precompiled` route skips source semantic actions; Map-state
  materialization needs a parsed source schema.
- **SHACL report sorting, ShEx JSON sorting and ShapeMap output:** the public
  options/formats are represented. SHACL sorting is ignored in the pinned
  implementation, ShEx JSON is unsorted, and ShapeMap CSV/details/internal
  formats are unfinished or panic upstream. Every format remains exposed by the
  wrapper; unfinished ShapeMap input/output returns `:unsupported_operation`
  before Rust's `todo!()` branch, preserving loaded state.
- **Query API:** the public `with_query_type` setter is bound but upstream ignores
  the requested type and detects it from query text. `run_query` forwards
  `format`, but the memory backend ignores it and emits Turtle; endpoint requests
  use it for content negotiation. `reset_query_results` also
  clears the stored query. Query and validation result getters expose the
  existing wrapper report shapes; raw object access remains with Rust.
- **Backends and external services:** SPARQL endpoint tests use local HTTP. QLever
  selection is bound but not launched in integration tests because it requires
  Docker and QLever binaries. Endpoint and URL operations require caller-owned
  network access.
- **Property graph database:** the pinned feature uses LadybugDB/Lbug. Local
  DDL, load, query, reports and connection resets are exercised; availability
  and file compatibility follow the linked native library.
- **Opaque native getters:** `Rudof.Object` is an immutable snapshot. Its
  `text/2` method delegates to upstream Display or Debug; callers cannot use it
  as a mutable Rudof handle.

## Elixir conveniences and presentation

These APIs supplement the facade inventory; they are not missing Rust methods:

- `Session.with_session/2` creates a session, returns the callback result, and
  closes it even when the callback raises; `close/1` explicitly ends a session.
- `read_*`, `query/2`, `check_shex/3`, `compile_shex_to_file/2`, `generate/4`,
  `convert_schema/5`, `compare_shex/4`, and serializer aliases provide documented
  shortcuts to native operations. Their accepted inputs/defaults are described
  in `Rudof.Session` docs.
- Top-level `Rudof` functions provide one-shot operations with automatic session
  cleanup through `Session.with_session/2`.
- `Object.text/2` formats an immutable native snapshot using Display or Debug.
- `Visualization.data_to_mermaid/1` obtains native PlantUML and converts the
  supported diagram subset via `plantuml_to_mermaid/1`; unsupported diagrams
  return an error. `table_data/1` reshapes SELECT results for presentation.
  Mermaid conversion is presentation logic, not an upstream Mermaid API.

## Verification

Integration coverage includes state and reset behavior, query stages, config
replacement, separate ShapeMap bases and incremental associations, compiled
schemas, resolver registration, RDF-config, Map state and materialization,
Excel conversion, Graphviz SVG/PNG, local URL load/dereference, property-graph
schema validation and database queries, and generation. The full native test
suite remains the repeatable gate. Focused contract tests check graph formats,
merged-query visibility, harmless unsupported operations, and rendering options. These tests verify representative behavior, not every
combination of formats and options. No Dialyzer is used.

The 2026-10-01 source audit matched all 87 facade rows and all 108 builder
setters against the pinned checkout and confirmed every setter is used in the
native binding. Repeat runtime verification with `mix test`; documentation
checks use `mix docs --warnings-as-errors`. Formatting and Clippy are separate
checks and are not implied by this inventory audit.

Runtime check on 2026-10-01: `mix test` passed **118 checks (117 tests and
1 doctest)**. Documentation checks still fail on README.md Livebook/LICENSE
links not resolved by ExDoc. The hidden-module and proposed-function references
have been removed from the inventories; see KNOWN_ISSUES.md for the remaining
issue.
