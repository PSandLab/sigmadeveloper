#!/usr/bin/env bash
# Build the Rust core (CLI + static library) and the Swift wrappers.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rust: produces the `sd14raw` CLI *and* libsd14raw.a (the C ABI the Swift
# package links against).
echo "building sd14raw (CLI + static library)..." >&2
cargo build --release --manifest-path "$here/raw/Cargo.toml"

# Swift: the embeddable wrapper + `foveon` CLI (links libsd14raw.a).
echo "building SigmaFoveon + foveon..." >&2
swift build -c release --package-path "$here/develop"

echo "built: raw/target/release/{sd14raw,libsd14raw.a}, develop/.build/release/foveon" >&2