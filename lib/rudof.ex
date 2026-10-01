defmodule Rudof do
  @moduledoc "RDF, SPARQL, ShEx and SHACL through the Rust rudof library.\n\nThese functions create and close a native session for each call. For repeated\nwork on the same data or schemas, use `Rudof.Session`.\n\n    iex> Rudof.query(\"<http://e/s> <http://e/p> 42 .\", \"ASK { ?s ?p ?o }\")\n    {:ok, %{kind: :ask, boolean: true}}\n\nFormats are atoms. Most inputs are source strings; read files with `File.read/1`.\n`generate/3` takes schema and output filenames as required by upstream.\nErrors are `{:error, %Rudof.Error{}}`. Validation failures are successful\nreports with `conforms: false`, distinct from parsing or execution errors.\n"
  @doc "Validates RDF against ShEx and a ShapeMap.\n\nOptions: `:data_format` (default `:turtle`), `:schema_format` (`:shexc` or\n`:shexj`), `:shapemap_format` (`:compact`), `:base`, and session configuration (`:path`, `:toml_str`, or keyword `:config`).\n"
  def validate_shex(data, schema, shapemap, opts \\ []) do
    rules =
      :erlang.++(
        [
          data_format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
          base: :optional_string,
          path: :string,
          toml_str: :string,
          config: :keyword
        ],
        schema_format: [:shexc, :shexj],
        shapemap_format: [:compact]
      )

    with :ok <- Rudof.Options.validate(opts, rules) do
      Rudof.Session.with_session(
        fn session ->
          with :ok <-
                 Rudof.Session.read_data(session, data, read_opts(opts, :data_format, :turtle)),
               :ok <-
                 Rudof.Session.read_shex(session, schema, read_opts(opts, :schema_format, :shexc)),
               :ok <-
                 Rudof.Session.read_shapemap(
                   session,
                   shapemap,
                   read_opts(opts, :shapemap_format, :compact)
                 ) do
            Rudof.Session.validate_shex(session)
          end
        end,
        Keyword.take(opts, Rudof.Config.keys())
      )
    end
  end

  @doc "Validates RDF against a SHACL shapes graph.\n\nOptions: `:data_format`, `:shapes_format` (both default to `:turtle`),\n`:mode` (`:native` or `:sparql`), `:base`, and session configuration (`:path`, `:toml_str`, or keyword `:config`).\n"
  def validate_shacl(data, shapes, opts \\ []) do
    with :ok <-
           Rudof.Options.validate(
             opts,
             :erlang.++(
               [
                 data_format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
                 base: :optional_string,
                 path: :string,
                 toml_str: :string,
                 config: :keyword
               ],
               shapes_format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
               mode: [:native, :sparql]
             )
           ) do
      Rudof.Session.with_session(
        fn session ->
          with :ok <-
                 Rudof.Session.read_data(session, data, read_opts(opts, :data_format, :turtle)),
               :ok <-
                 Rudof.Session.read_shacl(
                   session,
                   shapes,
                   read_opts(opts, :shapes_format, :turtle)
                 ) do
            Rudof.Session.validate_shacl(session, Keyword.take(opts, [:mode]))
          end
        end,
        Keyword.take(opts, Rudof.Config.keys())
      )
    end
  end

  defp read_opts(opts, format_key, default) do
    [format: Keyword.get(opts, format_key, default), base: Keyword.get(opts, :base)]
  end

  @doc "Runs a SPARQL query on RDF source. Options: `:data_format`, `:base`, and session configuration (`:path`, `:toml_str`, or keyword `:config`)."
  def query(data, query, opts \\ []) do
    with :ok <-
           Rudof.Options.validate(opts,
             data_format: [:turtle, :ntriples, :nquads, :trig, :n3, :rdfxml, :jsonld],
             base: :optional_string,
             path: :string,
             toml_str: :string,
             config: :keyword
           ) do
      Rudof.Session.with_session(
        fn session ->
          with :ok <-
                 Rudof.Session.read_data(session, data, read_opts(opts, :data_format, :turtle)) do
            Rudof.Session.query(session, query)
          end
        end,
        Keyword.take(opts, Rudof.Config.keys())
      )
    end
  end

  @doc "Generates RDF from a schema file to an output file. See `Rudof.Session.generate/4` for options and file effects."
  def generate(schema_path, output_path, opts \\ []) do
    Rudof.Session.with_session(fn session ->
      Rudof.Session.generate(session, schema_path, output_path, opts)
    end)
  end

  @doc "Converts schema source in a fresh session. See `Rudof.Session.convert_schema/5` for routes and options."
  def convert_schema(source, from, to, opts \\ []) do
    Rudof.Session.with_session(fn session ->
      Rudof.Session.convert_schema(session, source, from, to, opts)
    end)
  end

  @doc "Converts RDF between formats. Options: `:base` and session configuration (`:path`, `:toml_str`, or keyword `:config`)."
  def convert(data, from, to, opts \\ []) do
    with :ok <-
           Rudof.Options.validate(
             opts,
             :erlang.++([base: :optional_string], Rudof.Config.rules())
           ) do
      Rudof.Session.with_session(
        fn session ->
          with :ok <-
                 Rudof.Session.read_data(
                   session,
                   data,
                   :erlang.++([format: from], Keyword.take(opts, [:base]))
                 ) do
            Rudof.Session.serialize_data(session, to)
          end
        end,
        Keyword.take(opts, Rudof.Config.keys())
      )
    end
  end

  @doc "Compares ShEx source in a fresh session. See `Rudof.Session.compare_shex/4`."
  def compare_shex(left, right, opts \\ []) do
    Rudof.Session.with_session(fn session ->
      Rudof.Session.compare_shex(session, left, right, opts)
    end)
  end
end
