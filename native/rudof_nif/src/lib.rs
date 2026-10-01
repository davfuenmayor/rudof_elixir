mod api;
mod config;
mod inspection;
mod reports;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

use rudof_lib::{Rudof, RudofConfig, config::CommonConfig};
use rustler::{Atom, Encoder, Env, NifException, Resource, ResourceArc, Term};

mod atoms {
    rustler::atoms! { ok, error, closed, poisoned, invalid_argument, native_error, panic, config_error, input_error, data_error, shapemap_error, shex_error, shacl_error, pg_schema_error, pg_db_error, validation_error, node_inspection_error, conversion_error, comparison_error, rdf_config_error, service_error, query_error, generate_error, iri_error, map_state_error, materialize_error, prefixes_error, dctap_error, unsupported_operation }
}

#[derive(Debug, NifException)]
#[module = "Rudof.Error"]
pub struct Error {
    pub kind: Atom,
    pub message: String,
}

impl Error {
    fn new(kind: Atom, message: impl ToString) -> Self {
        Self {
            kind,
            message: message.to_string(),
        }
    }

    pub fn invalid(message: impl ToString) -> Self {
        Self::new(atoms::invalid_argument(), message)
    }

    pub fn native(message: impl ToString) -> Self {
        Self::new(atoms::native_error(), message)
    }
}

impl From<rudof_lib::errors::RudofError> for Error {
    fn from(error: rudof_lib::errors::RudofError) -> Self {
        use rudof_lib::errors::RudofError::*;
        let kind = match &error {
            Config(..) => atoms::config_error(),
            InputSpec(..) => atoms::input_error(),
            Data(..) => atoms::data_error(),
            ShapeMap(..) => atoms::shapemap_error(),
            ShEx(..) => atoms::shex_error(),
            Shacl(..) => atoms::shacl_error(),
            PgSchema(..) => atoms::pg_schema_error(),
            PgDb(..) => atoms::pg_db_error(),
            Validation(..) => atoms::validation_error(),
            NodeInspection(..) => atoms::node_inspection_error(),
            Conversion(..) => atoms::conversion_error(),
            Comparison(..) => atoms::comparison_error(),
            RdfConfig(..) => atoms::rdf_config_error(),
            Service(..) => atoms::service_error(),
            Query(..) => atoms::query_error(),
            Generate(..) => atoms::generate_error(),
            Iri(..) => atoms::iri_error(),
            MapState(..) => atoms::map_state_error(),
            Materialize(..) => atoms::materialize_error(),
            Prefixes(..) => atoms::prefixes_error(),
            DCTap(..) => atoms::dctap_error(),
            UnsupportedResultQueryFormatSelect { .. } => atoms::query_error(),
            NotImplemented { .. } => atoms::unsupported_operation(),
            Generic { .. } => atoms::native_error(),
        };
        Self::new(kind, error)
    }
}

type Result<T> = std::result::Result<T, Error>;

pub struct Session(Mutex<Option<Rudof>>);

#[rustler::resource_impl]
impl Resource for Session {}

fn with_session<T>(resource: &Session, f: impl FnOnce(&mut Rudof) -> Result<T>) -> Result<T> {
    let mut guard = resource.0.lock().map_err(|_| {
        Error::new(
            atoms::poisoned(),
            "session is poisoned; close it and create a new one",
        )
    })?;
    let rudof = guard
        .as_mut()
        .ok_or_else(|| Error::new(atoms::closed(), "session is closed"))?;
    f(rudof)
}

fn respond<'a, T: Encoder>(env: Env<'a>, f: impl FnOnce() -> Result<T>) -> Term<'a> {
    // JSON-LD parsing needs a larger stack than the dirty scheduler provides.
    // Keep the work on the calling thread, but give upstream a normal native
    // stack without requiring VM flags. Catch unwinding before leaving it.
    let result = stacker::maybe_grow(8 * 1024 * 1024, 8 * 1024 * 1024, || {
        catch_unwind(AssertUnwindSafe(f))
    });
    match result {
        Ok(Ok(value)) => (atoms::ok(), value).encode(env),
        Ok(Err(error)) => (atoms::error(), error).encode(env),
        Err(payload) => {
            let message = payload
                .downcast_ref::<String>()
                .map(String::as_str)
                .or_else(|| payload.downcast_ref::<&str>().copied())
                .unwrap_or("native panic");
            (atoms::error(), Error::new(atoms::panic(), message)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new<'a>(env: Env<'a>, config: Option<String>) -> Term<'a> {
    respond(env, || {
        let mut config = match config {
            Some(text) => config::load(&text)?,
            None => {
                RudofConfig::default().with_common(CommonConfig::default().with_auto_base(true))
            }
        };
        config.resolve();
        Ok(ResourceArc::new(Session(Mutex::new(Some(Rudof::new(
            config,
        ))))))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn close<'a>(env: Env<'a>, session: ResourceArc<Session>) -> Term<'a> {
    respond(env, || {
        // Even a poisoned session must be releasable. Closing is idempotent.
        let mut guard = session.0.lock().unwrap_or_else(|error| error.into_inner());
        guard.take();
        session.0.clear_poison();
        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn version<'a>(env: Env<'a>, session: ResourceArc<Session>) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| Ok(r.version().execute().to_string()))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reset<'a>(env: Env<'a>, session: ResourceArc<Session>, kind: String) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| {
            match kind.as_str() {
                "all" => r.reset_all().execute(),
                "data" => r.reset_data().execute(),
                "shex" => r.reset_shex().execute(),
                "shacl" => r.reset_shacl().execute(),
                "shapemap" => r.reset_shapemap().execute(),
                "dctap" => r.reset_dctap().execute(),
                "service_description" => r.reset_service_description().execute(),
                "shex_schema" => r.reset_shex_schema().execute(),
                "shacl_shapes" => r.reset_shacl_shapes().execute(),
                "sparql_query" => r.reset_sparql_query().execute(),
                "query_results" => r.reset_query_results().execute(),
                "rdf_config" => r.reset_rdf_config().execute(),
                "pg_schema" => r.reset_pg_schema().execute(),
                "typemap" => r.reset_typemap().execute(),
                "pg_schema_validation" => r.reset_pg_schema_validation().execute(),
                "pg_db_connection" => r.reset_pg_db_connection().execute(),
                _ => return Err(Error::invalid("unknown reset target")),
            }
            Ok(atoms::ok())
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_endpoints<'a>(env: Env<'a>, session: ResourceArc<Session>) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| Ok(r.list_endpoints().execute()?))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prefixes<'a>(env: Env<'a>, session: ResourceArc<Session>) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| {
            Ok(r.prefixes()
                .execute()
                .iter()
                .map(|(alias, iri)| (alias.clone(), iri.to_string()))
                .collect::<Vec<_>>())
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prefix<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    operation: String,
    alias: String,
    value: String,
) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| {
            match operation.as_str() {
                "add" => r.add_prefix(&alias, &value).execute()?,
                "remove" => r.remove_prefix(&alias).execute()?,
                "rename" => r.rename_prefix(&alias, &value).execute()?,
                "copy" => r.copy_prefix(&alias, &value).execute()?,
                _ => return Err(Error::invalid("unknown prefix operation")),
            }
            Ok(atoms::ok())
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn node_info<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    node: String,
    opts: inspection::Options,
) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| inspection::info(r, &node, opts))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn node_neighborhood<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    node: String,
    opts: inspection::Options,
) -> Term<'a> {
    respond(env, || {
        with_session(&session, |r| inspection::neighborhood(r, &node, opts))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn api_call<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    operation: String,
    options: String,
) -> Term<'a> {
    respond(env, || {
        let args = api::Args(serde_json::from_str(&options).map_err(Error::invalid)?);
        with_session(&session, |r| api::call(r, env, &operation, &args))
    })
}

rustler::init!("Elixir.Rudof.Native");
