# rudof_elixir

Thin, idiomatic Elixir bindings for [Rudof](https://github.com/rudof-project/rudof),
the Rust RDF, SPARQL, ShEx and SHACL library. Parsing, querying and validation
are delegated to Rust; Elixir provides sessions, tagged results and visualization
adapters.

- [Getting Started](livebooks/getting_started.livemd): the wrapper API and session lifecycle.
- [Rudof tutorials](livebooks/rudof-tutorial/intro.livemd): eleven lessons with inline data.

## Installation

Use this local checkout as a dependency:

```elixir
{:rudof_elixir, path: "../rudof_elixir"}
```

Requires Elixir 1.19+ and 64-bit Erlang/OTP 27+. On platforms with a shipped
bundle, Mix verifies and installs the Rustler NIF and renderer helper without
running Cargo. No separate Rudof installation or compiler is needed. The
notebooks use Livebook's default Standalone runtime and Kino; examples run
through the actual native API. Some tutorial chapters contact public RDF
services and need network access.

The bundle installer recognizes Linux x86-64/ARM64 (glibc), macOS Intel/Apple
Silicon and Windows x86-64. **Only artifacts listed as available in
[MULTIPLATFORM.md](MULTIPLATFORM.md) work without a source build.** musl/Alpine
is not supported. Other native bundles still need their own build runners and
validation; target recognition alone does not establish support.

The included Linux x86-64 bundle requires glibc 2.39+ and has been tested on
glibc 2.41. Bundles are currently distributed with this checkout; their size
requires separate release-asset hosting before Hex publication.

To build your own bundle with Rust 1.91+, CMake, a C++ toolchain and OpenSSL
development libraries, run `scripts/build_native.sh`, then `mix compile`.
Windows requires MSVC; macOS uses Xcode tools and Homebrew OpenSSL. Native builds
can be tuned for your hardware and avoid mismatches with system libraries.
Complete platform instructions, binary overrides and build/test status are in
[MULTIPLATFORM.md](MULTIPLATFORM.md).

```sh
mix deps.get
mix test
```

## Run the Livebooks

Install Livebook, then start it from this project folder:

```sh
mix escript.install hex livebook 0.19.9 --force
~/.mix/escripts/livebook server livebooks/getting_started.livemd
```

On Windows, start it in PowerShell:

```powershell
& "$HOME\.mix\escripts\livebook.bat" server livebooks/getting_started.livemd
```

Open the printed local URL, use the default **Standalone** runtime and choose
**Evaluate all**. Keep the checkout available to that runtime: setup uses paths
relative to each notebook. The first dependency/Kino installation needs network
access. Native bundle requirements and availability are described above.

Licensed under [MIT](LICENSE). Bundles retain upstream dependency notices;
see their `native/licenses` directories. The tutorial adaptation retains its
[upstream license](livebooks/rudof-tutorial/LICENSE).
