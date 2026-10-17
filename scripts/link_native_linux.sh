#!/usr/bin/env bash
# Private static runtimes avoid symbol conflicts with OpenSSL/C++ loaded by BEAM.
set -euo pipefail
read -ra openssl <<< "$(pkg-config --libs --static openssl)"
args=()
for arg in "$@" "${openssl[@]}"; do
  case "$arg" in
    -lstdc++|-lssl|-lcrypto|-lz|-lzstd) args+=(-Wl,-Bstatic "$arg" -Wl,-Bdynamic) ;;
    *) args+=("$arg") ;;
  esac
done
exec cc "${args[@]}" -Wl,--exclude-libs,ALL
