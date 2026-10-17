#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) target=linux-x86_64; triple=x86_64-unknown-linux-gnu ;;
  Linux-aarch64) target=linux-aarch64; triple=aarch64-unknown-linux-gnu ;;
  Darwin-x86_64) target=macos-x86_64; triple=x86_64-apple-darwin ;;
  Darwin-arm64) target=macos-aarch64; triple=aarch64-apple-darwin ;;
  MINGW*-x86_64|MSYS*-x86_64) target=windows-x86_64; triple=x86_64-pc-windows-msvc ;;
  *) echo 'Unsupported native build host' >&2; exit 1 ;;
esac
if ! rustc -vV | awk -v expected="$triple" '$1 == "host:" { found = ($2 == expected) } END { exit !found }'; then
  echo "Use a native Rust toolchain for $triple (Windows requires MSVC)." >&2
  exit 1
fi
# Ladybug's build script detects its build host, so cross-builds are not advertised.
cache=${RUDOF_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/rudof-elixir}
mkdir -p "$cache" native/precompiled
cache=$(cd "$cache" && pwd -P)
export CARGO_TARGET_DIR="$cache/target"
export CARGO_BUILD_JOBS=${BUILD_JOBS:-4}
# Use the locked crate's bundled C++ source, never its unpinned binary downloader.
export LBUG_BUILD_FROM_SOURCE=1
unset LBUG_SHARED LBUG_LIBRARY_DIR LBUG_INCLUDE_DIR LBUG_SOURCE_DIR
if [[ "$target" == macos-* ]]; then
  export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}
fi
if [[ "$target" == linux-* ]]; then
  # Only the final binaries use this linker; the locked dependencies stay cached.
  for artifact in --lib '--bin rudof_render'; do
    read -ra selection <<< "$artifact"
    cargo rustc --locked --release --manifest-path native/rudof_nif/Cargo.toml \
      "${selection[@]}" -- -C "linker=$PWD/scripts/link_native_linux.sh"
  done
else
  cargo build --locked --release --manifest-path native/rudof_nif/Cargo.toml
fi
elixir --erl '+S 1:1' -e 'File.rm_rf!(hd(System.argv()))' "$cache/stage/$target"
stage="$cache/stage/$target"
mkdir -p "$stage/native/licenses"
case "$target" in
  linux-*) library=librudof_nif.so; extension=so; helper=rudof_render ;;
  macos-*) library=librudof_nif.dylib; extension=so; helper=rudof_render ;;
  windows-*) library=rudof_nif.dll; extension=dll; helper=rudof_render.exe ;;
esac
cp "$cache/target/release/$library" "$stage/native/rudof_nif.$extension"
cp "$cache/target/release/$helper" "$stage/native/$helper"
echo "$target" > "$stage/native/target"
cp native/rudof_nif/LICENSE-RUDOF-MIT "$stage/native/licenses/"
cp LICENSE "$stage/native/licenses/LICENSE-RUDOF-ELIXIR-MIT"
cp native/rudof_nif/Cargo.lock "$stage/native/"
# Collect the actual resolved crates' license files, not only the top-level MIT grant.
cargo metadata --locked --format-version 1 --manifest-path native/rudof_nif/Cargo.toml > "$cache/metadata.json"
elixir --erl '+S 1:1' scripts/native_notices.exs "$cache/metadata.json" "$stage/native/licenses"
if [[ "$target" == linux-* ]]; then
  for binary in "$stage/native/rudof_nif.so" "$stage/native/rudof_render"; do
    patchelf --set-rpath '$ORIGIN' "$binary"
    strip "$binary"
  done
  for package in libssl3t64 libssl3 libstdc++6 libgcc-s1 gcc-14-base zlib1g libzstd1; do
    if [ -f "/usr/share/doc/$package/copyright" ]; then
      cp -L "/usr/share/doc/$package/copyright" "$stage/native/licenses/$package-NOTICES.txt"
    fi
  done
  if command -v dpkg-query >/dev/null; then
    dpkg-query -W -f='${binary:Package} ${Version} | source: ${source:Package} ${source:Version}\n' \
      libssl3t64 libssl3 libstdc++6 libgcc-s1 'gcc-*-base' zlib1g libzstd1 \
      > "$stage/native/licenses/SYSTEM-LIBRARIES.txt" 2>/dev/null || true
    printf '\nMatching source packages: https://snapshot.debian.org/package/\n' >> "$stage/native/licenses/SYSTEM-LIBRARIES.txt"
  fi
  for license in Apache-2.0 GPL-3; do
    cp "/usr/share/common-licenses/$license" "$stage/native/licenses/$license.txt"
  done
  # Bundle non-glibc dependencies needed by both the NIF and renderer.
  for binary in "$stage/native/rudof_nif.so" "$stage/native/rudof_render"; do
    while read -r library; do
      case "$(basename "$library")" in
        libssl.so.*|libcrypto.so.*|libstdc++.so.*|libgcc_s.so.*|libatomic.so.*)
          [ -f "$stage/native/$(basename "$library")" ] || cp -L "$library" "$stage/native/"
          ;;
      esac
    done < <(ldd "$binary" | awk '$2 == "=>" && $3 ~ /^\// {print $3}')
  done
  for library in "$stage/native/"*.so.*; do
    [ ! -f "$library" ] || patchelf --set-rpath '$ORIGIN' "$library"
  done
  # A BEAM may already have loaded another OpenSSL/C++ runtime. Private SONAMEs
  # ensure it still loads our bundled copies instead of reusing a host version.
  for library in "$stage/native/"*.so.*; do
    [ -f "$library" ] || continue
    name=$(basename "$library")
    for binary in "$stage/native/rudof_nif.so" "$stage/native/rudof_render" "$stage/native/"*.so.*; do
      patchelf --replace-needed "$name" "rudof_$name" "$binary"
    done
    patchelf --set-soname "rudof_$name" "$library"
    mv "$library" "$stage/native/rudof_$name"
  done
elif [[ "$target" == macos-* ]]; then
  # OpenSSL is provided by Homebrew at build time, then relocated beside the NIF.
  for binary in "$stage/native/rudof_nif.so" "$stage/native/rudof_render"; do
    while read -r dependency; do
      case "$dependency" in
        */libssl.*.dylib|*/libcrypto.*.dylib)
          cp -L "$dependency" "$stage/native/"
          install_name_tool -change "$dependency" "@loader_path/$(basename "$dependency")" "$binary"
          ;;
      esac
    done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }')
  done
  for binary in "$stage/native/"*.dylib; do
    [ -f "$binary" ] || continue
    install_name_tool -id "@loader_path/$(basename "$binary")" "$binary"
    while read -r dependency; do
      case "$dependency" in
        */libssl.*.dylib|*/libcrypto.*.dylib)
          install_name_tool -change "$dependency" "@loader_path/$(basename "$dependency")" "$binary" ;;
      esac
    done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }')
    codesign --force --sign - "$binary"
  done
  for binary in "$stage/native/rudof_nif.so" "$stage/native/rudof_render"; do
    strip -x "$binary"
    codesign --force --sign - "$binary"
  done
fi
archive="native/precompiled/rudof-0.3.24-$target.tar.gz"
tar -czf "$archive" -C "$stage" native
elixir --erl '+S 1:1' -e '[file] = System.argv(); hash = :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower); File.write!(file <> ".sha256", hash <> "\n")' "$archive"
printf 'Built %s (%s)\n' "$target" "$triple"
