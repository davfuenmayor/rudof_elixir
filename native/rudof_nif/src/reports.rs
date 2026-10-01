use rudof_lib::types::{QueryResult, ResultShapeMap, ShExValidationStatus, ShaclValidationReport};
use rustler::{Atom, Encoder, Env, NifMap, Term};

mod atoms {
    rustler::atoms! { select, ask, graph, conformant, nonconformant, pending, inconsistent }
}

#[derive(NifMap)]
pub struct ShExReport {
    conforms: bool,
    entries: Vec<ShExEntry>,
}

#[derive(NifMap)]
struct ShExEntry {
    node: String,
    shape: String,
    status: Atom,
    details: Option<String>,
}

pub fn shex(results: &ResultShapeMap) -> ShExReport {
    let mut entries: Vec<_> = results
        .iter()
        .map(|(node, shape, status)| {
            let (status, details) = match status {
                ShExValidationStatus::Conformant(info) => {
                    (atoms::conformant(), Some(info.to_string()))
                }
                ShExValidationStatus::NonConformant(info) => {
                    (atoms::nonconformant(), Some(info.to_string()))
                }
                ShExValidationStatus::Pending => (atoms::pending(), None),
                ShExValidationStatus::Inconsistent(yes, no) => {
                    (atoms::inconsistent(), Some(format!("{yes}; {no}")))
                }
            };
            ShExEntry {
                node: node.to_string(),
                shape: shape.to_string(),
                status,
                details,
            }
        })
        .collect();
    entries.sort_by(|a, b| (&a.node, &a.shape).cmp(&(&b.node, &b.shape)));
    ShExReport {
        conforms: entries.iter().all(|e| e.status == atoms::conformant()),
        entries,
    }
}

#[derive(NifMap)]
pub struct ShaclReport {
    conforms: bool,
    results: Vec<ShaclEntry>,
}

#[derive(NifMap)]
struct ShaclEntry {
    focus_node: String,
    path: Option<String>,
    value: Option<String>,
    source_shape: Option<String>,
    constraint_component: String,
    severity: String,
    messages: Vec<Message>,
}

#[derive(NifMap)]
struct Message {
    text: String,
    lang: Option<String>,
}

pub fn shacl(report: &ShaclValidationReport) -> ShaclReport {
    let results = report
        .results()
        .iter()
        .map(|result| {
            let mut messages: Vec<_> = result
                .message()
                .iter()
                .map(|(lang, text)| Message {
                    text: text.clone(),
                    lang: lang.as_ref().map(ToString::to_string),
                })
                .collect();
            messages.sort_by(|a, b| a.lang.cmp(&b.lang));
            ShaclEntry {
                focus_node: result.focus_node().to_string(),
                path: result.path().map(ToString::to_string),
                value: result.value().map(ToString::to_string),
                source_shape: result.source().map(ToString::to_string),
                constraint_component: result.constraint_component().to_string(),
                severity: result.severity().to_string(),
                messages,
            }
        })
        .collect();
    ShaclReport {
        conforms: report.conforms(),
        results,
    }
}

#[derive(NifMap)]
struct Select {
    kind: Atom,
    variables: Vec<String>,
    rows: Vec<Vec<Option<String>>>,
}
#[derive(NifMap)]
struct Ask {
    kind: Atom,
    boolean: bool,
}
#[derive(NifMap)]
struct Graph {
    kind: Atom,
    graph: String,
}

pub fn query<'a>(result: &QueryResult, env: Env<'a>) -> Term<'a> {
    match result {
        QueryResult::Ask(boolean) => Ask {
            kind: atoms::ask(),
            boolean: *boolean,
        }
        .encode(env),
        QueryResult::Construct(graph) => Graph {
            kind: atoms::graph(),
            graph: graph.clone(),
        }
        .encode(env),
        QueryResult::Select(solutions) => {
            let variables = solutions
                .iter()
                .next()
                .map(|s| {
                    s.variables()
                        .iter()
                        .map(|v| v.to_string().trim_start_matches('?').to_owned())
                        .collect()
                })
                .unwrap_or_default();
            let rows = solutions
                .iter()
                .map(|s| {
                    (0..s.variables().len())
                        .map(|i| s.find_solution(i).map(ToString::to_string))
                        .collect()
                })
                .collect();
            Select {
                kind: atoms::select(),
                variables,
                rows,
            }
            .encode(env)
        }
    }
}
