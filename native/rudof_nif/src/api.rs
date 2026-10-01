//! Direct bindings for the public Rudof facade. JSON carries validated options;
//! RDF/schema parsing and all operations remain in upstream Rust.
use crate::{Error, Result, atoms, reports};
use rudof_lib::{DataStats, Rudof, formats::*};
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    fmt::{Debug, Display},
    path::Path,
    str::FromStr,
};

pub(crate) fn parse<T: FromStr>(value: &str) -> Result<T>
where
    T::Err: Display,
{
    value.parse().map_err(Error::invalid)
}

pub struct Args(pub Value);
impl Args {
    pub fn string(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(Value::as_str)
    }
    pub fn required(&self, key: &str) -> Result<&str> {
        self.string(key)
            .ok_or_else(|| Error::invalid(format!("missing {key}")))
    }
    pub fn boolean(&self, key: &str) -> Option<bool> {
        self.0.get(key).and_then(Value::as_bool)
    }
    pub fn parse<T: FromStr>(&self, key: &str) -> Result<Option<T>>
    where
        T::Err: Display,
    {
        self.string(key).map(parse).transpose()
    }
    pub fn input(&self, key: &str) -> Result<Option<InputSpec>> {
        self.0
            .get(key)
            .filter(|v| !v.is_null())
            .map(input)
            .transpose()
    }
    pub fn inputs(&self, key: &str) -> Result<Vec<InputSpec>> {
        match self.0.get(key) {
            Some(Value::Array(v)) => v.iter().map(input).collect(),
            None => Ok(vec![]),
            _ => Err(Error::invalid(format!("{key} must be a list"))),
        }
    }
}
fn input(value: &Value) -> Result<InputSpec> {
    if let Some(s) = value.as_str() {
        return Ok(InputSpec::str(s));
    }
    let kind = value.get("kind").and_then(Value::as_str);
    let value = value.get("value").and_then(Value::as_str).unwrap_or("");
    match kind {
        Some("file") => Ok(InputSpec::path(value)),
        Some("url") => Ok(InputSpec::Url(
            UrlSpec::parse(value).map_err(Error::invalid)?,
        )),
        Some("string") => Ok(InputSpec::str(value)),
        Some("stdin") => Ok(InputSpec::Stdin),
        _ => Err(Error::invalid("invalid input specification")),
    }
}
pub fn json_text(value: impl Serialize) -> Result<String> {
    serde_json::to_string(&value).map_err(Error::native)
}
fn optional_json(value: Option<&impl Serialize>) -> Result<Option<String>> {
    value.map(json_text).transpose()
}
fn bytes<'a>(env: Env<'a>, data: &[u8]) -> Result<Term<'a>> {
    let mut binary = rustler::OwnedBinary::new(data.len())
        .ok_or_else(|| Error::native("cannot allocate output"))?;
    binary.as_mut_slice().copy_from_slice(data);
    Ok(binary.release(env).encode(env))
}
trait ObjectValue: Debug + Display + Send + Sync {}
impl<T: Debug + Display + Send + Sync> ObjectValue for T {}
pub struct Object(Box<dyn ObjectValue>);
#[rustler::resource_impl]
impl Resource for Object {}
#[derive(rustler::NifStruct)]
#[module = "Rudof.Object"]
pub struct ObjectHandle {
    kind: String,
    reference: ResourceArc<Object>,
}
fn object<T: ObjectValue + Clone + 'static>(kind: &str, value: Option<&T>) -> Option<ObjectHandle> {
    value.map(|value| ObjectHandle {
        kind: kind.into(),
        reference: ResourceArc::new(Object(Box::new(value.clone()))),
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn object_text<'a>(env: Env<'a>, object: ResourceArc<Object>, debug: bool) -> Term<'a> {
    crate::respond(env, || {
        Ok(if debug {
            format!("{:?}", object.0)
        } else {
            object.0.to_string()
        })
    })
}

pub fn call<'a>(r: &mut Rudof, env: Env<'a>, op: &str, o: &Args) -> Result<Term<'a>> {
    let mut output = Vec::new();
    match op {
        "render_snapshot" => {
            let op = o.required("operation")?;
            let (kind, source) = match op {
                "serialize_data" => ("data", data_source(r)?),
                "serialize_shex_schema" => ("shex", json_text(r.shex_schema().ok_or_else(||
                    Error::new(atoms::shex_error(), "rendering requires a source ShEx schema"))?)?),
                "show_schema_conversion" => {
                    let mut options = o.0.clone();
                    options["to"] = json!("shex");
                    options["output_format"] = json!("shexj");
                    // Presentation options must not contaminate the JSON transport.
                    options.as_object_mut().unwrap().remove("shape");
                    options["show_time"] = json!(false);
                    let mut out = Vec::new();
                    conversion(r, &Args(options), &mut out)?;
                    ("conversion", json_text(r.shex_schema().ok_or_else(||
                        Error::new(atoms::shex_error(), "conversion produced no ShEx schema"))?)?)
                }
                _ => return Err(Error::invalid("invalid image operation")),
            };
            return Ok(json_text(json!({"kind":kind, "source":source, "config":r.config().execute(),
                "format":o.string("format").or(o.string("output_format")), "engine":o.string("viz_engine").unwrap_or("plantuml"), "options":o.0}))?.encode(env));
        }
        "has_data" => return Ok(r.has_data().encode(env)),
        "has_sparql_query" => return Ok(r.has_sparql_query().encode(env)),
        "shex_schema_shapes_count" => return Ok(r.shex_schema_shapes_count().encode(env)),
        "data_stats" => {
            let stats = r.data_stats().map(|s| match s {
                DataStats::Rdf { triples } => json!({"kind": "rdf", "triples": triples}),
                DataStats::Pg { nodes, edges } => json!({"kind": "pg", "nodes": nodes, "edges": edges}),
            });
            return Ok(stats.map(json_text).transpose()?.encode(env));
        }
        "config" => return Ok(json_text(r.config().execute())?.encode(env)),
        "update_config" => {
            let config = crate::config::load(o.required("config")?).map_err(|e| Error::new(atoms::config_error(), e.message))?;
            r.update_config(config).execute();
        }
        "shex_schema" => return Ok(optional_json(r.shex_schema())?.encode(env)),
        "shacl_shapes" => return Ok(object("shacl_shapes", r.shacl_shapes()).encode(env)),
        "pg_schema" => return Ok(object("pg_schema", r.pg_schema()).encode(env)),
        "dctap" => return Ok(optional_json(r.dctap())?.encode(env)),
        "service_description" => return Ok(optional_json(r.service_description())?.encode(env)),
        "pgschema_validation_results" => return Ok(optional_json(r.pgschema_validation_results())?.encode(env)),
        "query_results" => return Ok(r.query_results().map(|v| reports::query(v, env)).encode(env)),
        "shex_validation_results" => return Ok(r.shex_validation_results().map(reports::shex).encode(env)),
        "shacl_validation_results" => return Ok(r.shacl_validation_results().map(reports::shacl).encode(env)),
        "query" => {
            load(r, "load_sparql_query", o)?;
            r.run_query().execute()?;
            return r.query_results()
                .map(|result| reports::query(result, env))
                .ok_or_else(|| Error::native("query produced no results"));
        }
        "validate_shex" => {
            r.validate_shex().execute()?;
            return r.shex_validation_results()
                .map(|result| reports::shex(result).encode(env))
                .ok_or_else(|| Error::native("ShEx validation produced no results"));
        }
        "validate_shacl" => {
            r.validate_shacl()
                .with_shacl_validation_mode(&parse(o.string("mode").unwrap_or("native"))?)
                .execute()?;
            return r.shacl_validation_results()
                .map(|result| reports::shacl(result).encode(env))
                .ok_or_else(|| Error::native("SHACL validation produced no results"));
        }
        "run_query" => {
            let format = o.parse("format")?;
            let mut b = r.run_query();
            if let Some(v) = &format { b = b.with_result_query_format(v); }
            b.execute()?;
        }
        "add_external_resolver" => { r.add_external_resolver(o.required("spec")?)?; }
        "clear_external_resolvers" => r.clear_external_resolvers(),
        "list_external_resolvers" => return Ok(json_text(Rudof::list_external_resolvers().iter().map(|v|
            json!({"name":v.name,"description":v.description,"spec_syntax":v.spec_syntax})).collect::<Vec<_>>())?.encode(env)),
        "add_node_shape_to_shapemap" => {
            let mut b = r.add_node_shape_to_shapemap(o.required("node")?);
            if let Some(v) = o.string("shape") { b = b.with_shape(v); }
            if let Some(v) = o.string("base_nodes").or(o.string("base")) { b = b.with_base_nodes(v); }
            if let Some(v) = o.string("base_shapes").or(o.string("base")) { b = b.with_base_shapes(v); }
            if let Some(v) = o.string("iri_mode") { b = b.with_iri_mode(iri_mode(v)?); }
            b.execute()?;
        }
        "load_map_state" => r.load_map_state(Path::new(o.required("path")?)).execute()?,
        "serialize_map_state" => { r.serialize_map_state(&mut output).execute()?; return bytes(env, &output); }
        "serialize_sparql_query" => { r.serialize_sparql_query(&mut output).execute()?; return bytes(env, &output); }
        "materialize" => {
            let format = o.parse("format")?;
            let mut b = r.materialize(&mut output);
            if let Some(v) = o.string("initial_node_iri") { b = b.with_initial_node_iri(v); }
            if let Some(v) = &format { b = b.with_result_format(v); }
            b.execute()?;
            return bytes(env, &output);
        }
        "dereference" => {
            let reader = o.parse("reader_mode")?;
            let mut b = r.dereference(o.required("uri")?);
            if let Some(v) = &reader { b = b.with_reader_mode(v); }
            if let Some(v) = o.boolean("merge") { b = b.with_merge(v); }
            b.execute()?;
            if o.boolean("merge").unwrap_or(true) {
                refresh_data(r)?;
            }
        }
        "generate_data" => generate(r, o)?,
        "validate_pgschema" => r.validate_pgschema().execute()?,
        "load_data" => load_data(r, o)?,
        op if op.starts_with("load_") && !matches!(op, "load_pg_db") => load(r, op, o)?,
        op if op.starts_with("serialize_") => { serialize(r, op, o, &mut output)?; return bytes(env, &output); }
        "show_schema_conversion" => { conversion(r, o, &mut output)?; return bytes(env, &output); }
        "show_schema_comparison" => { comparison(r, o, &mut output)?; return bytes(env, &output); }
        "check_shex_schema" => {
            let input = o.input("input")?.ok_or_else(|| Error::invalid("missing input"))?;
            let format = o.parse("format")?;
            let mut b = r.check_shex_schema(&input, &mut output);
            if let Some(v) = &format { b = b.with_shex_schema_format(v); }
            if let Some(v) = o.string("base") { b = b.with_base(v); }
            let valid = b.execute()?;
            return Ok((valid, bytes(env, &output)?).encode(env));
        }
        "compile_shex_schema_to_file" => {
            r.compile_shex_schema_to_file(&mut output).execute()?;
            std::fs::write(o.required("path")?, output).map_err(Error::native)?;
        }
        "connect_pg_db" | "pg_db_ddl" | "load_pg_db" | "query_cypher" | "pg_db_connection" => return database(r, env, op, o),
        _ => return Err(Error::invalid(format!("unknown operation {op}"))),
    }
    Ok(atoms::ok().encode(env))
}

fn load(r: &mut Rudof, op: &str, o: &Args) -> Result<()> {
    let input = o.input("input")?;
    let required = || {
        input
            .as_ref()
            .ok_or_else(|| Error::invalid("missing input"))
    };
    let reader = o.parse("reader_mode")?;
    match op {
        "load_shex_schema" => {
            let format = o.parse("format")?;
            let mut b = r.load_shex_schema(required()?);
            if let Some(v) = &format {
                b = b.with_shex_schema_format(v);
            }
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            if let Some(v) = o.string("base") {
                b = b.with_base(v);
            }
            b.execute()?;
        }
        "load_shex_schema_precompiled" => {
            let mut b = r.load_shex_schema_precompiled(required()?);
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            b.execute()?;
        }
        "load_shacl_shapes" => {
            let format = o.parse("format")?;
            let mut b = r.load_shacl_shapes();
            if let Some(v) = &input {
                b = b.with_shacl_schema(v);
            }
            if let Some(v) = &format {
                b = b.with_shacl_schema_format(v);
            }
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            if let Some(v) = o.string("base") {
                b = b.with_base(v);
            }
            b.execute()?;
        }
        "load_shapemap" => {
            let format: Option<ShapeMapFormat> = o.parse("format")?;
            if format.is_some_and(|v| v != ShapeMapFormat::Compact) {
                return Err(Error::new(
                    atoms::unsupported_operation(),
                    "upstream ShapeMap input supports compact only",
                ));
            }
            let mut b = r.load_shapemap(required()?);
            if let Some(v) = &format {
                b = b.with_shapemap_format(v);
            }
            if let Some(v) = o.string("base_nodes").or(o.string("base")) {
                b = b.with_base_nodes(v);
            }
            if let Some(v) = o.string("base_shapes").or(o.string("base")) {
                b = b.with_base_shapes(v);
            }
            b.execute()?;
        }
        "load_sparql_query" => {
            let query_type = o.parse("query_type")?;
            let mut b = r.load_sparql_query(required()?);
            if let Some(v) = &query_type {
                b = b.with_query_type(v);
            }
            b.execute()?;
        }
        "load_service_description" => {
            let format = o.parse("format")?;
            let mut b = r.load_service_description(required()?);
            if let Some(v) = &format {
                b = b.with_data_format(v);
            }
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            if let Some(v) = o.string("base") {
                b = b.with_base(v);
            }
            b.execute()?;
        }
        "load_dctap" => {
            let format = o.parse("format")?;
            let mut b = r.load_dctap(required()?);
            if let Some(v) = &format {
                b = b.with_dctap_format(v);
            }
            b.execute()?;
        }
        "load_rdf_config" => {
            let format = o.parse("format")?;
            let mut b = r.load_rdf_config(required()?);
            if let Some(v) = &format {
                b = b.with_rdf_config_format(v);
            }
            b.execute()?;
        }
        "load_pg_schema" => {
            let format = o.parse("format")?;
            let mut b = r.load_pg_schema(required()?);
            if let Some(v) = &format {
                b = b.with_pg_schema_format(v);
            }
            b.execute()?;
        }
        "load_typemap" => {
            r.load_typemap(required()?).execute()?;
        }
        _ => return Err(Error::invalid("unknown loader")),
    }
    Ok(())
}
fn backend(value: &str) -> Result<BackendSpec> {
    match value {
        "memory" => Ok(BackendSpec::Memory),
        "qlever" => Ok(BackendSpec::Qlever),
        "lbug" => Ok(BackendSpec::Lbug),
        _ => Err(Error::invalid("unknown backend")),
    }
}
fn load_data(r: &mut Rudof, o: &Args) -> Result<()> {
    let inputs = o.inputs("inputs")?;
    let prefixes = o.inputs("prefixes")?;
    let format = o.parse("format")?;
    let reader = o.parse("reader_mode")?;
    let mut b = r.load_data();
    if o.string("endpoint").is_none() || !inputs.is_empty() {
        b = b.with_data(&inputs);
    }
    if let Some(v) = &format {
        b = b.with_data_format(v);
    }
    if let Some(v) = &reader {
        b = b.with_reader_mode(v);
    }
    if let Some(v) = o.string("base") {
        b = b.with_base(v);
    }
    if let Some(v) = o.boolean("merge") {
        b = b.with_merge(v);
    }
    if let Some(v) = o.string("backend") {
        b = b.with_backend(backend(v)?);
    }
    if let Some(v) = o.string("endpoint") {
        b = b.with_endpoint(v);
    }
    if let Some(v) = o.parse("endpoint_strategy")? {
        b = b.with_endpoint_strategy(v);
    }
    if !prefixes.is_empty() {
        b = b.with_prefixes(&prefixes);
    }
    b.execute()?;
    if !inputs.is_empty()
        && o.boolean("merge").unwrap_or(true)
        && o.string("endpoint").is_none()
        && o.string("backend").is_none_or(|v| v == "memory")
        && matches!(r.data_stats(), Some(DataStats::Rdf { .. }))
    {
        refresh_data(r)?;
    }
    Ok(())
}

fn serialize(r: &mut Rudof, op: &str, o: &Args, output: &mut Vec<u8>) -> Result<()> {
    let viz = o.parse("viz_engine")?;
    match op {
        "serialize_data" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_data(output);
            if let Some(v) = &format {
                b = b.with_result_data_format(v);
            }
            if let Some(v) = &viz {
                b = b.with_viz_engine(v);
            }
            b.execute()?;
        }
        "serialize_shex_schema" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_shex_schema(output);
            if let Some(v) = &format {
                b = b.with_result_shex_format(v);
            }
            if let Some(v) = &viz {
                b = b.with_viz_engine(v);
            }
            if let Some(v) = o.string("shape") {
                b = b.with_shape(v);
            }
            if let Some(v) = o.boolean("show_schema") {
                b = b.with_show_schema(v);
            }
            if let Some(v) = o.boolean("show_statistics") {
                b = b.with_show_statistics(v);
            }
            if let Some(v) = o.boolean("show_dependencies") {
                b = b.with_show_dependencies(v);
            }
            if let Some(v) = o.boolean("show_time") {
                b = b.with_show_time(v);
            }
            b.execute()?;
        }
        "serialize_shacl_shapes" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_shacl_shapes(output);
            if let Some(v) = &format {
                b = b.with_shacl_result_format(v);
            }
            b.execute()?;
        }
        "serialize_shapemap" => {
            let format: Option<ShapeMapFormat> = o.parse("format")?;
            if format.is_some_and(|v| !matches!(v, ShapeMapFormat::Compact | ShapeMapFormat::Json))
            {
                return Err(Error::new(
                    atoms::unsupported_operation(),
                    "upstream ShapeMap output supports compact and JSON only",
                ));
            }
            let mut b = r.serialize_shapemap(output);
            if let Some(v) = &format {
                b = b.with_result_shapemap_format(v);
            }
            if let Some(v) = o.boolean("show_colors") {
                b = b.with_show_colors(v);
            }
            b.execute()?;
        }
        "serialize_query_results" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_query_results(output);
            if let Some(v) = &format {
                b = b.with_result_query_format(v);
            }
            b.execute()?;
        }
        "serialize_shex_validation_results" => {
            let format = o.parse("format")?;
            let sort = o.parse("sort_by")?;
            let mut b = r.serialize_shex_validation_results(output);
            if let Some(v) = &format {
                b = b.with_result_shex_validation_format(v);
            }
            if let Some(v) = &sort {
                b = b.with_shex_validation_sort_order_mode(v);
            }
            b.execute()?;
        }
        "serialize_shacl_validation_results" => {
            let format = o.parse("format")?;
            let sort = o.parse("sort_by")?;
            let mut b = r.serialize_shacl_validation_results(output);
            if let Some(v) = &format {
                b = b.with_result_shacl_validation_format(v);
            }
            if let Some(v) = &sort {
                b = b.with_shacl_validation_sort_order_mode(v);
            }
            b.execute()?;
        }
        "serialize_dctap" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_dctap(output);
            if let Some(v) = &format {
                b = b.with_result_dctap_format(v);
            }
            b.execute()?;
        }
        "serialize_service_description" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_service_description(output);
            if let Some(v) = &format {
                b = b.with_result_service_format(v);
            }
            b.execute()?;
        }
        "serialize_rdf_config" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_rdf_config(output);
            if let Some(v) = &format {
                b = b.with_result_rdf_config_format(v);
            }
            b.execute()?;
        }
        "serialize_pg_schema" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_pg_schema(output);
            if let Some(v) = &format {
                b = b.with_result_pg_schema_format(v);
            }
            b.execute()?;
        }
        "serialize_pgschema_validation_results" => {
            let format = o.parse("format")?;
            let mut b = r.serialize_pgschema_validation_results(output);
            if let Some(v) = &format {
                b = b.with_result_pg_schema_validation_format(v);
            }
            if let Some(v) = o.boolean("show_colors") {
                b = b.with_show_colors(v);
            }
            b.execute()?;
        }
        _ => return Err(Error::invalid("unknown serializer")),
    }
    Ok(())
}
fn conversion(r: &mut Rudof, o: &Args, output: &mut Vec<u8>) -> Result<()> {
    let input = o
        .input("input")?
        .ok_or_else(|| Error::invalid("missing input"))?;
    let from = parse(o.required("from")?)?;
    let to = parse(o.required("to")?)?;
    let input_format = parse(o.required("input_format")?)?;
    let output_format = parse(o.required("output_format")?)?;
    let reader = o.parse("reader_mode")?;
    let viz = o.parse("viz_engine")?;
    let mut b = r.show_schema_conversion(&input, &from, &to, &input_format, &output_format, output);
    if let Some(v) = o.string("base") {
        b = b.with_base(v);
    }
    if let Some(v) = o.string("shape") {
        b = b.with_shape(v);
    }
    if let Some(v) = &reader {
        b = b.with_reader_mode(v);
    }
    if let Some(v) = &viz {
        b = b.with_viz_engine(v);
    }
    if let Some(v) = o.boolean("show_time") {
        b = b.with_show_time(v);
    }
    if let Some(v) = o.string("templates_folder") {
        b = b.with_templates_folder(Path::new(v));
    }
    if let Some(v) = o.string("output_folder") {
        b = b.with_output_folder(Path::new(v));
    }
    b.execute()?;
    Ok(())
}
fn comparison(r: &mut Rudof, o: &Args, output: &mut Vec<u8>) -> Result<()> {
    let left = o
        .input("left")?
        .ok_or_else(|| Error::invalid("missing left input"))?;
    let right = o
        .input("right")?
        .ok_or_else(|| Error::invalid("missing right input"))?;
    let mode1 = o.parse("mode1")?.unwrap_or(ComparisonMode::ShEx);
    let mode2 = o.parse("mode2")?.unwrap_or(ComparisonMode::ShEx);
    if mode1 != ComparisonMode::ShEx || mode2 != ComparisonMode::ShEx {
        return Err(Error::new(
            atoms::unsupported_operation(),
            "upstream comparisons of SHACL, DCTAP and service descriptions are unimplemented",
        ));
    }
    let format1 = o.parse("format1")?.unwrap_or(ComparisonFormat::ShExC);
    let format2 = o.parse("format2")?.unwrap_or(ComparisonFormat::ShExC);
    if [format1, format2]
        .iter()
        .any(|f| !matches!(f, ComparisonFormat::ShExC | ComparisonFormat::ShExJ))
    {
        return Err(Error::new(
            atoms::unsupported_operation(),
            "upstream ShEx comparison supports shexc and shexj input only",
        ));
    }
    let result = o.parse("output_format")?;
    let reader = o.parse("reader_mode")?;
    let mut b = r.show_schema_comparison(&left, &right, &format1, &format2, &mode1, &mode2, output);
    if let Some(v) = &result {
        b = b.with_result_format(v);
    }
    if let Some(v) = &reader {
        b = b.with_reader_mode(v);
    }
    if let Some(v) = o.string("base1") {
        b = b.with_base1(v);
    }
    if let Some(v) = o.string("base2") {
        b = b.with_base2(v);
    }
    if let Some(v) = o.string("shape1") {
        b = b.with_shape1(v);
    }
    if let Some(v) = o.string("shape2") {
        b = b.with_shape2(v);
    }
    if let Some(v) = o.boolean("show_time") {
        b = b.with_show_time(v);
    }
    b.execute()?;
    Ok(())
}
fn database<'a>(r: &mut Rudof, env: Env<'a>, op: &str, o: &Args) -> Result<Term<'a>> {
    match op {
        "pg_db_connection" => Ok(r
            .pg_db_connection()
            .map(|v| {
                json_text(json!({
                    "engine":v.engine.to_string(),"path":v.path,"read_only":v.read_only
                }))
            })
            .transpose()?
            .encode(env)),
        "connect_pg_db" => {
            let engine = o.string("engine").map(backend).transpose()?;
            let mut b = r.connect_pg_db(o.string("path").map(Path::new));
            if let Some(v) = &engine {
                b = b.with_engine(v);
            }
            if let Some(v) = o.boolean("in_memory") {
                b = b.with_in_memory(v);
            }
            if let Some(v) = o.boolean("read_only") {
                b = b.with_read_only(v);
            }
            let result = b.execute()?;
            Ok(json_text(json!({"storage_version":result.storage_version,"library_source":result.library_source}))?.encode(env))
        }
        "query_cypher" => {
            let input = o
                .input("input")?
                .ok_or_else(|| Error::invalid("missing input"))?;
            let mut b = r.query_cypher(&input);
            if let Some(v) = o.string("db") {
                b = b.with_db(Path::new(v), o.boolean("read_only").unwrap_or(false));
            }
            Ok(json_text(b.execute()?)?.encode(env))
        }
        "pg_db_ddl" => {
            let inputs = o.inputs("inputs")?;
            let format = o.parse("format")?;
            let reader = o.parse("reader_mode")?;
            let dialect = o.parse("dialect")?;
            let mut b = r.pg_db_ddl(&inputs);
            if let Some(v) = &format {
                b = b.with_data_format(v);
            }
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            if let Some(v) = &dialect {
                b = b.with_dialect(v);
            }
            if let Some(v) = o.string("base") {
                b = b.with_base_data(v);
            }
            if let Some(v) = o.string("graph_type_name") {
                b = b.with_graph_type_name(v);
            }
            Ok(b.execute()?.encode(env))
        }
        "load_pg_db" => {
            let inputs = o.inputs("inputs")?;
            let shapes = o.input("shapes")?;
            let format = o.parse("format")?;
            let shapes_format = o.parse("shapes_format")?;
            let reader = o.parse("reader_mode")?;
            let mut output = Vec::new();
            let mut b = r.load_pg_db(&inputs, &mut output);
            if let Some(v) = o.string("db") {
                b = b.with_db(Path::new(v), o.boolean("read_only").unwrap_or(false));
            }
            if let Some(v) = &shapes {
                b = b.with_shapes(v);
            }
            if let Some(v) = &format {
                b = b.with_data_format(v);
            }
            if let Some(v) = &shapes_format {
                b = b.with_shapes_format(v);
            }
            if let Some(v) = &reader {
                b = b.with_reader_mode(v);
            }
            if let Some(v) = o.string("base") {
                b = b.with_base_data(v);
            }
            if let Some(v) = o.string("base_shapes") {
                b = b.with_base_shapes(v);
            }
            if let Some(v) = o.boolean("skip_validation") {
                b = b.with_skip_validation(v);
            }
            let (nodes, relationships) = b.execute()?;
            Ok((nodes, relationships, bytes(env, &output)?).encode(env))
        }
        _ => Err(Error::invalid("unknown database operation")),
    }
}

pub fn iri_mode(value: &str) -> Result<IriNormalizationMode> {
    match value {
        "strict" => Ok(IriNormalizationMode::Strict),
        "lax" => Ok(IriNormalizationMode::Lax),
        _ => Err(Error::invalid("invalid iri_mode")),
    }
}

fn generate(r: &mut Rudof, o: &Args) -> Result<()> {
    let schema = o
        .input("input")?
        .ok_or_else(|| Error::invalid("missing input"))?;
    let schema_format = o
        .parse("schema_format")?
        .unwrap_or(GenerationSchemaFormat::Auto);
    let format = o.parse("output_format")?;
    let output = o.string("output").map(std::path::PathBuf::from);
    let config = o.string("config_file").map(std::path::PathBuf::from);
    let entities =
        o.0.get("entities")
            .and_then(Value::as_u64)
            .map(|n| n as usize);
    let mut b = r.generate_data(&schema, &schema_format, entities);
    if let Some(v) = &format {
        b = b.with_result_generation_format(v);
    }
    if let Some(v) = &output {
        b = b.with_output(v);
    }
    if let Some(v) = &config {
        b = b.with_config_file(v);
    }
    if let Some(v) = o.0.get("seed").and_then(Value::as_u64) {
        b = b.with_seed(v);
    }
    if let Some(v) = o.0.get("parallel").and_then(Value::as_u64) {
        b = b.with_parallel(v as usize);
    }
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(Error::native)?
        .block_on(b.execute())?;
    Ok(())
}

fn data_source(r: &mut Rudof) -> Result<String> {
    let mut output = Vec::new();
    serialize(r, "serialize_data", &Args(json!({"format": "turtle"})), &mut output)?;
    String::from_utf8(output).map_err(Error::native)
}

// Rebuild the memory RDF view after a successful merge.
fn refresh_data(r: &mut Rudof) -> Result<()> {
    let source = data_source(r)?;
    load_data(r, &Args(json!({"inputs": [source], "format": "turtle", "merge": false})))
}
