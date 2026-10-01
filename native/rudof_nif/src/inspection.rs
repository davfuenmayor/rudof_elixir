use crate::{Error, Result, api::parse};
use rudof_lib::{Rudof, types::ArcDirection};
use rustler::{Atom, NifMap};

mod atoms {
    rustler::atoms! { outgoing, incoming }
}

#[derive(NifMap)]
pub struct Options {
    pub mode: String,
    pub depth: u64,
    pub predicates: Vec<String>,
    pub limit: Option<u64>,
    pub iri_mode: String,
    pub show_colors: bool,
    pub show_hyperlinks: bool,
}

#[derive(NifMap)]
pub struct Arc {
    root: String,
    node: String,
    predicate: String,
    neighbor: String,
    direction: Atom,
    depth: usize,
    is_last: bool,
}

#[derive(NifMap)]
pub struct Neighborhood {
    arcs: Vec<Arc>,
    truncated: bool,
}

pub fn info(r: &mut Rudof, node: &str, opts: Options) -> Result<String> {
    let mut output = Vec::new();
    r.show_node_info(node, &mut output)
        .with_predicates(&opts.predicates)
        .with_show_node_mode(&parse(&opts.mode)?)
        .with_depth(opts.depth as usize)
        .with_show_colors(opts.show_colors)
        .with_show_hyperlinks(opts.show_hyperlinks)
        .with_iri_mode(crate::api::iri_mode(&opts.iri_mode)?)
        .execute()?;
    String::from_utf8(output).map_err(Error::native)
}

pub fn neighborhood(r: &mut Rudof, node: &str, opts: Options) -> Result<Neighborhood> {
    let mode = parse(&opts.mode)?;
    let iter = r
        .node_neighborhood(node)
        .with_predicates(&opts.predicates)
        .with_mode(&mode)
        .with_depth(opts.depth as usize)
        .with_iri_mode(crate::api::iri_mode(&opts.iri_mode)?)
        .execute()?;
    let limit = opts.limit.map(|n| n as usize).unwrap_or(usize::MAX);
    let mut arcs = iter
        .take(limit.saturating_add(1))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let truncated = arcs.len() > limit;
    arcs.truncate(limit);
    let arcs = arcs
        .into_iter()
        .map(|arc| Arc {
            root: arc.root.to_string(),
            node: arc.node.to_string(),
            predicate: arc.predicate.to_string(),
            neighbor: arc.neighbor.to_string(),
            direction: match arc.direction {
                ArcDirection::Outgoing => atoms::outgoing(),
                ArcDirection::Incoming => atoms::incoming(),
            },
            depth: arc.depth,
            is_last: arc.is_last,
        })
        .collect();
    Ok(Neighborhood { arcs, truncated })
}
