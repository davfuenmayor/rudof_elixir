# Known issues

Checked **2026-10-01** against rudof **0.3.24**, pinned revision
`393f45e9d79ff18abc6ed237c675e4a9f8809bcd`.
[API_COVERAGE.md](API_COVERAGE.md) tracks API coverage and unsupported functionality.
Record confirmed behavior, evidence, workarounds and removal conditions here.

## KI-001: SPARQL queries miss data merged after the first query

**Apparent upstream bug; reproduced directly and mitigated by the wrapper.**

The memory backend maintains a graph and a lazily initialized SPARQL store.
Merges update the graph without refreshing an existing store; `ensure_store()`
returns immediately if that store exists. Consequently, **load → query → merge
→ query** can serialize the new triples while SPARQL cannot see them. Merging
before the first query works.

Source: [merge_from_reader and ensure_store](https://github.com/rudof-project/rudof/blob/393f45e9d79ff18abc6ed237c675e4a9f8809bcd/rudof_rdf/src/rdf_impl/oxigraph/in_memory.rs).
No matching upstream tracking issue has been identified; no report has been
filed by us. This records our confirmation, not upstream acknowledgment.

### Reproduction without the wrapper

Create a Rust binary with the `rudof_lib` dependency and feature selection from
[native/rudof_nif/Cargo.toml](native/rudof_nif/Cargo.toml). Use this `src/main.rs`
and run `cargo run`:

```rust
use rudof_lib::{Rudof, RudofConfig, formats::InputSpec, types::QueryResult};

const INITIAL: &str = "<http://e/a> <http://e/p> <http://e/old> .";
const ADDED: &str = "<http://e/b> <http://e/p> <http://e/new> .";
const QUERY: &str = "ASK { <http://e/b> <http://e/p> <http://e/new> }";

fn load(r: &mut Rudof, text: &str, merge: bool) {
    r.load_data()
        .with_data(&[InputSpec::str(text)])
        .with_merge(merge)
        .execute()
        .unwrap();
}

fn ask(r: &mut Rudof) -> bool {
    r.load_sparql_query(&InputSpec::str(QUERY)).execute().unwrap();
    r.run_query().execute().unwrap();
    match r.query_results().unwrap() {
        QueryResult::Ask(value) => *value,
        _ => panic!("expected ASK"),
    }
}

fn main() {
    let mut r = Rudof::new(RudofConfig::default());
    load(&mut r, INITIAL, false);
    assert!(!ask(&mut r)); // Initialize the query store before merging.
    load(&mut r, ADDED, true);

    let mut output = Vec::new();
    r.serialize_data(&mut output).execute().unwrap();
    println!("Serialization after merge:\n{}", String::from_utf8(output).unwrap());

    let warm = ask(&mut r);
    println!("ASK after warming the store, then merging: {warm}");
    assert!(!warm, "stale-store reproduction changed");

    let mut cold = Rudof::new(RudofConfig::default());
    load(&mut cold, INITIAL, false);
    load(&mut cold, ADDED, true);
    let cold = ask(&mut cold);
    println!("Same ASK when merging before the first query: {cold}");
    assert!(cold);
}
```

At the pinned revision, serialization contains both triples, but the warmed
ASK returns `false`; the same ASK without a prior query returns `true`.
The `assert!(!warm)` characterizes the failure and must change when testing a fix.

### Workaround and costs

After qualifying memory-RDF merges, [refresh_data](native/rudof_nif/src/api.rs)
serializes the resulting graph as Turtle and reloads it with `merge: false`.
The next query builds a fresh store. This applies to `read_data/3`, nonempty
memory-RDF inputs to `load_data/3`, and `dereference/3`. Replacement loads,
endpoint attachment and nonmemory backends skip this refresh.

- Each refresh traverses the entire graph and allocates temporary serialization
  data, including when no query has run yet. Batch small merges where practical.
- Blank-node labels can change during the round trip; RDF relationships remain
  preserved. Do not use these labels as persistent application identifiers.
- Refresh runs after the merge. Failure does not roll back the merged data.

[test/data_merge_test.exs](test/data_merge_test.exs) checks ASK/SELECT/CONSTRUCT
visibility and blank-node relationships. It does **not** assert label renaming.
[test/api_contract_test.exs](test/api_contract_test.exs) additionally covers
merge defaults, replacement, prefixes and dereferencing; query-based ShapeMap
selection is covered in [test/rudof_test.exs](test/rudof_test.exs).

Remove the refresh only after pinning an upstream fix and verifying the same
query-visibility tests without it. Record the fixing revision here.

## KI-002: Python docstrings give the wrong merge default

**Confirmed upstream documentation mismatch; no wrapper workaround needed.**

The pinned Python [read_data and dereference bindings](https://github.com/rudof-project/rudof/blob/393f45e9d79ff18abc6ed237c675e4a9f8809bcd/bindings/python/src/api/data.rs)
say `merge` defaults to `False`. Their signatures use `None`, forwarding a
setting only when supplied. Rust resolves omission as `true`.

Elixir follows the implementation: `read_data/3`, `load_data/3`, and
`dereference/3` merge by default; pass `merge: false` to replace. These behaviors
are covered by [test/api_contract_test.exs](test/api_contract_test.exs).
No upstream tracking issue has been identified. Resolve this entry when the
upstream docstrings are corrected.

## Improvements

Pending concrete integration work; preserve the upstream pin and Rust delegation.

- **Precompiled distribution:** ship checksum-verified release binaries for both
  the NIF and `rudof_render`, with a source-build fallback. Builds currently
  require the full native toolchain.
- **Release builds for consumers:** lib/rudof/native.ex selects debug mode outside
  `MIX_ENV=prod`, including default Livebook builds. Use release by default with
  an explicit development override.
- **Reproducibility:** Rustler 0.38.0 runs Cargo metadata and compilation without
  `--locked`. Enforce the committed lockfile; account separately for native
  artifacts downloaded by Ladybug's build script.
- **Build identity:** expose the upstream commit, features, target and build mode
  without starting a session. The upstream version string does not identify a
  unique commit. Derive values from build inputs.
- **Deployment documentation:** the README now states Rust 1.91+ and source-build
  prerequisites. Still document deployed native-library and renderer requirements,
  and a local Cargo override workflow for testing a sibling upstream checkout.
