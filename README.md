# rudof_elixir

Thin, idiomatic Elixir bindings for [Rudof](https://github.com/rudof-project/rudof),
the Rust RDF, SPARQL, ShEx and SHACL library. Parsing, querying and validation
are delegated to Rust; Elixir provides sessions, tagged results and visualization
adapters.

- [Getting Started](livebooks/getting_started.livemd): the wrapper API, examples and session lifecycle.
- [Rudof tutorials](livebooks/rudof-tutorial/intro.livemd): the data and validation languages, with native Elixir examples.

For upstream documentation, configuration and functionality, see the
[Rudof GitHub repository](https://github.com/rudof-project/rudof).

## Installation

The package is currently used from a local checkout:

```elixir
{:rudof_elixir, path: "../rudof_elixir"}
```

Source builds require Elixir 1.19+, Erlang/OTP, Rust 1.91+, a C/C++ toolchain,
`pkg-config` and OpenSSL development headers. On Debian, install
`build-essential pkg-config libssl-dev`. The first build downloads and compiles
the pinned Rust dependencies; no separate Rudof checkout is required.

To build and run the tests from this repository:

```sh
mix deps.get
mix test
```

Licensed under [MIT](LICENSE). Upstream material retains its original copyrights
and licenses, as described in that file.
