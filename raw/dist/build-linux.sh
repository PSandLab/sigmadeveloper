#!/usr/bin/env bash
# Cross-compile the sd14raw decoder to a static x86_64-linux binary and refresh
# the prebuilt copy in this directory. Run from anywhere; needs only rustup +
# zig (used as the cross-linker via cargo-zigbuild). The crate is pure std with
# no C deps, so this is a clean cross-compile.
#
#   ./raw/dist/build-linux.sh            # auto-installs cargo-zigbuild, needs `zig` on PATH
#
# Install zig first if missing (no system package needed):
#   curl -fsSL https://ziglang.org/download/0.13.0/zig-<os>-<arch>-0.13.0.tar.xz | tar xJ
#   export PATH="$PWD/zig-<os>-<arch>-0.13.0:$PATH"
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/../Cargo.toml"
target="x86_64-unknown-linux-musl"   # musl → fully static, runs on any x86_64 Linux

command -v zig >/dev/null || { echo "error: 'zig' not on PATH (see header)" >&2; exit 1; }
command -v cargo-zigbuild >/dev/null || cargo install cargo-zigbuild
rustup target add "$target"

cargo zigbuild --release --manifest-path "$manifest" --target "$target" --bin sd14raw

out="$here/x86_64-linux/sd14raw"
mkdir -p "$(dirname "$out")"
cp "$here/../target/$target/release/sd14raw" "$out"
chmod +x "$out"
echo "wrote $out"
file "$out"
