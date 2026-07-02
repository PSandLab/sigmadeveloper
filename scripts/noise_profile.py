#!/usr/bin/env python3
"""Measure the SD14's Poisson-Gaussian noise profile from single frames.

The SD14 applies no analog gain — ISO is a metadata push over one base
sensitivity — so every decoded frame, at any ISO, measures the same base
profile  var(x) = a + b*x  per channel in the decoder's scene-linear sRGB
output units (high ISO just means the frame sits further down the range).

Estimator:
  - High-pass each channel with the Immerkær mask [1,-2,1;-2,4,-2;1,-2,1]/6,
    which cancels constants and linear ramps and has unit noise gain, so on
    flat regions its output *is* the pixel noise.
  - Bin pixels by the local 3x3 mean, estimate each bin's sigma robustly
    (MAD — real texture inflates only the tail, not the median).
  - Weighted linear fit of var vs signal per frame; pool every frame in
    dataset/noisy AND dataset/clean with a weighted median, which suppresses
    the upward bias of texture-heavy scenes.

Writes develop/Sources/SigmaFoveon/NoiseProfiles.generated.swift.

Usage:  python3 scripts/noise_profile.py [--dry-run]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from jit_denoiser import develop_x3f, read_image, read_x3f_props  # noqa: E402

DECODER = ROOT / "raw/target/release/sd14raw"
DECODED_CACHE = ROOT / "out/dataset"        # pre-decoded intermediates, if present
GENERATED = ROOT / "develop/Sources/SigmaFoveon/NoiseProfiles.generated.swift"

# Per-channel signal bins (scene-linear). Below ~one raw 10-bit LSB (≈1e-3 in
# decoded units) the signal is quantisation-dominated; start above it.
BINS = np.geomspace(8e-4, 1.2, 41)
MIN_BIN_PIXELS = 4000
CLIP = 0.92          # exclude pixels near the highlight-reconstruction knee
MAD_TO_SIGMA = 1.4826

# Quantisation floor of the 10-bit raw in decoded units (LSB²/12): thresholds
# should never fall below it in deep shadows.
QUANT_VAR = (1.0 / 1024.0) ** 2 / 12.0


def load_linear(x3f: Path, data_root: Path) -> np.ndarray:
    cached = DECODED_CACHE / x3f.relative_to(data_root).with_suffix(".tif")
    if cached.exists():
        return read_image(cached)
    return develop_x3f(x3f, DECODER)


def highpass(c: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Immerkær high-pass (unit noise gain) and 3x3 local mean, both valid-crop."""
    tl, tc, tr = c[:-2, :-2], c[:-2, 1:-1], c[:-2, 2:]
    ml, mc, mr = c[1:-1, :-2], c[1:-1, 1:-1], c[1:-1, 2:]
    bl, bc, br = c[2:, :-2], c[2:, 1:-1], c[2:, 2:]
    d = (tl + tr + bl + br - 2 * (tc + ml + mr + bc) + 4 * mc) / 6.0
    m = (tl + tc + tr + ml + mc + mr + bl + bc + br) / 9.0
    return d, m


def frame_bins(f: np.ndarray):
    """Per-channel (bin signal x, noise variance, counts) for one frame."""
    out = []
    for c in range(3):
        d, m = highpass(f[..., c])
        d, m = d.ravel(), m.ravel()
        ok = (m > 0) & (m < CLIP) & np.isfinite(d)
        d, m = d[ok], m[ok]
        idx = np.digitize(m, BINS)
        xs, vs, ns = [], [], []
        for b in range(1, len(BINS)):
            sel = idx == b
            n = int(sel.sum())
            if n < MIN_BIN_PIXELS:
                continue
            db = d[sel]
            sigma = MAD_TO_SIGMA * float(np.median(np.abs(db)))  # zero-median by design
            xs.append(float(np.median(m[sel])))
            vs.append(sigma * sigma)
            ns.append(n)
        if len(xs) < 4:
            return None
        out.append((np.array(xs), np.array(vs), np.array(ns)))
    return out


def fit_affine(xs: np.ndarray, vs: np.ndarray, ns: np.ndarray) -> tuple[float, float]:
    """Population-weighted LSQ of var = a + b*x, constrained non-negative."""
    w = ns.astype(np.float64)
    M = np.stack([np.ones_like(xs), xs], axis=1)
    Mw = M * w[:, None]
    a, b = np.linalg.lstsq(Mw.T @ M, Mw.T @ vs, rcond=None)[0]
    if a < 0:  # shadows dominated by the poissonian term: refit through origin
        a = 0.0
        b = float((w * xs * vs).sum() / (w * xs * xs).sum())
    if b < 0:
        b = 0.0
        a = float((w * vs).sum() / w.sum())
    return float(a), float(b)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print fits, don't write Swift")
    args = ap.parse_args()

    frames = []
    for sub in ("noisy", "clean"):
        data_root = ROOT / "dataset"
        frames += [(f, data_root) for f in sorted((data_root / sub).rglob("*"))
                   if f.suffix.lower() == ".x3f"]

    fits: list[tuple[np.ndarray, np.ndarray, float]] = []
    for x3f, data_root in frames:
        f = load_linear(x3f, data_root)
        stats = frame_bins(f)
        if stats is None:
            print(f"[warn] {x3f.relative_to(data_root)}: too dark/flat to bin; skipped")
            continue
        a3, b3, weight = np.zeros(3), np.zeros(3), 0.0
        for c in range(3):
            xs, vs, ns = stats[c]
            a3[c], b3[c] = fit_affine(xs, vs, ns)
            weight += float(ns.sum())
        fits.append((a3, b3, weight))
        iso = read_x3f_props(x3f).get("ISO", "?")
        print(f"{x3f.relative_to(data_root)}  ISO {iso:>5}"
              f"  a={a3[0]:.2e}/{a3[1]:.2e}/{a3[2]:.2e}"
              f"  b={b3[0]:.2e}/{b3[1]:.2e}/{b3[2]:.2e}")

    if not fits:
        sys.exit("no usable frames found")

    def weighted_median(values: np.ndarray, weights: np.ndarray) -> float:
        order = np.argsort(values)
        cum = np.cumsum(weights[order])
        return float(values[order][np.searchsorted(cum, cum[-1] / 2)])

    ws = np.array([f[2] for f in fits])
    a = np.array([weighted_median(np.array([f[0][c] for f in fits]), ws) for c in range(3)])
    b = np.array([weighted_median(np.array([f[1][c] for f in fits]), ws) for c in range(3)])
    a = np.maximum(a, QUANT_VAR)

    print(f"\npooled base profile over {len(fits)} frames (weighted median):")
    for c, name in enumerate("RGB"):
        print(f"  {name}: a={a[c]:.4e}  b={b[c]:.4e}  (read sigma={np.sqrt(a[c]):.4f}, "
              f"shot sigma@0.18={np.sqrt(b[c] * 0.18):.4f})")

    if args.dry_run:
        return

    swift = f"""// Generated by scripts/noise_profile.py — do not edit by hand.
//
// Poisson-Gaussian noise model of the SD14 sensor, measured in the decoder's
// scene-linear sRGB output units at base sensitivity: var(x) = a + b·x per
// channel. Estimated registration-free from {len(fits)} dataset frames
// (Immerkær high-pass, per-bin MAD, weighted-median pooling; `a` floored at
// the 10-bit raw quantisation variance).

let sd14BaseNoise = NoiseProfile(
    a: SIMD3<Float>({a[0]:.6e}, {a[1]:.6e}, {a[2]:.6e}),
    b: SIMD3<Float>({b[0]:.6e}, {b[1]:.6e}, {b[2]:.6e})
)
"""
    GENERATED.write_text(swift)
    print(f"\nwrote {GENERATED.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
