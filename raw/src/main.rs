//! Thin CLI shim — all logic lives in the `sd14raw` library (`src/lib.rs`),
//! which is also compiled as a static library for the Swift/iOS wrapper.
fn main() {
    sd14raw::cli_main();
}
