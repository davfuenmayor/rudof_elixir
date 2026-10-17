# Native bundles

`rudof-0.3.24-<target>.tar.gz` and its `.sha256` sidecar are built with
`scripts/build_native.sh`. Each archive contains `native/`: the Rustler NIF,
renderer helper, target identifier, resolved Cargo lockfile, runtime libraries
where needed and dependency license notices. Keep the sidecar with its archive.

See [MULTIPLATFORM.md](../../MULTIPLATFORM.md) for available artifacts, native
build requirements, limitations and the validation process. Generated build
trees and intermediate files belong in the external build cache, not here.
