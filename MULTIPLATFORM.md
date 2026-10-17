# Native builds and platform testing

Rudof 0.3.24 is pinned in `native/rudof_nif/Cargo.toml` and `Cargo.lock`.
The wrapper keeps Rustler for NIF registration and loading, with
[`skip_compilation?` and `load_from`](https://rustler.hexdocs.pm/Rustler.html).
A Mix compiler installs a platform archive from `native/precompiled/`, verifies
its SHA-256 sidecar and target identifier, and restores missing native files.
There is no Cargo invocation during an ordinary dependency install.

## Status

| Target | Bundle and validation |
| --- | --- |
| Linux x86-64, glibc | Bundle included; validated on glibc 2.41 / OTP 29 |
| Linux ARM64, glibc | Installer target defined; native build and tests pending |
| Windows x86-64, MSVC | Installer target defined; native build and tests pending |
| macOS Intel | Installer target defined; native build and tests pending |
| macOS Apple Silicon | Installer target defined; native build and tests pending |

**Only a built, tested archive provides an out-of-the-box installation.** There
are no Windows or macOS runners here. musl/Alpine, 32-bit runtimes and Windows
ARM64 are outside the supported target set. A 64-bit VM must match its archive's
architecture; an x86-64 VM under Rosetta uses the Intel archive.

The included Linux binaries require **glibc 2.39+** according to their ELF
symbol requirements. They have been executed on glibc 2.41, not yet on the
minimum baseline. Use a native source build on older distributions.

## Build a bundle

Build on the target OS and architecture. Use Elixir 1.19+, 64-bit Erlang/OTP 27+
and Rust 1.91+ (edition 2024). Use a clean checkout with the committed Cargo
lockfile. Builds preserve every existing Rudof feature, including the embedded
Ladybug property-graph database and the isolated renderer helper.

Linux (Debian/Ubuntu):

```sh
sudo apt-get install build-essential cmake ninja-build pkg-config libssl-dev zlib1g-dev libzstd-dev patchelf
scripts/build_native.sh
mix deps.get
mix test
```

The script builds locked Rust dependencies in release mode and forces Ladybug
to compile the C++ source shipped in its pinned crate. Its default upstream
build otherwise downloads an unpinned binary/script. The first full build is
large and can take considerable time; `BUILD_JOBS=4` limits parallelism. Build
on the oldest glibc baseline you intend to support; glibc is not bundled.

macOS, on both Intel and Apple Silicon:

```sh
xcode-select --install
brew install cmake ninja pkg-config openssl@3
export OPENSSL_DIR="$(brew --prefix openssl@3)"
export CMAKE_PREFIX_PATH="$OPENSSL_DIR${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
scripts/build_native.sh
mix deps.get
mix test
```

The script sets a macOS 12 deployment target by default, relocates OpenSSL
libraries beside the NIF and helper, and ad-hoc signs the resulting binaries.
This recipe still needs native validation on both architectures. Check every
non-system dependency with `otool -L`; no Homebrew paths may remain in a release
bundle. Include the redistributed OpenSSL notices before release.

Windows x86-64:

1. Install 64-bit Erlang/Elixir, Rust's **MSVC** toolchain, Visual Studio Build
   Tools with Desktop development with C++, CMake, Ninja, Git Bash and OpenSSL
   development libraries (for example, via vcpkg).
2. Start an **x64 Visual Studio developer shell**, then start Git Bash from it
   so Cargo can find `cl.exe`, `link.exe` and CMake. Configure OpenSSL's include
   and library paths for that MSVC environment.
3. Run `scripts/build_native.sh`, `mix deps.get` and `mix test` there.
4. Before distributing an archive, collect its non-system DLL dependencies and
   their redistribution notices, check both binaries using `dumpbin /DEPENDENTS`,
   then repeat installation/tests on a clean Windows VM without build tools.

Windows packaging of MSVC/OpenSSL runtime DLLs is a remaining release task;
the build recipe alone does not establish a standalone Windows installation.
Ladybug's build script detects its **host OS**, assumes MSVC on Windows and
sets its own CMake runtime flags. Linux-to-Windows GNU cross-compilation is not
a substitute. Do not disable database features or relabel a GNU DLL as MSVC.
Linux ARM64 similarly needs a native ARM runner or a fully validated cross
build with target OpenSSL/C++ dependencies. QEMU is available in this container,
but installing a Rust target alone does not solve those native dependencies.

Build trees, staging and metadata live outside the repo, under
`${XDG_CACHE_HOME:-$HOME/.cache}/rudof-elixir`; `RUDOF_BUILD_ROOT` overrides
that location. Only the final `.tar.gz` and `.sha256` go into
`native/precompiled/`. Each archive contains the NIF, `rudof_render`, target
identifier, Cargo lockfile and third-party notices. Linux bundles also carry
private OpenSSL/C++ runtimes linked statically with hidden symbols, plus any
remaining non-glibc shared dependencies with relative loader paths and private
SONAMEs. This prevents conflicts with OpenSSL already loaded by Erlang. The
Linux linker helper applies only to the final NIF and renderer; dependency
builds remain cached.

## Bring your own binaries

Run the build script on your Mac, Windows or Linux machine, then use
`mix compile` normally. The result uses exactly the same API and notebook setup.
You can tune a local build with Cargo's `RUSTFLAGS`, but avoid `target-cpu=native`
for bundles distributed to other machines. A native build can match your CPU
and installed libraries more closely; it still needs the same functional tests.

To use an archive outside the checkout, set `RUDOF_ELIXIR_BUNDLE` to its absolute
path and keep `<archive>.sha256` alongside it. In PowerShell:

```powershell
$env:RUDOF_ELIXIR_BUNDLE = 'C:\bundles\rudof-0.3.24-windows-x86_64.tar.gz'
mix compile
```

`RUDOF_BUILD=1 mix compile` explicitly invokes the build script (Bash required).
Normal installs never compile Rust. Restart running BEAM/Livebook runtimes after
replacing a NIF: an already loaded native library cannot be replaced by changing
files underneath it.

## Test each platform

Run the following on every native target, with the compiler toolchain removed
from `PATH` for the final install/relocation checks:

```sh
mix deps.get
mix test
elixir scripts/check_livebook_cells.exs
```

The cell checker evaluates all twelve executable notebooks twice, including
Getting Started, preserving each cell's Elixir bindings and imports. Some
chapters call public endpoints and require working internet access and available
services. Use
`elixir scripts/check_livebook_cells.exs --offline` to explicitly omit the four
network-dependent chapters; those omissions are reported, never counted as
passes. These checks execute the actual NIF; they do not stub the Rust API.
Also verify the renderer helper starts,
missing native files are restored, a checksum mismatch fails before extraction,
and the installed app can move to a different path in a fresh VM. Inspect
`ldd`, `otool -L` or `dumpbin /DEPENDENTS` to exclude build-machine dependencies.

For actual Livebook parser/runtime/Kino checks, install Livebook 0.19.9 and
start an isolated local node (choose your own local cookie):

```sh
mix escript.install hex livebook 0.19.9 --force
epmd -daemon
LIVEBOOK_IFRAME_PORT=8192 ~/.mix/escripts/livebook server --ip 127.0.0.1 --port 8191 \
  --name rudof_livebooks@127.0.0.1 --cookie YOUR_LOCAL_COOKIE
```

In another terminal, from this repo:

```sh
elixir --name rudof_checker@127.0.0.1 --cookie YOUR_LOCAL_COOKIE \
  scripts/check_livebooks.exs rudof_livebooks@127.0.0.1
```

The RPC checker imports every notebook, rejects parser warnings, evaluates all
executable cells in real Standalone runtimes and closes each session. Guides
are reported separately. It uses disposable copies so autosave cannot alter
the authoritative lessons. Renderer image backends may need Java/PlantUML or
Graphviz; default Mermaid notebook diagrams require neither.

Pass `--offline` after the node name to explicitly report and omit the four
network-dependent chapters. Notebook text and lesson code are kept verbatim;
the checkers do not rewrite them or replace remote results with fixtures.

## Release work still required

- Produce and validate the four remaining native archives. Native Windows must
  include required redistributable DLLs; macOS must pass relocation, signing
  and OpenSSL notice checks on Intel and Apple Silicon.
- Establish and test the minimum Linux glibc/macOS/OTP versions on real runners.
  Running on this container only proves its own baseline.
- The Linux archive is **35,565,311 bytes (33.9 MiB)**, exceeding the
  [16 MiB Hex tarball limit](https://hex-core.hexdocs.pm/hex_core.html).
  Local checkout installs work; Hex publication needs versioned release assets
  with pinned checksums and download support. No remote release artifacts have
  been published.
- On every release, rerun API tests, both notebook checkers, fresh installation,
  relocation and loader dependency inspection for every claimed target.

## Results in this container

Linux x86-64: Elixir 1.20.4, OTP 29.1.1, glibc 2.41, Rust 1.98.1. The first
full release build took about 25 minutes, mostly the pinned Ladybug C++ source;
the final private-runtime relink reused those compiled dependencies.

- `mix test`: **123 passed**, including the NIF and helper running after
  relocation to a path with spaces, checksum/target/payload rejection and
  restoration of missing native files. Cargo was absent from `PATH` throughout
  the install and test run.
- `scripts/check_livebook_cells.exs`: **all twelve executable notebooks passed
  twice**, including their original DBpedia, Wikidata and UniProt requests.
  The introduction is reference-only. No notebook was edited for these checks.
- Real Livebook 0.19.9: **all twelve executable notebooks passed**, including
  their setup cells and public endpoint requests (159 code cells total). The
  introduction imported without warnings and remains reference-only.
- `ldd`: the NIF/helper depend only on bundled private `libgcc_s`, glibc and
  libm; there is no runtime OpenSSL, C++ library, zlib or zstd dependency.
- With Debian 12's **OpenSSL 3.0.20 preloaded**, Erlang's crypto application
  starts, the NIF runs a SPARQL query, and the renderer helper reaches its normal
  argument validation. Reproduce with `LD_PRELOAD=/path/to/libcrypto.so.3` in a
  fresh VM. Merely renaming shared OpenSSL libraries failed this check; static
  linking with hidden symbols resolved the conflict.
- `mix hex.build --output <cache>/rudof_elixir-0.1.0.tar` confirms the current
  vendored-bundle package exceeds Hex's compressed-size limit. This is a
  distribution blocker, not a local installation failure; see release work.

The locked `proc-macro-error2` 2.0.1 dependency reports a future-incompatibility
warning under Rust 1.98.1. Current builds pass; reassess the lockfile when
upgrading the build toolchain. Build logs and temporary checks remain outside
the repo in the build cache.
