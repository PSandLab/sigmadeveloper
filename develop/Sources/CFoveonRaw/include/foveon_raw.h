#ifndef FOVEON_RAW_H
#define FOVEON_RAW_H

#include <stdint.h>
#include <stddef.h>

/* C ABI for `sd14raw` (see raw/src/ffi.rs). Turns in-memory .x3f bytes into
   in-memory DNG or developed half-float TIFF bytes. No global state, no
   filesystem — safe to call concurrently from many threads (one per image). */

typedef struct {
    uint8_t *ptr;
    size_t   len;
    size_t   cap;
} FoveonBytes;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t orientation;
    uint32_t spatial_gain;
    float    mono_weights[3];

    float    focal_length;
    float    aperture;
    float    focal_min;
    float    focal_max;
    float    aperture_max;

    /* capture metadata (0 when the file carries none) */
    float    iso;
    float    baseline_exposure;

    /* body lens code (LENSMODEL; 0 = absent, 255 = unknown to the body) */
    uint32_t lens_model;
} FoveonInfo;

/* mode: 0 = linear-Foveon DNG, 1 = developed scene-linear sRGB half-float
   TIFF, 2 = half-resolution proxy of the developed TIFF (2x2 raw box average;
   thumbnails/analysis). wb may be NULL (use the as-shot white balance).
   Returns 0 on success and fills *out_bytes (owned by caller; free with
   foveon_bytes_free) and, when non-NULL, *out_info. Returns a negative code on
   failure. */
int32_t foveon_render(const uint8_t *x3f, size_t x3f_len, uint32_t mode,
                      const char *wb, FoveonBytes *out_bytes, FoveonInfo *out_info);

/* Opaque prepared decode: parse + Huffman decode + colour calibration done
   once, so several formats can be emitted from one file at one decode's cost. */
typedef struct FoveonPrepared FoveonPrepared;

/* Prepare .x3f bytes for repeated foveon_emit calls. The bytes are fully
   consumed and need not outlive the call. Returns NULL on failure; free the
   handle with foveon_close. */
FoveonPrepared *foveon_open(const uint8_t *x3f, size_t x3f_len, const char *wb);

/* Emit one format (same mode/out contract as foveon_render) from a prepared
   decode. Read-only on the handle: concurrent emits are safe. */
int32_t foveon_emit(const FoveonPrepared *prepared, uint32_t mode,
                    FoveonBytes *out_bytes, FoveonInfo *out_info);

/* Free a handle returned by foveon_open (NULL is a no-op). */
void foveon_close(FoveonPrepared *prepared);

/* Free a buffer returned by foveon_render/foveon_emit (a zeroed buffer is a
   no-op). */
void foveon_bytes_free(FoveonBytes b);

#endif /* FOVEON_RAW_H */
