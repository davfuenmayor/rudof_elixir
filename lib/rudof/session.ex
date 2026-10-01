defmodule Rudof.Session do
  @moduledoc """
  A reusable, process-owned native rudof session.

  Reads, queries and validations share the session's data and schemas. Calls on
  one session queue in its private GenServer; only one enters native code at a
  time. Calls wait without a timeout, so a slow native operation also delays
  later calls queued on that session. A caller timeout does not cancel native
  work. Separate sessions can run concurrently.

  A sequence of calls is not a transaction: another borrower can change session
  state between calls. Use a separate session for each independent job when
  those steps must not observe another caller's changes. Failed upstream
  operations may have changed state; reset or recreate a session before retrying
  if that matters to your application.

  Reads take UTF-8 source text except explicitly named file or endpoint
  operations. Generation takes schema and output filenames. Schema imports and
  remote JSON-LD contexts may access the network through upstream rudof. The
  upstream backend stores a single graph: named graphs in TriG or N-Quads input
  are flattened into the default graph. Native work runs on dirty CPU schedulers;
  killing a caller or timing out a Task does not cancel an in-flight NIF.

  Call `close/1` to release native state promptly, or use `with_session/2`. The
  session also closes when its creator exits, even normally. Other processes can
  borrow the handle while the creator is alive. Create shared sessions in a
  process that lives for their intended lifetime, not in a short-lived Task.
  The server monitors its creator without linking to it; a server failure does
  not crash callers. Copies refer to the same session and close together.
  Dropping a handle alone does not stop its process.
  """
  @enforce_keys [:pid]
  defstruct [:pid]

  @doc "Runs a function with a fresh session, closing it even if the function raises, throws, or exits."
  def with_session(fun, opts \\ []) when :erlang.is_function(fun, 1) do
    with {:ok, session} <- new(opts) do
      try do
        fun.(session)
      after
        close(session)
      end
    end
  end

  @doc "Returns the pinned upstream library version."
  def version(session) do
    call(session, :version)
  end

  @doc "Validates loaded data against the ShEx schema and ShapeMap. Nonconformance is an `:ok` report; an empty report conforms vacuously."
  def validate_shex(session) do
    api_call(session, "validate_shex")
  end

  @doc "Validates loaded data against SHACL shapes. `:mode` is `:native` (default) or `:sparql`. Nonconformance is an `:ok` report."
  def validate_shacl(session, opts \\ []) do
    api_call(session, "validate_shacl", opts, mode: [:native, :sparql])
  end

  @doc "Validates loaded property-graph data using the schema and typemap. Retrieve the report separately.\n"
  def validate_pgschema(session) do
    api_call(session, "validate_pgschema")
  end

  @doc "Replaces runtime configuration using the same options as `new/1`, with\ndefaults for omitted settings. Parsing finishes before mutation. Existing\nloaded data and compiled validators are not rebuilt.\n"
  def update_config(session, opts) do
    with {:ok, config} <- Rudof.Config.encode(opts) do
      api_call(
        session,
        "update_config",
        [
          config:
            case config do
              x when :erlang.orelse(:erlang."=:="(x, false), :erlang."=:="(x, nil)) -> "{}"
              x -> x
            end
        ],
        config: :string
      )
    end
  end

  defp unwrap!({:ok, value}) do
    value
  end

  defp unwrap!({:error, error}) do
    :erlang.error(Kernel.Utils.raise(error), :none, error_info: %{module: Exception})
  end

  defp unit({:ok, :ok}) do
    :ok
  end

  defp unit(error) do
    error
  end

  @doc "Converts native schema inputs, including Excel files, HTML and UML/image outputs.\nRequired format options: input_format and output_format. Other options: base, shape, reader_mode, show_time, templates_folder, output_folder, viz_engine. HTML writes to output_folder; binary outputs remain binaries.\n"
  def show_schema_conversion(session, input, from, to, opts \\ []) do
    api_options(session, "show_schema_conversion", [input: input, from: from, to: to], opts,
      input: :input,
      from: [:shex, :shacl, :dctap],
      to: [:shex, :shacl, :sparql, :uml, :html],
      input_format: [:csv, :xlsx, :shexc, :shexj, :turtle],
      output_format: [
        :default,
        :internal,
        :json,
        :shexc,
        :shexj,
        :turtle,
        :uml,
        :html,
        :svg,
        :png
      ],
      base: :optional_string,
      shape: :optional_string,
      reader_mode: [:strict, :lax],
      show_time: :boolean,
      templates_folder: :string,
      output_folder: :string,
      viz_engine: [:plantuml, :graphviz]
    )
  end

  @doc "Compares native schema inputs. Options: mode1/mode2, format1/format2, base1/base2, shape1/shape2, reader_mode, show_time, output_format. Upstream only implements ShEx comparison; other modes return unsupported_operation.\n"
  def show_schema_comparison(session, left, right, opts \\ []) do
    api_options(session, "show_schema_comparison", [left: left, right: right], opts,
      left: :input,
      right: :input,
      mode1: [:shex, :shacl, :dctap, :service],
      mode2: [:shex, :shacl, :dctap, :service],
      format1: [:shexc, :shexj, :turtle, :rdfxml, :ntriples],
      format2: [:shexc, :shexj, :turtle, :rdfxml, :ntriples],
      base1: :optional_string,
      base2: :optional_string,
      shape1: :optional_string,
      shape2: :optional_string,
      reader_mode: [:strict, :lax],
      show_time: :boolean,
      output_format: [:json, :internal]
    )
  end

  @doc "Direct public Rust node inspection; accepts the same options as node_info/3."
  def show_node_info(session, node, opts \\ []) do
    node_info(session, node, opts)
  end

  @doc "Returns the last ShEx report or nil, without validating again.\n"
  def shex_validation_results(session) do
    api_call(session, "shex_validation_results")
  end

  @doc "Returns the compiled shape count, including imports, or nil. Works with precompiled schemas.\n"
  def shex_schema_shapes_count(session) do
    api_call(session, "shex_schema_shapes_count")
  end

  @doc "Returns the source ShEx AST as upstream JSON or nil. Precompiled caches do not contain this AST.\n"
  def shex_schema(session) do
    api_call(session, "shex_schema")
  end

  @doc "Returns the last SHACL report or nil, without validating again.\n"
  def shacl_validation_results(session) do
    api_call(session, "shacl_validation_results")
  end

  @doc "Returns an immutable native SHACL IR snapshot or nil. Format it with Rudof.Object.text/2.\n"
  def shacl_shapes(session) do
    api_call(session, "shacl_shapes")
  end

  @doc "Returns service metadata as upstream JSON or nil.\n"
  def service_description(session) do
    api_call(session, "service_description")
  end

  @doc "Exports the normalized stored SPARQL query.\n"
  def serialize_sparql_query(session) do
    api_call(session, "serialize_sparql_query")
  end

  @doc "Extended native serializer. Options: sort_by: [:node, :shape, :status, :details]. Upstream JSON output ignores sorting. Unsupported formats return structured errors.\n"
  def serialize_shex_validation_results(session, format, opts) do
    api_options(session, "serialize_shex_validation_results", [format: format], opts,
      format: [
        :compact,
        :details,
        :json,
        :csv | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml]
      ],
      sort_by: [:node, :shape, :status, :details]
    )
  end

  @doc "Serializes the last ShEx validation report through Rust (default `:json`). Native formats include compact text, detailed text, JSON, CSV, and RDF formats. Upstream may return an error for unfinished formats. Use the three-argument form to pass sorting options."
  def serialize_shex_validation_results(session, format \\ :json) do
    serialize_shex_validation_results(session, format, [])
  end

  @doc "Serializes ShEx through Rust, preserving binary output. Options: `:shape`, `:show_schema`, `:show_statistics`, `:show_dependencies`, `:show_time`, and `:viz_engine` (`:plantuml` or `:graphviz`). Presentation text is retained exactly as emitted upstream, even with binary/image formats.\n"
  def serialize_shex_schema(session, format \\ :shexc, opts \\ []) do
    api_options(session, "serialize_shex_schema", [format: format], opts,
      format: [
        :shexc,
        :shexj,
        :json,
        :internal,
        :simple,
        :plantuml,
        :svg,
        :png,
        :binary,
        :turtle,
        :ntriples,
        :nquads,
        :trig,
        :n3,
        :rdfxml,
        :jsonld
      ],
      shape: :string,
      show_schema: :boolean,
      show_statistics: :boolean,
      show_dependencies: :boolean,
      show_time: :boolean,
      viz_engine: [:plantuml, :graphviz]
    )
  end

  @doc "Serializes the ShEx schema as `:shexc` (default) or `:shexj`."
  def serialize_shex(session, format \\ :shexc) do
    serialize(session, "serialize_shex_schema", format, [:shexc, :shexj])
  end

  @doc "Extended native serializer. Options: show_colors: :boolean. Unsupported upstream formats return structured errors.\n"
  def serialize_shapemap(session, format, opts) do
    api_options(session, "serialize_shapemap", [format: format], opts,
      format: [:compact, :json, :internal, :details, :csv],
      show_colors: :boolean
    )
  end

  @doc "Serializes the ShapeMap as `:compact` (default) or `:json`. Upstream `:internal`, `:details`, and `:csv` return `:unsupported_operation`."
  def serialize_shapemap(session, format \\ :compact) do
    serialize_shapemap(session, format, [])
  end

  @doc "Serializes SHACL results. Options: `:sort_by` (:severity, :node, :component, :value, :path, :sourceshape, :details); sorting is ignored by the pinned upstream. Unsupported formats return structured errors.\n"
  def serialize_shacl_validation_results(session, format, opts) do
    api_options(session, "serialize_shacl_validation_results", [format: format], opts,
      format: [
        :compact,
        :minimal,
        :details,
        :json,
        :csv | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml]
      ],
      sort_by: [:severity, :node, :component, :value, :path, :sourceshape, :details]
    )
  end

  @doc "Serializes the last SHACL report through Rust (default `:turtle`). Compact, minimal, detailed, JSON, CSV, and RDF formats are accepted by the wrapper; upstream may return an error for unfinished formats. Use the three-argument form to pass native options."
  def serialize_shacl_validation_results(session, format \\ :turtle) do
    serialize_shacl_validation_results(session, format, [])
  end

  @doc "Serializes loaded SHACL shapes in a native format. No additional options.\n"
  def serialize_shacl_shapes(session, format \\ :turtle, opts \\ []) do
    api_options(session, "serialize_shacl_shapes", [format: format], opts,
      format: [:json, :internal | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]]
    )
  end

  @doc "Serializes the SHACL shapes graph (default `:turtle`)."
  def serialize_shacl(session, format \\ :turtle) do
    serialize(session, "serialize_shacl_shapes", format, [
      :turtle,
      :ntriples,
      :nquads,
      :trig,
      :n3,
      :rdfxml,
      :jsonld
    ])
  end

  @doc "Serializes the service description as upstream `:json` (default), `:mie` or `:internal` text."
  def serialize_service_description(session, format \\ :json) do
    serialize(session, "serialize_service_description", format, [:json, :mie, :internal])
  end

  @doc "Serializes loaded RDF-config as `:yaml` (default) or `:internal` text. No additional options.\n"
  def serialize_rdf_config(session, format \\ :yaml, opts \\ []) do
    api_options(session, "serialize_rdf_config", [format: format], opts,
      format: [:yaml, :internal]
    )
  end

  @doc "Serializes the last query result through Rust. SELECT supports upstream `:json` (default, not SPARQL Results JSON), `:csv`, `:markdown` and `:internal`. ASK always writes boolean text; CONSTRUCT/DESCRIBE write the stored graph text unchanged; its format depends on the execution backend and run_query/2 options. RDF formats are accepted by Rust but rejected for SELECT."
  def serialize_query_results(session, format \\ :json) do
    serialize(session, "serialize_query_results", format, [
      :json,
      :csv,
      :markdown,
      :internal | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]
    ])
  end

  @doc "Serializes the last property-graph report. Option: `:show_colors` (boolean).\n"
  def serialize_pgschema_validation_results(session, format \\ :json, opts \\ []) do
    api_options(session, "serialize_pgschema_validation_results", [format: format], opts,
      format: [:compact, :details, :json, :csv],
      show_colors: :boolean
    )
  end

  @doc "Serializes a property-graph schema as `:compact` (default) or its alias `:pgschemac`. No additional options.\n"
  def serialize_pg_schema(session, format \\ :compact, opts \\ []) do
    api_options(session, "serialize_pg_schema", [format: format], opts,
      format: [:compact, :pgschemac]
    )
  end

  @doc "Serializes loaded Map semantic-action state as upstream JSON.\n"
  def serialize_map_state(session) do
    api_call(session, "serialize_map_state")
  end

  @doc "Serializes the loaded DCTAP as upstream JSON (default) or human-readable `:internal` text."
  def serialize_dctap(session, format \\ :json) do
    serialize(session, "serialize_dctap", format, [:json, :internal])
  end

  @doc "Extended native serializer. Options: viz_engine: [:plantuml, :graphviz]. Unsupported upstream formats return structured errors.\n"
  def serialize_data(session, format, opts) do
    api_options(session, "serialize_data", [format: format], opts,
      format: [
        :compact,
        :json,
        :plantuml,
        :svg,
        :png | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]
      ],
      viz_engine: [:plantuml, :graphviz]
    )
  end

  @doc "Serializes loaded data (default `:turtle`). Accepts RDF formats and upstream `:compact`, `:json`, `:plantuml`, `:svg`, and `:png`; use /3 to select the visualization engine."
  def serialize_data(session, format \\ :turtle) do
    serialize_data(session, format, [])
  end

  defp serialize(session, kind, format, formats) do
    api_call(session, kind, [format: format], format: formats)
  end

  @doc "Executes the stored query. Retrieve the result with query_results/1.\nOption `:format` is forwarded to the upstream graph-query builder (default Turtle). The memory backend currently ignores it and always emits Turtle; endpoints use it for content negotiation.\n"
  def run_query(session, opts \\ []) do
    api_call(session, "run_query", opts,
      format: [
        :json,
        :csv,
        :markdown,
        :internal | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]
      ]
    )
  end

  @doc "Delegates to Rust `reset_typemap`. Uses upstream reset semantics.\n"
  def reset_typemap(session) do
    reset(session, :typemap)
  end

  @doc "Delegates to Rust `reset_sparql_query`. Uses upstream reset semantics.\n"
  def reset_sparql_query(session) do
    reset(session, :sparql_query)
  end

  @doc "Delegates to Rust `reset_shex_schema`. Uses upstream reset semantics.\n"
  def reset_shex_schema(session) do
    reset(session, :shex_schema)
  end

  @doc "Delegates to Rust `reset_shex`. Uses upstream reset semantics.\n"
  def reset_shex(session) do
    reset(session, :shex)
  end

  @doc "Delegates to Rust `reset_shapemap`. Uses upstream reset semantics.\n"
  def reset_shapemap(session) do
    reset(session, :shapemap)
  end

  @doc "Delegates to Rust `reset_shacl_shapes`. Uses upstream reset semantics.\n"
  def reset_shacl_shapes(session) do
    reset(session, :shacl_shapes)
  end

  @doc "Delegates to Rust `reset_shacl`. Uses upstream reset semantics.\n"
  def reset_shacl(session) do
    reset(session, :shacl)
  end

  @doc "Delegates to Rust `reset_service_description`. Uses upstream reset semantics.\n"
  def reset_service_description(session) do
    reset(session, :service_description)
  end

  @doc "Delegates to Rust `reset_rdf_config`. Uses upstream reset semantics.\n"
  def reset_rdf_config(session) do
    reset(session, :rdf_config)
  end

  @doc "Delegates to Rust `reset_query_results`. Uses upstream reset semantics.\n"
  def reset_query_results(session) do
    reset(session, :query_results)
  end

  @doc "Delegates to Rust `reset_pg_schema_validation`. Uses upstream reset semantics.\n"
  def reset_pg_schema_validation(session) do
    reset(session, :pg_schema_validation)
  end

  @doc "Delegates to Rust `reset_pg_schema`. Uses upstream reset semantics.\n"
  def reset_pg_schema(session) do
    reset(session, :pg_schema)
  end

  @doc "Delegates to Rust `reset_pg_db_connection`. Uses upstream reset semantics.\n"
  def reset_pg_db_connection(session) do
    reset(session, :pg_db_connection)
  end

  @doc "Delegates to Rust `reset_dctap`. Uses upstream reset semantics.\n"
  def reset_dctap(session) do
    reset(session, :dctap)
  end

  @doc "Delegates to Rust `reset_data`. Uses upstream reset semantics.\n"
  def reset_data(session) do
    reset(session, :data)
  end

  @doc "Delegates to Rust `reset_all`. Uses upstream reset semantics.\n"
  def reset_all(session) do
    reset(session, :all)
  end

  @doc "Clears selected state using upstream reset semantics. The target defaults to `:all`; other targets clear only their named component, such as RDF data, ShEx schema, SHACL shapes, or query results. Configuration is retained."
  def reset(session, target \\ :all) do
    with :ok <-
           Rudof.Options.validate([target: target],
             target: [
               :all,
               :data,
               :shex,
               :shacl,
               :shapemap,
               :dctap,
               :service_description,
               :shex_schema,
               :shacl_shapes,
               :sparql_query,
               :query_results,
               :rdf_config,
               :pg_schema,
               :typemap,
               :pg_schema_validation,
               :pg_db_connection
             ]
           ) do
      call(session, :reset, [:erlang.atom_to_binary(target)])
    end
  end

  @doc "Renames a default prefix, retaining its IRI and replacing the destination alias if present."
  def rename_prefix(session, old, new) do
    prefix(session, "rename", old, new)
  end

  @doc "Removes a default prefix. An unknown alias returns an upstream error."
  def remove_prefix(session, alias) do
    prefix(session, "remove", alias, "")
  end

  @doc "Loads a precompiled ShEx cache file for validation, skipping source parsing and imports. Uses upstream's reader default; does not restore a serializable source AST."
  def read_shex_precompiled(session, path) do
    with :ok <- Rudof.Options.validate([path: path], path: :string) do
      load_shex_schema_precompiled(session, {:file, path})
    end
  end

  @doc "Reads a ShEx schema. Options: `:format` (`:shexc` or `:shexj`, default `:shexc`) and `:base`."
  def read_shex(session, source, opts \\ []) do
    read(session, "load_shex_schema", source, opts, [:shexc, :shexj], :shexc)
  end

  @doc "Reads node/shape associations. Options: `:format` (default `:compact`), `:base`, `:base_nodes`, `:base_shapes`. Other upstream ShapeMap formats return `:unsupported_operation`."
  def read_shapemap(session, source, opts \\ []) do
    with :ok <-
           Rudof.Options.validate(opts,
             format: [:compact, :json, :internal, :details, :csv],
             base: :optional_string,
             base_nodes: :optional_string,
             base_shapes: :optional_string
           ) do
      load_shapemap(session, source, opts)
    end
  end

  @doc "Reads a SHACL shapes graph. Options: RDF `:format` (default `:turtle`) and `:base`."
  def read_shacl(session, source, opts \\ []) do
    read(
      session,
      "load_shacl_shapes",
      source,
      opts,
      [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      :turtle
    )
  end

  @doc "Reads a SPARQL service description from RDF source. Options: RDF `:format` (default `:turtle`) and `:base`. Does not connect to the described endpoint."
  def read_service_description(session, source, opts \\ []) do
    read(
      session,
      "load_service_description",
      source,
      opts,
      [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      :turtle
    )
  end

  @doc "Attaches a SPARQL endpoint URL or configured endpoint name as the session's\ndata backend, replacing local data. Queries and validation may then perform\nnetwork requests through Rust. Upstream configuration governs HTTP behavior.\nReset `:data` before returning to local source input.\n"
  def read_endpoint(session, endpoint) do
    with :ok <- Rudof.Options.validate([endpoint: endpoint], endpoint: :string) do
      load_data(session, [], endpoint: endpoint)
    end
  end

  @doc "Reads a DCTAP file. `:format` is `:csv` (default), `:xlsx`, `:xlsb`, `:xlsm` or `:xls`. Excel loading requires a filename upstream."
  def read_dctap_file(session, path, opts \\ []) do
    with :ok <- Rudof.Options.validate([path: path], path: :string),
         :ok <- Rudof.Options.validate(opts, format: [:csv, :xlsx, :xlsb, :xlsm, :xls]) do
      load_dctap(session, {:file, path}, Keyword.put_new(opts, :format, :csv))
    end
  end

  @doc "Reads DCTAP CSV source. Unlike RDF, profiles do not merge."
  def read_dctap(session, source) do
    read(session, "load_dctap", source, [], [:csv], :csv)
  end

  @doc "Reads RDF source. Options: `:format` (default `:turtle`), `:base`, and
`:merge` (default `true`, following upstream). New data is added to the current
graph; pass `merge: false` to replace it."
  def read_data(session, source, opts \\ []) do
    read(
      session,
      "load_data",
      source,
      opts,
      [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      :turtle,
      true
    )
  end

  defp read(session, kind, source, opts, formats, default, merge? \\ false) do
    rules =
      :erlang.++(
        [format: formats, base: :optional_string],
        case merge? do
          x when :erlang.orelse(:erlang."=:="(x, false), :erlang."=:="(x, nil)) -> []
          _ -> [merge: :boolean]
        end
      )

    with :ok <- Rudof.Options.validate([source: source], source: :string),
         :ok <- Rudof.Options.validate(opts, rules) do
      opts = Keyword.put_new(opts, :format, default)

      case merge? do
        x when :erlang.orelse(:erlang."=:="(x, false), :erlang."=:="(x, nil)) ->
          api_input(session, kind, source, opts, rules)

        _ ->
          load_data(session, [source], opts)
      end
    end
  end

  @doc "Returns the last query result map or nil, without executing the query.\n"
  def query_results(session) do
    api_call(session, "query_results")
  end

  @doc "Executes native Cypher from a source/file/URL input, returning upstream JSON with columns, rows and timing. Options: db and read_only (used with a db override).\n"
  def query_cypher(session, input, opts \\ []) do
    api_input(session, "query_cypher", input, opts, db: :string, read_only: :boolean)
  end

  @doc "Executes SELECT, ASK, CONSTRUCT or DESCRIBE against the loaded data.\n\nSELECT returns variable names (without `?`) and aligned rows of RDF term\nstrings; unbound values are `nil`. Upstream does not retain variable names\nfor an empty result, so both lists are empty in that case. ASK returns a\nboolean map. Graph queries return Turtle text with query/2; run_query/2 forwards a graph format, which the memory backend currently ignores. SPARQL UPDATE is unsupported.\n"
  def query(session, source) do
    with :ok <- Rudof.Options.validate([source: source], source: :string) do
      api_call(session, "query", [input: source], input: :string)
    end
  end

  @doc "Lists default prefix declarations as `{alias, iri}` pairs, for subsequent reads and queries."
  def prefixes(session) do
    call(session, :prefixes)
  end

  defp prefix(session, operation, alias, value) do
    with :ok <-
           Rudof.Options.validate([alias: alias, value: value], alias: :string, value: :string) do
      call(session, :prefix, [operation, alias, value])
    end
  end

  @doc "Returns the last property-graph report as upstream JSON or nil, without validating again.\n"
  def pgschema_validation_results(session) do
    api_call(session, "pgschema_validation_results")
  end

  @doc "Returns an immutable native property-graph schema snapshot or nil.\n"
  def pg_schema(session) do
    api_call(session, "pg_schema")
  end

  @doc "Derives DDL from RDF input specifications without replacing session data. Options: dialect (:cypher/:gql), graph_type_name, format, base, reader_mode.\n"
  def pg_db_ddl(session, inputs, opts \\ []) do
    api_options(session, "pg_db_ddl", [inputs: inputs], opts,
      inputs: :inputs,
      dialect: [:cypher, :gql],
      graph_type_name: :string,
      format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      base: :optional_string,
      reader_mode: [:strict, :lax]
    )
  end

  @doc "Returns stored database connection settings as JSON or nil. Upstream opens a connection for each operation.\n"
  def pg_db_connection(session) do
    api_call(session, "pg_db_connection")
  end

  @doc "Collects upstream's depth-first neighborhood as `%{arcs: [...], truncated: boolean}`.\nEach arc has `:root`, `:node`, `:predicate`, `:neighbor` (term strings),\n`:direction` (`:incoming` or `:outgoing`), `:depth` and `:is_last`.\nUses the same selectors/options as `node_info/3`, plus optional positive `:limit`.\nWithout a limit, the entire neighborhood is collected. `:is_last` describes\nupstream traversal, not the end of a truncated list. RDF 1.2 triple terms cannot\ncurrently be rendered upstream; encountering one can return `:panic` and close\nthe session.\n"
  def node_neighborhood(session, node, opts \\ []) do
    inspect_node(session, :node_neighborhood, node, opts)
  end

  @doc "Returns upstream's node description without ANSI colors. Node selectors and\npredicate filters use `<absolute-IRI>` or declared `prefix:name` syntax.\nOptions: `:mode` (`:both`, `:incoming`, `:outgoing`), positive `:depth` (default 1),\nand `:predicates` (list of strings, default all).\n"
  def node_info(session, node, opts \\ []) do
    inspect_node(session, :node_info, node, opts)
  end

  @doc "Creates a session, raising `Rudof.Error` on failure."
  def new!(opts \\ []) do
    unwrap!(new(opts))
  end

  @doc "Creates an empty session tied to the calling process's lifetime.\nSupply at most one of `path: filename`, `toml_str: text`, or\n`config: keywords`. Nested keyword lists represent upstream TOML tables;\nother lists represent arrays. Use upstream setting names and enum strings.\nRust parses and validates all three forms using its configuration API.\n\nWithout configuration, relative IRIs use rudof's automatic base (`http://base`).\nPass `base: \"https://example.org/\"` when reading to set an explicit base.\n"
  def new(opts \\ []) do
    with {:ok, config} <- Rudof.Config.encode(opts),
         {:ok, pid} <- Rudof.Session.Server.start(config) do
      {:ok, %Rudof.Session{pid: pid}}
    end
  end

  defp native_options(opts, defaults) do
    Map.new(
      Keyword.merge(
        defaults,
        opts
      ),
      fn
        {key, value}
        when :erlang.andalso(
               :erlang.andalso(:erlang.is_atom(value), :erlang.not(:erlang.==(value, nil))),
               :erlang.not(:erlang.is_boolean(value))
             ) ->
          {key, :erlang.atom_to_binary(value)}

        pair ->
          pair
      end
    )
  end

  @doc "Materializes RDF from the loaded ShEx schema and Map state. Options: initial_node_iri and RDF format (default Turtle).\n"
  def materialize(session, opts \\ []) do
    api_call(session, "materialize", opts,
      initial_node_iri: :string,
      format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]
    )
  end

  @doc "Loads property-graph node/type associations from a native input. No additional options.\n"
  def load_typemap(session, input, opts \\ []) do
    api_input(session, "load_typemap", input, opts, [])
  end

  @doc "Loads a native query input without executing it. Option: `:query_type` (`:select`, `:ask`, `:construct`, or `:describe`), currently ignored by upstream in favor of detecting the type from source.\n"
  def load_sparql_query(session, input, opts \\ []) do
    api_input(session, "load_sparql_query", input, opts,
      query_type: [:select, :ask, :construct, :describe]
    )
  end

  @doc "Loads a compiled ShEx cache from UTF-8 source text or a tagged `{:file, path}`, `{:url, url}`, or `{:string, text}` input. `:reader_mode` may be `:strict` or `:lax`. Source ASTs are not restored; use files or URLs for caches containing non-UTF-8 bytes.\n"
  def load_shex_schema_precompiled(session, input, opts \\ []) do
    api_input(session, "load_shex_schema_precompiled", input, opts, reader_mode: [:strict, :lax])
  end

  @doc "Loads ShEx from UTF-8 source text or a tagged `{:file, path}`, `{:url, url}`, or `{:string, text}` input. Options: `:format` (`:shexc`, `:shexj`, `:json`, `:internal`, `:simple`, `:plantuml`, `:svg`, `:png`, `:binary`, or an RDF format), `:base`, and `:reader_mode` (`:strict` or `:lax`). Formats unavailable upstream return errors.\n"
  def load_shex_schema(session, input, opts \\ []) do
    api_input(session, "load_shex_schema", input, opts,
      format: [
        :shexc,
        :shexj,
        :json,
        :internal,
        :simple,
        :plantuml,
        :svg,
        :png,
        :binary,
        :turtle,
        :ntriples,
        :nquads,
        :trig,
        :n3,
        :rdfxml,
        :jsonld
      ],
      base: :optional_string,
      reader_mode: [:strict, :lax]
    )
  end

  @doc "Loads a ShapeMap from UTF-8 source text or a tagged `{:file, path}`, `{:url, url}`, or `{:string, text}` input. Options: `:format` (`:compact`, `:json`, `:internal`, `:details`, or `:csv`), `:base`, `:base_nodes`, and `:base_shapes`. Only compact input is implemented upstream; other formats return `:unsupported_operation` without mutation.\n"
  def load_shapemap(session, input, opts \\ []) do
    api_input(session, "load_shapemap", input, opts,
      format: [:compact, :json, :internal, :details, :csv],
      base: :optional_string,
      base_nodes: :optional_string,
      base_shapes: :optional_string
    )
  end

  @doc "Loads SHACL shapes from UTF-8 source text, a tagged `{:file, path}`, `{:url, url}`, or `{:string, text}` input, or from loaded RDF when input is nil. Options: RDF `:format` (also `:json` or `:internal`), `:base`, and `:reader_mode` (`:strict` or `:lax`).\n"
  def load_shacl_shapes(session, input, opts \\ []) do
    api_options(session, "load_shacl_shapes", [input: input], opts,
      input: :optional_input,
      format: [:json, :internal | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]],
      base: :optional_string,
      reader_mode: [:strict, :lax]
    )
  end

  @doc "Loads service metadata from a native RDF input without attaching its endpoint. Options: RDF `:format`, `:base`, and `:reader_mode` (`:strict` or `:lax`).\n"
  def load_service_description(session, input, opts \\ []) do
    api_input(session, "load_service_description", input, opts,
      format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      base: :optional_string,
      reader_mode: [:strict, :lax]
    )
  end

  @doc "Loads an RDF-config document from a native input. Option: `:format` (`:yaml`).\n"
  def load_rdf_config(session, input, opts \\ []) do
    api_input(session, "load_rdf_config", input, opts, format: [:yaml])
  end

  @doc "Loads a property-graph schema from a native input. Option: `:format` (`:compact` or its alias `:pgschemac`).\n"
  def load_pg_schema(session, input, opts \\ []) do
    api_input(session, "load_pg_schema", input, opts, format: [:compact, :pgschemac])
  end

  @doc "Loads RDF into the property-graph database. Returns `{node_count, relationship_count, diagnostics}`. Options: db, read_only, shapes, shapes_format, base_shapes, skip_validation, format, base, reader_mode.\n"
  def load_pg_db(session, inputs, opts \\ []) do
    api_options(session, "load_pg_db", [inputs: inputs], opts,
      inputs: :inputs,
      db: :string,
      read_only: :boolean,
      shapes: :input,
      shapes_format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      base_shapes: :optional_string,
      skip_validation: :boolean,
      format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
      base: :optional_string,
      reader_mode: [:strict, :lax]
    )
  end

  @doc "Loads Map semantic-action state from a JSON file, using the upstream file reader.\n"
  def load_map_state(session, path) do
    api_call(session, "load_map_state", [path: path], path: :string)
  end

  @doc "Loads a DCTAP profile from a native input. Option: `:format` (`:csv`, `:xlsx`, `:xlsb`, `:xlsm`, or `:xls`). Excel formats require a file input upstream.\n"
  def load_dctap(session, input, opts \\ []) do
    api_input(session, "load_dctap", input, opts, format: [:csv, :xlsx, :xlsb, :xlsm, :xls])
  end

  @doc "Loads native RDF or property-graph inputs. Inputs are a list of source strings or tagged input specifications.
Options: format, base, reader_mode, merge, backend (:memory/:qlever/:lbug), endpoint, endpoint_strategy (:sparql/:dereference), prefixes (input list).
Merges by default, following upstream, as does `read_data/3`. Pass `merge: false` to replace existing data."
  def load_data(session, inputs, opts \\ []) do
    api_options(session, "load_data", [inputs: inputs], opts,
      inputs: :inputs,
      format: [:pg | [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld]],
      base: :optional_string,
      reader_mode: [:strict, :lax],
      merge: :boolean,
      backend: [:memory, :qlever, :lbug],
      endpoint: :string,
      endpoint_strategy: [:sparql, :dereference],
      prefixes: :inputs
    )
  end

  @doc "Returns JSON metadata for built-in resolver kinds, not the installed resolver chain.\n"
  def list_external_resolvers(session) do
    api_call(session, "list_external_resolvers")
  end

  @doc "Lists configured endpoints as `{name, url}` pairs. Requires initialized RDF data (local or endpoint). Does not contact them."
  def list_endpoints(session) do
    call(session, :list_endpoints)
  end

  defp inspect_node(session, operation, node, opts) do
    rules = [
      mode: [:both, :incoming, :outgoing],
      depth: :positive_integer,
      predicates: :strings,
      iri_mode: [:strict, :lax]
    ]

    rules =
      case :erlang.==(operation, :node_neighborhood) do
        false -> :erlang.++(rules, show_colors: :boolean, show_hyperlinks: :boolean)
        true -> :erlang.++(rules, limit: :optional_positive_integer)
      end

    with :ok <- Rudof.Options.validate([node: node], node: :string),
         :ok <- Rudof.Options.validate(opts, rules) do
      call(session, operation, [
        node,
        native_options(opts,
          mode: :both,
          depth: 1,
          predicates: [],
          limit: nil,
          iri_mode: :strict,
          show_colors: false,
          show_hyperlinks: false
        )
      ])
    end
  end

  @doc "Returns whether a query is stored, independently of its results.\n"
  def has_sparql_query?(session) do
    api_call(session, "has_sparql_query")
  end

  @doc "Returns whether upstream has loaded data, including an empty graph.\n"
  def has_data?(session) do
    api_call(session, "has_data")
  end

  @doc "Direct upstream generation builder. Input must currently be a schema file.\nOptions: schema_format (:auto/:shex/:shacl), entities, output, output_format,\nconfig_file, seed, parallel. Omitted options retain upstream defaults, including\nits output destination. Generation can overwrite output and statistics files.\n"
  def generate_data(session, input, opts \\ []) do
    api_input(session, "generate_data", input, opts,
      schema_format: [:auto, :shex, :shacl],
      entities: :optional_u64,
      output: :string,
      output_format:
        :erlang.++([:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld], [:pg]),
      config_file: :string,
      seed: :optional_u64,
      parallel: :optional_positive_integer
    )
  end

  @doc "Generates RDF from a schema **file** into an explicit output **file**, using\nthe upstream generator. Returns `:ok`; does not load the generated data into\nthis session. Existing output files may be overwritten. Upstream also writes\nstatistics by default; configuration can enable compression or multiple files.\n\nOptions: `:schema_format` (`:auto`, `:shex`, `:shacl`), `:output_format`\n(`:turtle` default or `:ntriples`), `:entities` (positive integer), `:seed`\n(unsigned 64-bit integer), `:parallel` (positive worker count), `:config_file`\n(generator TOML/JSON filename, not Rudof session configuration).\n\nUnspecified counts/seed/workers retain generator configuration defaults.\nThe explicit output path and output format override the config file. A seed\nis passed through; byte-for-byte determinism and schema conformance depend on\nupstream. Validate generated data when conformance matters.\n"
  def generate(session, schema_path, output_path, opts \\ []) do
    with :ok <-
           Rudof.Options.validate([schema_path: schema_path, output_path: output_path],
             schema_path: :string,
             output_path: :string
           ),
         :ok <-
           Rudof.Options.validate(opts,
             schema_format: [:auto, :shex, :shacl],
             output_format: [:turtle, :ntriples],
             entities: :optional_positive_integer,
             seed: :optional_u64,
             parallel: :optional_positive_integer,
             config_file: :optional_string
           ) do
      opts =
        Keyword.put_new(
          Keyword.put(
            Enum.reject(
              opts,
              fn {_key, value} -> :erlang.==(value, nil) end
            ),
            :output,
            output_path
          ),
          :output_format,
          :turtle
        )

      generate_data(session, {:file, schema_path}, opts)
    end
  end

  @doc "Dereferences an IRI through the native HTTP client. Options: reader_mode and merge (default true). Upstream controls content negotiation and redirects."
  def dereference(session, uri, opts \\ []) do
    api_options(session, "dereference", [uri: uri], opts,
      uri: :string,
      reader_mode: [:strict, :lax],
      merge: :boolean
    )
  end

  @doc "Returns the loaded DCTAP model as upstream JSON or nil.\n"
  def dctap(session) do
    api_call(session, "dctap")
  end

  @doc "Returns upstream JSON statistics or nil. RDF triples are local counts; this does not count remote endpoint triples.\n"
  def data_stats(session) do
    api_call(session, "data_stats")
  end

  @doc "Copies a default prefix to another alias, replacing its existing IRI if present."
  def copy_prefix(session, old, new) do
    prefix(session, "copy", old, new)
  end

  @doc "Converts schema source through upstream rudof. Supported routes are\nDCTAP → ShEx, SHACL → ShEx, ShEx → SPARQL, and same-language ShEx/SHACL\nserialization. Inputs are `:dctap`, `:shex` or `:shacl`; outputs are `:shex`,\n`:shacl` or `:sparql`. Unsupported combinations return an upstream error.\n\nOptions: `:input_format` (`:csv`, `:shexc`, `:shexj`, `:turtle`),\n`:output_format` (`:shexc`, `:shexj`, `:turtle`, `:default`), `:base`, `:shape`.\nFormats default to the corresponding language's compact text format.\n`:shape` selects a shape using ShEx IRI syntax (`\":Person\"` or\n`\"<http://example.org/Person>\"`) where supported by upstream. Conversion can update\nthe session's loaded schema/profile. Returns serialized source, not an AST.\n"
  def convert_schema(session, source, from, to, opts \\ []) do
    with :ok <-
           Rudof.Options.validate([source: source, from: from, to: to],
             source: :string,
             from: [:dctap, :shex, :shacl],
             to: [:shex, :shacl, :sparql]
           ),
         :ok <-
           Rudof.Options.validate(opts,
             input_format: [:csv, :shexc, :shexj, :turtle],
             output_format: [:shexc, :shexj, :turtle, :default],
             base: :optional_string,
             shape: :optional_string
           ) do
      defaults = [
        input_format: %{dctap: :csv, shex: :shexc, shacl: :turtle}[from],
        output_format: %{shex: :shexc, shacl: :turtle, sparql: :default}[to]
      ]

      show_schema_conversion(session, source, from, to, Keyword.merge(defaults, opts))
    end
  end

  @doc "Opens/verifies a property-graph database and returns info as JSON. Options: in_memory, read_only, engine (:lbug). In-memory connections are not retained by upstream.\n"
  def connect_pg_db(session, path \\ nil, opts \\ []) do
    api_options(session, "connect_pg_db", [path: path], opts,
      path: :optional_string,
      in_memory: :boolean,
      read_only: :boolean,
      engine: [:lbug, :memory, :qlever]
    )
  end

  @doc "Returns serializable upstream configuration as JSON text. Runtime resolver registries are not serialized.\n"
  def config(session) do
    api_call(session, "config")
  end

  @doc "Writes the loaded ShEx compiled IR to a file, overwriting it. Cache compatibility is governed by upstream; regenerate caches when upgrading rudof."
  def compile_shex_to_file(session, path) do
    compile_shex_schema_to_file(session, path)
  end

  @doc "Writes the native compiled ShEx schema to a file. Existing files are overwritten after compilation succeeds.\n"
  def compile_shex_schema_to_file(session, path) do
    api_call(session, "compile_shex_schema_to_file", [path: path], path: :string)
  end

  @doc "Compares two ShEx source strings through the upstream comparator.\nReturns upstream JSON text by default, or human-readable `:internal` output.\n\nOptions: `:format1`/`:format2` (`:shexc` or `:shexj`, default `:shexc`),\n`:shape1`/`:shape2` (absolute shape IRIs), `:base1`/`:base2`, `:output_format`.\nComparison is upstream's structural comparison, not a proof of equivalence.\nOther schema languages are not supported by the pinned upstream comparator.\n"
  def compare_shex(session, left, right, opts \\ []) do
    with :ok <- Rudof.Options.validate([left: left, right: right], left: :string, right: :string),
         :ok <-
           Rudof.Options.validate(opts,
             format1: [:shexc, :shexj],
             format2: [:shexc, :shexj],
             output_format: [:json, :internal],
             base1: :optional_string,
             base2: :optional_string,
             shape1: :optional_string,
             shape2: :optional_string
           ) do
      show_schema_comparison(session, left, right, Keyword.put_new(opts, :output_format, :json))
    end
  end

  @doc "Releases native state and stops the session process after earlier queued calls. Idempotent; all aliases become closed."
  def close(%Rudof.Session{pid: pid}) do
    case Rudof.Session.Server.call(pid, :close) do
      {:error, %Rudof.Error{kind: kind}}
      when :erlang.orelse(:erlang."=:="(kind, :closed), :erlang."=:="(kind, :server_failure)) ->
        :ok

      result ->
        unit(result)
    end
  end

  @doc "Restores the default reject-all external shape resolver registry. Changes apply when a validator is built.\n"
  def clear_external_resolvers(session) do
    api_call(session, "clear_external_resolvers")
  end

  @doc "Checks a source/file/URL schema without replacing the session schema. Returns `{valid?, diagnostics}`. Options: format and base.\n"
  def check_shex_schema(session, input, opts \\ []) do
    api_input(session, "check_shex_schema", input, opts,
      format: [
        :shexc,
        :shexj,
        :json,
        :internal,
        :simple,
        :plantuml,
        :svg,
        :png,
        :binary,
        :turtle,
        :ntriples,
        :nquads,
        :trig,
        :n3,
        :rdfxml,
        :jsonld
      ],
      base: :optional_string
    )
  end

  @doc "Checks ShEx source without replacing the loaded schema. Returns `{:ok, {valid?, message}}`. Options: `:format` (`:shexc` default or `:shexj`) and `:base`."
  def check_shex(session, source, opts \\ []) do
    with :ok <- Rudof.Options.validate([source: source], source: :string),
         :ok <- Rudof.Options.validate(opts, format: [:shexc, :shexj], base: :optional_string) do
      check_shex_schema(session, source, Keyword.put_new(opts, :format, :shexc))
    end
  end

  defp call(%Rudof.Session{pid: pid}, operation, args \\ []) do
    unit(Rudof.Session.Server.call(pid, {operation, args}))
  end

  defp api_value({kind, value}) do
    %{kind: kind, value: value}
  end

  defp api_value(:stdin) do
    %{kind: :stdin}
  end

  defp api_value(values) when :erlang.is_list(values) do
    Enum.map(values, &api_value/1)
  end

  defp api_value(value) do
    value
  end

  defp api_options(session, operation, args, opts, rules) do
    with :ok <- Rudof.Options.validate(args, rules),
         :ok <- Rudof.Options.validate(opts, Keyword.drop(rules, Keyword.keys(args))) do
      options = Map.new(:erlang.++(args, opts), fn {key, value} -> {key, api_value(value)} end)
      call(session, :api_call, [operation, options])
    end
  end

  defp api_input(session, operation, input, opts, rules) do
    api_options(session, operation, [input: input], opts, :erlang.++([input: :input], rules))
  end

  defp api_call(session, operation, opts \\ [], rules \\ []) do
    api_options(session, operation, [], opts, rules)
  end

  @doc "Adds or replaces a default prefix (alias without `:`), following upstream semantics."
  def add_prefix(session, alias, iri) do
    prefix(session, "add", alias, iri)
  end

  @doc "Adds an association to the current ShapeMap, creating it if absent. Omitted shape selects START.\nOptions: shape, base, base_nodes, base_shapes, iri_mode (:lax default or :strict).\n"
  def add_node_shape_to_shapemap(session, node, opts \\ []) do
    api_options(session, "add_node_shape_to_shapemap", [node: node], opts,
      node: :string,
      shape: :string,
      base: :optional_string,
      base_nodes: :optional_string,
      base_shapes: :optional_string,
      iri_mode: [:strict, :lax]
    )
  end

  @doc "Prepends an upstream external resolver specification, such as `reject-all` or `schema:/path/schema.shex`. Configure before loading a schema so its validator uses the registry.\n"
  def add_external_resolver(session, spec) do
    api_call(session, "add_external_resolver", [spec: spec], spec: :string)
  end
end
