//! sd14raw — Sigma SD14 (Foveon X3) `.X3F` → linear DNG converter.
//!
//! credits for strong inspiration:
//! `kalpanika/x3f` (C) and `x3fuse-core`
//
// //! The 3 Foveon planes are written as a `LinearRaw` (PhotometricInterpretation
//! 34892), 3-samples-per-pixel, 16-bit DNG. White balance is communicated via
//! `AsShotNeutral`, colour via `ColorMatrix1`/`ForwardMatrix1`/`CameraCalibration1`.
//!
//! Build:  `cargo build --release`   (zero external crates, builds offline)
//! Run:    `sd14raw <in.x3f> [out.dng] [--wb NAME]`

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};

// Errors & little-endian readers

type R<T> = Result<T, String>;

#[inline]
fn u8at(b: &[u8], o: usize) -> R<u8> {
    b.get(o)
        .copied()
        .ok_or_else(|| "unexpected end of data".into())
}
#[inline]
fn u16at(b: &[u8], o: usize) -> R<u16> {
    b.get(o..o + 2)
        .map(|s| u16::from_le_bytes([s[0], s[1]]))
        .ok_or_else(|| "unexpected end of data".into())
}
#[inline]
fn u32at(b: &[u8], o: usize) -> R<u32> {
    b.get(o..o + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
        .ok_or_else(|| "unexpected end of data".into())
}
#[inline]
fn i16at(b: &[u8], o: usize) -> R<i16> {
    u16at(b, o).map(|v| v as i16)
}
#[inline]
fn f32at(b: &[u8], o: usize) -> R<f32> {
    u32at(b, o).map(f32::from_bits)
}

/// Read a NUL-terminated ASCII/UTF-8 C-string starting at `o` (bounds-safe).
fn cstr(b: &[u8], o: usize) -> String {
    let s = match b.get(o..) {
        Some(s) => s,
        None => return String::new(),
    };
    let end = s.iter().position(|&c| c == 0).unwrap_or(s.len());
    String::from_utf8_lossy(&s[..end]).into_owned()
}

/// Read a NUL-terminated little-endian UTF-16 string at byte offset `o`. X3F
/// `PROP` keys/values are ASCII-range BMP, so a plain `u16 → char` is exact
fn utf16_at(b: &[u8], o: usize) -> String {
    let mut s = String::new();
    let mut i = o;
    while i + 1 < b.len() {
        let c = (b[i] as u16) | ((b[i + 1] as u16) << 8);
        if c == 0 {
            break;
        }
        s.push(char::from_u32(c as u32).unwrap_or('\u{fffd}'));
        i += 2;
    }
    s
}

/// As-shot capture metadata read from X3F SECp
#[derive(Default, Clone)]
struct Capture {
    focal: Option<f32>,        // FLENGTH, mm
    aperture: Option<f32>,     // APERTURE, f-number (e.g. 1.41421 = f/1.4)
    focal_min: Option<f32>,    // LENSFRANGE low (= focal for a prime)
    focal_max: Option<f32>,    // LENSFRANGE high
    aperture_max: Option<f32>, // LENSARANGE widest (smallest f-number)
    /// LENSMODEL body lens code (6 = 28-80, 8 = 70-300, 255 = unknown
    /// lens newer than the body ?
    lens_model: Option<u32>,
    camera_model: Option<String>, // CAMMANUF + CAMMODEL → DNG UniqueCameraModel
}

impl Capture {
    /// Parse the `PROP` list of a `SECp` section (UTF-16 key/value pairs). The
    /// section layout is: header, then at +8 the entry count, +12 the char
    /// format (0 = UTF-16), +24 the (nameOff, valueOff) table in *chars*
    fn parse(sect: &[u8]) -> Capture {
        let n = match u32at(sect, 8) {
            Ok(v) if v <= 4096 => v as usize,
            _ => return Capture::default(),
        };
        if u32at(sect, 12).unwrap_or(0) != 0 {
            return Capture::default(); // only UTF-16 lists
        }
        let heap = 24 + n * 8;
        let get = |key: &str| -> Option<String> {
            (0..n).find_map(|i| {
                let no = u32at(sect, 24 + i * 8).ok()? as usize;
                if utf16_at(sect, heap + no * 2) != key {
                    return None;
                }
                let vo = u32at(sect, 24 + i * 8 + 4).ok()? as usize;
                Some(utf16_at(sect, heap + vo * 2))
            })
        };
        // "30" → [30]; "70 to 300" → [70, 300]
        let nums = |s: &str| -> Vec<f32> {
            s.split("to")
                .filter_map(|p| p.trim().parse().ok())
                .collect()
        };
        let frange = get("LENSFRANGE").map(|s| nums(&s)).unwrap_or_default();
        let arange = get("LENSARANGE").map(|s| nums(&s)).unwrap_or_default();
        // "SIGMA" + "SIGMA SD14" → "SIGMA SD14"
        let camera_model = match (get("CAMMANUF"), get("CAMMODEL")) {
            (Some(manuf), Some(model)) => {
                let (manuf, model) = (manuf.trim().to_string(), model.trim().to_string());
                Some(if model.is_empty() {
                    manuf
                } else if manuf.is_empty()
                    || model.to_uppercase().starts_with(&manuf.to_uppercase())
                {
                    model
                } else {
                    format!("{manuf} {model}")
                })
            }
            (m, None) | (None, m) => m.map(|s| s.trim().to_string()),
        }
        .filter(|s| !s.is_empty());
        Capture {
            focal: get("FLENGTH").and_then(|s| s.trim().parse().ok()),
            aperture: get("APERTURE").and_then(|s| s.trim().parse().ok()),
            focal_min: frange.iter().copied().reduce(f32::min),
            focal_max: frange.iter().copied().reduce(f32::max),
            aperture_max: arange.iter().copied().reduce(f32::min),
            lens_model: get("LENSMODEL").and_then(|s| s.trim().parse().ok()),
            camera_model,
        }
    }
}

// X3F container constants

const X3F_FOVB: u32 = 0x6256_4f46; // "FOVb"
const X3F_SECD: u32 = 0x6443_4553; // "SECd"
const X3F_SECI: u32 = 0x6943_4553; // "SECi" image
const X3F_SECP: u32 = 0x7043_4553; // "SECp" property list
const X3F_SECC: u32 = 0x6343_4553; // "SECc" CAMF

const RAW_HUFFMAN_X530: u32 = 0x0003_0005; // SD9/SD10
const RAW_HUFFMAN_10BIT: u32 = 0x0003_0006; // SD14

const CMBP: u32 = 0x5062_4d43; // "CMbP" property list
const CMBT: u32 = 0x5462_4d43; // "CMbT" text
const CMBM: u32 = 0x4d62_4d43; // "CMbM" matrix

const VERSION_2_1: u32 = (2 << 16) + 1;
const VERSION_4_0: u32 = 4 << 16;

// Parsed container

struct Section<'a> {
    identifier: u32,
    type_format: u32, // images only: (type<<16)|format
    camf_type: u32,   // CAMF only
    camf_vals: [u32; 4],
    /// Section payload *after* the per-section header (image/camf = +28, prop = +24).
    data: &'a [u8],
    /// Image header fields (images only).
    columns: u32,
    rows: u32,
    row_stride: u32,
}

struct Header {
    white_balance: String,
    rotation: u32,
}

struct Container<'a> {
    header: Header,
    sections: Vec<Section<'a>>,
    capture: Capture,
}

fn parse_container(buf: &[u8]) -> R<Container<'_>> {
    if u32at(buf, 0)? != X3F_FOVB {
        return Err("not an X3F file (bad FOVb magic)".into());
    }
    let version = u32at(buf, 4)?;
    let mut white_balance = String::new();
    let mut rotation = 0;
    if version < VERSION_4_0 {
        rotation = u32at(buf, 36)?;
        if version >= VERSION_2_1 {
            white_balance = cstr(buf, 40); // char[32] at 40
        }
    }

    // Directory: last 4 bytes point at the SECd section.
    let dir_ptr = u32at(buf, buf.len().checked_sub(4).ok_or("file too small")?)? as usize;
    if u32at(buf, dir_ptr)? != X3F_SECD {
        return Err("bad directory section (SECd)".into());
    }
    let n_entries = u32at(buf, dir_ptr + 8)? as usize;
    if n_entries > 1024 {
        return Err("implausible directory entry count".into());
    }

    let mut sections = Vec::with_capacity(n_entries);
    let mut capture = Capture::default();
    for i in 0..n_entries {
        let e = dir_ptr + 12 + i * 12;
        let off = u32at(buf, e)? as usize;
        let size = u32at(buf, e + 4)? as usize;
        let end = off.checked_add(size).ok_or("entry overflow")?;
        let sect = buf.get(off..end).ok_or("entry out of bounds")?;

        let identifier = u32at(sect, 0)?;
        if identifier == X3F_SECP {
            capture = Capture::parse(sect);
        }
        let (header_size, type_format, columns, rows, row_stride, camf_type, camf_vals) =
            match identifier {
                X3F_SECI => {
                    let typ = u32at(sect, 8)?;
                    let fmt = u32at(sect, 12)?;
                    (
                        28usize,
                        (typ << 16) | fmt,
                        u32at(sect, 16)?,
                        u32at(sect, 20)?,
                        u32at(sect, 24)?,
                        0,
                        [0; 4],
                    )
                }
                X3F_SECC => {
                    let t = u32at(sect, 8)?;
                    let v = [
                        u32at(sect, 12)?,
                        u32at(sect, 16)?,
                        u32at(sect, 20)?,
                        u32at(sect, 24)?,
                    ];
                    (28usize, 0, 0, 0, 0, t, v)
                }
                X3F_SECP => (24usize, 0, 0, 0, 0, 0, [0; 4]),
                _ => (8usize, 0, 0, 0, 0, 0, [0; 4]),
            };
        sections.push(Section {
            identifier,
            type_format,
            camf_type,
            camf_vals,
            data: sect.get(header_size..).unwrap_or(&[]),
            columns,
            rows,
            row_stride,
        });
    }
    Ok(Container {
        header: Header {
            white_balance,
            rotation,
        },
        sections,
        capture,
    })
}

// Huffman decode (SD9 / SD10 / SD14)

/// MSB-first bit reader over a byte slice.
struct Bits<'a> {
    d: &'a [u8],
    pos: usize,
    acc: u64,
    nbits: u32,
}
impl<'a> Bits<'a> {
    fn new(d: &'a [u8]) -> Self {
        Bits {
            d,
            pos: 0,
            acc: 0,
            nbits: 0,
        }
    }
    #[inline]
    fn refill(&mut self) {
        // splicing fun
        if self.pos + 8 <= self.d.len() {
            let next = u64::from_be_bytes(self.d[self.pos..self.pos + 8].try_into().unwrap());
            self.acc |= next >> self.nbits;
            let whole = (63 - self.nbits) >> 3; // bytes fully consumed into `acc`
            self.pos += whole as usize;
            self.nbits += whole * 8;
        } else {
            while self.nbits <= 56 {
                let byte = self.d.get(self.pos).copied().unwrap_or(0);
                self.pos += 1;
                self.acc |= (byte as u64) << (56 - self.nbits);
                self.nbits += 8;
            }
        }
    }
    #[inline]
    fn peek(&self, n: u32) -> u32 {
        (self.acc >> (64 - n)) as u32
    }
    #[inline]
    fn consume(&mut self, n: u32) {
        self.acc <<= n;
        self.nbits -= n;
    }
}

const NO_LEAF: i32 = i32::MIN;

struct Tree {
    branch: Vec<[i32; 2]>,
    leaf: Vec<i32>,
}
impl Tree {
    fn new() -> Self {
        let mut t = Tree {
            branch: Vec::new(),
            leaf: Vec::new(),
        };
        t.node();
        t
    }
    fn node(&mut self) -> i32 {
        self.branch.push([-1, -1]);
        self.leaf.push(NO_LEAF);
        (self.branch.len() - 1) as i32
    }
    fn add(&mut self, length: u32, code: u32, value: i32) {
        let mut t = 0i32;
        for i in 0..length {
            let pos = length - i - 1; // PATTERN_BIT_POS
            let bit = ((code >> pos) & 1) as usize;
            let mut next = self.branch[t as usize][bit];
            if next == -1 {
                next = self.node();
                self.branch[t as usize][bit] = next;
            }
            t = next;
        }
        self.leaf[t as usize] = value;
    }
    #[inline]
    fn walk(&self, bs: &mut Bits) -> i32 {
        let mut node = 0usize;
        while self.branch[node][0] != -1 || self.branch[node][1] != -1 {
            bs.refill();
            let b = bs.peek(1) as usize;
            bs.consume(1);
            let nx = self.branch[node][b];
            if nx == -1 {
                return 0; // malformed stream; defensive
            }
            node = nx as usize;
        }
        self.leaf[node]
    }
}

/// Table-driven Huffman decoder
const FAST_BITS: u32 = 12;
struct Huffman {
    tree: Tree,
    len: Box<[u8; 1 << FAST_BITS]>,  // code length for each FAST_BITS prefix
    val: Box<[u16; 1 << FAST_BITS]>, // decoded value for each FAST_BITS prefix
}
impl Huffman {
    fn new(table: &[u32], mapping: &[u16]) -> Self {
        let tree = build_tree(table, mapping);
        let mut len = Box::new([0u8; 1 << FAST_BITS]);
        let mut val = Box::new([0u16; 1 << FAST_BITS]);
        let use_map = table.len() == mapping.len();
        for (i, &element) in table.iter().enumerate() {
            let length = (element >> 27) & 0x1f;
            if element == 0 || length == 0 || length > FAST_BITS {
                continue;
            }
            let code = element & 0x07ff_ffff;
            // Reject a code wider than its declared length: otherwise `base`
            // indexes past the 2^FAST_BITS fast table
            if code >= (1u32 << length) {
                continue;
            }
            let value = if use_map { mapping[i] } else { i as u16 };

            let base = (code << (FAST_BITS - length)) as usize;
            for slot in 0..(1usize << (FAST_BITS - length)) {
                len[base + slot] = length as u8;
                val[base + slot] = value;
            }
        }
        Huffman { tree, len, val }
    }
    /// Decode one symbol; caller must have refilled the reader since the
    /// last 44 consumed bits: a refill banks ≥ 56, three table hits spend at
    /// most 3 × FAST_BITS = 36, and the escape path refills itself
    #[inline]
    fn diff(&self, bs: &mut Bits) -> i32 {
        let idx = bs.peek(FAST_BITS) as usize;
        let len = self.len[idx];
        if len != 0 {
            bs.consume(len as u32);
            self.val[idx] as i32
        } else {
            self.tree.walk(bs)
        }
    }
}

/// Build the SD14 Huffman tree from the 2^bits code table and value mapping
fn build_tree(table: &[u32], mapping: &[u16]) -> Tree {
    let mut tree = Tree::new();
    let use_map = table.len() == mapping.len();
    for (i, &element) in table.iter().enumerate() {
        if element != 0 {
            let length = (element >> 27) & 0x1f;
            let code = element & 0x07ff_ffff;
            let value = if use_map { mapping[i] as i32 } else { i as i32 };
            tree.add(length, code, value);
        }
    }
    tree
}

/// Decoded raw planes: 3-channel interleaved 16-bit (Foveon B/M/T)
struct Raw {
    columns: usize,
    rows: usize,
    data: Vec<u16>, // len = columns*rows*3
}

/// Decode the SD14 raw image section into interleaved 16-bit BMT
fn decode_raw(sect: &Section) -> R<Raw> {
    let bits = 10u32;
    let cols = sect.columns as usize;
    let rows = sect.rows as usize;
    if cols == 0 || rows == 0 || cols > 20000 || rows > 20000 {
        return Err("implausible image dimensions".into());
    }
    let npix = cols
        .checked_mul(rows)
        .and_then(|v| v.checked_mul(3))
        .ok_or("image too large")?;
    let table_size = 1usize << bits; // 1024

    let d = sect.data;
    let map_bytes = table_size * 2;
    let mapping: Vec<u16> = (0..table_size).map(|i| u16at(d, i * 2)).collect::<R<_>>()?;

    let mut data = vec![0u16; npix];

    if sect.row_stride == 0 {
        // compressed layout: mapping[u16;N], code-table[u32;N], image data,
        // footer of per-row bit offsets: row_offsets[u32;rows]
        let tab_bytes = table_size * 4;
        let table: Vec<u32> = (0..table_size)
            .map(|i| u32at(d, map_bytes + i * 4))
            .collect::<R<_>>()?;
        let huff = Huffman::new(&table, &mapping);
        let ro_bytes = rows.checked_mul(4).ok_or("image too large")?;
        let body_end = d
            .len()
            .checked_sub(ro_bytes)
            .ok_or("truncated huffman data")?;
        let body = d
            .get(map_bytes + tab_bytes..body_end)
            .ok_or("truncated huffman body")?;
        let row_offsets: Vec<usize> = (0..rows)
            .map(|i| u32at(d, body_end + i * 4).map(|v| v as usize))
            .collect::<R<_>>()?;
        decode_compressed(&huff, body, &row_offsets, cols, rows, &mut data);
    } else {
        // uncompressed layout: mapping[u16;N] packed `bits`-wide samples,
        // 3 per 32-bit word, row_stride bytes per row
        let body = d.get(map_bytes..).ok_or("truncated huffman body")?;
        decode_simple(
            &mapping,
            body,
            sect.row_stride as usize,
            bits,
            cols,
            rows,
            &mut data,
        );
    }

    Ok(Raw {
        columns: cols,
        rows,
        data,
    })
}

/// Number of image rows a worker claims per atomic step. Small enough to keep
/// the asymmetric P/E cores balanced at the tail, large enough that the shared
/// cursor is never a point of contention.
const ROW_CHUNK: usize = 8;

/// A raw pointer made `Send`/`Sync` so workers can write disjoint rows of a
/// shared buffer without a lock. Soundness is the caller's contract: every row
/// index must be handed to exactly one worker (guaranteed by `parallel_rows`).
#[derive(Clone, Copy)]
struct SyncPtr<T>(*mut T);
unsafe impl<T> Send for SyncPtr<T> {}
unsafe impl<T> Sync for SyncPtr<T> {}

impl<T> SyncPtr<T> {
    /// Offset the base pointer by `count` elements. Taking `self` by value makes
    /// a closure capture the whole (`Sync`) wrapper rather than the bare pointer.
    ///
    /// # Safety
    /// `count` must keep the result within the original allocation.
    #[inline]
    unsafe fn add(self, count: usize) -> *mut T {
        unsafe { self.0.add(count) }
    }
}

/// account for asymmetric P/E topology
fn parallel_rows(rows: usize, chunk: usize, worker: impl Fn(usize) + Sync) {
    let threads = std::thread::available_parallelism()
        .map_or(1, |n| n.get())
        .min(rows.max(1));
    if threads <= 1 {
        for row in 0..rows {
            worker(row);
        }
        return;
    }
    let cursor = AtomicUsize::new(0);
    std::thread::scope(|s| {
        for _ in 0..threads {
            let (cursor, worker) = (&cursor, &worker);
            s.spawn(move || {
                loop {
                    let start = cursor.fetch_add(chunk, Ordering::Relaxed);
                    if start >= rows {
                        break;
                    }
                    for row in start..(start + chunk).min(rows) {
                        worker(row);
                    }
                }
            });
        }
    });
}

/// Compressed Huffman path
fn decode_compressed(
    tree: &Huffman,
    body: &[u8],
    row_offsets: &[usize],
    cols: usize,
    rows: usize,
    out: &mut [u16],
) {
    let row_len = cols * 3;
    let decode_row = |row: usize, out_row: &mut [u16]| -> i32 {
        let start = row_offsets[row].min(body.len());
        let mut bs = Bits::new(&body[start..]);
        let mut c = [0i16; 3];
        let mut minimum = 0i32;
        for px in out_row.chunks_exact_mut(3) {
            // one refill covers all three symbols
            bs.refill();
            for (color, o) in px.iter_mut().enumerate() {
                // int16_t accumulation with wraparound carries signed deltas
                // encoded as the 16-bit two's-complement mapping values
                c[color] = (c[color] as i32).wrapping_add(tree.diff(&mut bs)) as i16;
                minimum = minimum.min(c[color] as i32);
                *o = c[color] as u16;
            }
        }
        minimum
    };

    let base = SyncPtr(out.as_mut_ptr());
    let min = AtomicI32::new(0);
    parallel_rows(rows, ROW_CHUNK, |row| {
        // SAFETY: each row is claimed by exactly one worker and the
        // [row*row_len, +row_len) slices are disjoint, so the writes never alias.
        let out_row = unsafe { std::slice::from_raw_parts_mut(base.add(row * row_len), row_len) };
        let m = decode_row(row, out_row);
        if m < 0 {
            min.fetch_min(m, Ordering::Relaxed);
        }
    });
    let minimum = min.load(Ordering::Relaxed);

    // legacy negative-offset correction
    if minimum < 0 {
        let offset = -minimum;
        for v in out.iter_mut() {
            *v = (*v as i16 as i32 + offset).max(0) as u16;
        }
    }
}

/// Uncompressed Huffman path
fn decode_simple(
    mapping: &[u16],
    body: &[u8],
    row_stride: usize,
    bits: u32,
    cols: usize,
    rows: usize,
    out: &mut [u16],
) {
    let mask = (1u32 << bits) - 1;
    let get = |idx: u16| -> i32 {
        if mapping.is_empty() {
            idx as i32
        } else {
            mapping[idx as usize] as i32
        }
    };
    // mild parallel 
    let row_len = cols * 3;
    let base_ptr = SyncPtr(out.as_mut_ptr());
    parallel_rows(rows, ROW_CHUNK, |row| {
        let out_row = unsafe { std::slice::from_raw_parts_mut(base_ptr.add(row * row_len), row_len) };
        let base = row * row_stride;
        let mut c = [0u16; 3];
        for (col, px) in out_row.chunks_exact_mut(3).enumerate() {
            let val = u32at(body, base + col * 4).unwrap_or(0);
            for (color, o) in px.iter_mut().enumerate() {
                let idx = ((val >> (color as u32 * bits)) & mask) as u16;
                c[color] = (c[color] as i32).wrapping_add(get(idx)) as u16;
                *o = if (c[color] as i16) > 0 { c[color] } else { 0 };
            }
        }
    });
}

// CAMF (camera metadata): type-2 decrypt + entry table

/// Decrypt a CAMF type-2 (SD9..SD14) section with the LCG/XOR stream cipher.
fn camf_decode_type2(data: &[u8], crypt_key: u32) -> Vec<u8> {
    let mut key = crypt_key;
    let mut out = Vec::with_capacity(data.len());
    for &old in data {
        key = key.wrapping_mul(1597).wrapping_add(51749) % 244944;
        let tmp = ((key as i64 * 301593171) >> 24) as u32;
        let mask = ((((key << 8).wrapping_sub(tmp)) >> 1).wrapping_add(tmp) >> 17) as u8;
        out.push(old ^ mask);
    }
    out
}

enum Mat {
    F64(Vec<f64>),
    I32(Vec<i32>),
    U32(Vec<u32>),
}
struct Matrix {
    dim: usize,
    dims: [usize; 3],
    data: Mat,
}
enum Value {
    Matrix(Matrix),
    Property(Vec<(String, String)>),
}
struct Entry {
    name: String,
    value: Value,
}

struct Camf {
    entries: Vec<Entry>,
}

impl Camf {
    fn parse(sect: &Section) -> R<Camf> {
        if sect.camf_type != 2 {
            return Err(format!(
                "unsupported CAMF type {} (SD14 expects type 2)",
                sect.camf_type
            ));
        }
        let crypt_key = sect.camf_vals[3];
        let decoded = camf_decode_type2(sect.data, crypt_key);
        let entries = parse_entries(&decoded)?;
        Ok(Camf { entries })
    }

    fn find(&self, name: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|e| e.name == name)
            .map(|e| &e.value)
    }
    fn matrix(&self, name: &str) -> Option<&Matrix> {
        match self.find(name)? {
            Value::Matrix(m) => Some(m),
            _ => None,
        }
    }
    fn floats(&self, name: &str) -> Option<&[f64]> {
        match &self.matrix(name)?.data {
            Mat::F64(v) => Some(v),
            _ => None,
        }
    }
    fn ints(&self, name: &str) -> Option<&[i32]> {
        match &self.matrix(name)?.data {
            Mat::I32(v) => Some(v),
            _ => None,
        }
    }
    fn uints(&self, name: &str) -> Option<&[u32]> {
        match &self.matrix(name)?.data {
            Mat::U32(v) => Some(v),
            _ => None,
        }
    }
    fn float(&self, name: &str) -> Option<f64> {
        self.floats(name).filter(|v| v.len() == 1).map(|v| v[0])
    }
    fn vec3f(&self, name: &str) -> Option<[f64; 3]> {
        self.floats(name)
            .filter(|v| v.len() == 3)
            .map(|v| [v[0], v[1], v[2]])
    }
    fn property(&self, list: &str) -> Option<&[(String, String)]> {
        match self.find(list)? {
            Value::Property(p) => Some(p),
            _ => None,
        }
    }
    fn property_get(&self, list: &str, key: &str) -> Option<&str> {
        self.property(list)?
            .iter()
            .find(|(n, _)| n == key)
            .map(|(_, v)| v.as_str())
    }
    /// Resolve a per-white-balance matrix (`list[wb]` → matrix name → matrix).
    fn matrix_for_wb(&self, list: &str, wb: &str, dim0: usize, dim1: usize) -> Option<&[f64]> {
        let mat_name = self.property_get(list, wb).or_else(|| {
            if wb == "Daylight" {
                self.property_get(list, "Sunlight") // SD1 workaround
            } else {
                None
            }
        })?;
        let m = self.matrix(mat_name)?;
        let want = dim0.max(1) * dim1.max(1);
        match &m.data {
            Mat::F64(v) if v.len() == want => Some(v.as_slice()),
            _ => None,
        }
    }
}

/// Parse the decrypted CAMF blob into a flat entry list.
fn parse_entries(d: &[u8]) -> R<Vec<Entry>> {
    let mut entries = Vec::new();
    let mut p = 0usize;
    while p + 20 <= d.len() {
        let id = u32at(d, p)?;
        if id != CMBP && id != CMBT && id != CMBM {
            break; // end / padding
        }
        let entry_size = u32at(d, p + 8)? as usize;
        let name_offset = u32at(d, p + 12)? as usize;
        let value_offset = u32at(d, p + 16)? as usize;
        if entry_size < 20 || p + entry_size > d.len() {
            break;
        }
        if id == CMBT {
            p += entry_size; // text entries (firmware strings, etc.) are unused
            continue;
        }
        let entry = &d[p..p + entry_size];
        let name = cstr(entry, name_offset);
        let value = match id {
            CMBM => parse_matrix(entry, value_offset)?,
            CMBP => parse_property(entry, value_offset)?,
            _ => unreachable!(),
        };
        entries.push(Entry { name, value });
        p += entry_size;
    }
    Ok(entries)
}

fn parse_property(entry: &[u8], value_offset: usize) -> R<Value> {
    let v = value_offset;
    let num = u32at(entry, v)? as usize;
    let off = u32at(entry, v + 4)? as usize;
    let mut pairs = Vec::with_capacity(num.min(4096));
    for i in 0..num {
        let name_off = off + u32at(entry, v + 8 + 8 * i)? as usize;
        let value_off = off + u32at(entry, v + 8 + 8 * i + 4)? as usize;
        pairs.push((cstr(entry, name_off), cstr(entry, value_off)));
    }
    Ok(Value::Property(pairs))
}

fn parse_matrix(entry: &[u8], value_offset: usize) -> R<Value> {
    let v = value_offset;
    let mtype = u32at(entry, v)?;
    let dim = u32at(entry, v + 4)? as usize;
    let data_off = u32at(entry, v + 8)? as usize;
    if dim > 3 {
        return Err("matrix with >3 dims".into());
    }
    let mut dims = [1usize; 3];
    let mut elements = 1usize;
    for (i, slot) in dims.iter_mut().enumerate().take(dim) {
        let size = u32at(entry, v + 12 + 12 * i)? as usize;
        *slot = size;
        elements = elements.checked_mul(size).ok_or("matrix too large")?;
    }
    if elements > 1 << 24 {
        return Err("matrix too large".into());
    }
    // bound element count
    let elem_size = match mtype {
        0 | 6 => 2,
        1..=3 => 4,
        5 => 1,
        _ => return Err(format!("unknown matrix element type {mtype}")),
    };
    let base = data_off;
    let span = elements.checked_mul(elem_size).ok_or("matrix too large")?;
    if base.checked_add(span).is_none_or(|end| end > entry.len()) {
        return Err("matrix data out of bounds".into());
    }
    let data = match mtype {
        0 => Mat::I32(
            (0..elements)
                .map(|i| i16at(entry, base + i * 2).map(|x| x as i32))
                .collect::<R<_>>()?,
        ),
        1 | 2 => Mat::U32(
            (0..elements)
                .map(|i| u32at(entry, base + i * 4))
                .collect::<R<_>>()?,
        ),
        3 => Mat::F64(
            (0..elements)
                .map(|i| f32at(entry, base + i * 4).map(|x| x as f64))
                .collect::<R<_>>()?,
        ),
        5 => Mat::U32(
            (0..elements)
                .map(|i| u8at(entry, base + i).map(|x| x as u32))
                .collect::<R<_>>()?,
        ),
        6 => Mat::U32(
            (0..elements)
                .map(|i| u16at(entry, base + i * 2).map(|x| x as u32))
                .collect::<R<_>>()?,
        ),
        _ => return Err(format!("unknown matrix element type {mtype}")),
    };
    Ok(Value::Matrix(Matrix { dim, dims, data }))
}

// 3x3 / 3x1 colour math (row-major) and constants

type M3 = [f64; 9];
type V3 = [f64; 3];

#[inline]
fn mul3x3(a: &M3, b: &M3) -> M3 {
    let mut c = [0.0; 9];
    for r in 0..3 {
        for col in 0..3 {
            c[r * 3 + col] =
                a[r * 3] * b[col] + a[r * 3 + 1] * b[3 + col] + a[r * 3 + 2] * b[6 + col];
        }
    }
    c
}
#[inline]
fn mul3x1(a: &M3, v: &V3) -> V3 {
    [
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    ]
}
fn inv3x3(a: &M3) -> M3 {
    let (m00, m01, m02) = (a[0], a[1], a[2]);
    let (m10, m11, m12) = (a[3], a[4], a[5]);
    let (m20, m21, m22) = (a[6], a[7], a[8]);
    let av = m11 * m22 - m12 * m21;
    let bv = -(m10 * m22 - m12 * m20);
    let cv = m10 * m21 - m11 * m20;
    let dv = -(m01 * m22 - m02 * m21);
    let ev = m00 * m22 - m02 * m20;
    let fv = -(m00 * m21 - m01 * m20);
    let gv = m01 * m12 - m02 * m11;
    let hv = -(m00 * m12 - m02 * m10);
    let iv = m00 * m11 - m01 * m10;
    let det = m00 * av + m01 * bv + m02 * cv;
    let d = if det == 0.0 { 1.0 } else { det };
    [
        av / d,
        dv / d,
        gv / d,
        bv / d,
        ev / d,
        hv / d,
        cv / d,
        fv / d,
        iv / d,
    ]
}
#[inline]
fn diag(v: &V3) -> M3 {
    [v[0], 0.0, 0.0, 0.0, v[1], 0.0, 0.0, 0.0, v[2]]
}

const SRGB_TO_XYZ: M3 = [
    0.4124, 0.3576, 0.1805, // D65-referenced sRGB primaries
    0.2126, 0.7152, 0.0722, //
    0.0193, 0.1192, 0.9505,
];
const XYZ_TO_SRGB: M3 = [
    3.2406, -1.5372, -0.4986, //
    -0.9689, 1.8758, 0.0415, //
    0.0557, -0.2040, 1.0570,
];
const BRADFORD_D65_TO_D50: M3 = [
    1.0478112, 0.0228866, -0.0501270, //
    0.0295424, 0.9904844, -0.0170491, //
    -0.0092345, 0.0150436, 0.7521316,
];
/// D65 reference white in XYZ (used to derive the raw neutral on the pre-TRUE path).
const D65_XYZ: V3 = [0.95047, 1.00000, 1.08883];

/// Raw neutral = (raw→XYZ)⁻¹ · D65_white. Mirrors the reference `get_raw_neutral`.
#[inline]
fn raw_neutral(raw_to_xyz: &M3) -> V3 {
    mul3x1(&inv3x3(raw_to_xyz), &D65_XYZ)
}

// Metadata extraction → DNG calibration

/// Raw→XYZ for the pre-TRUE engine (SD9/10/14): `wb_correction · cam_to_xyz`,
/// from the `WhiteBalanceCorrections` and `WhiteBalanceIlluminants` lists
fn raw_to_xyz_legacy(camf: &Camf, wb: &str) -> Option<M3> {
    let cam: M3 = camf
        .matrix_for_wb("WhiteBalanceIlluminants", wb, 3, 3)?
        .try_into()
        .ok()?;
    let corr: M3 = camf
        .matrix_for_wb("WhiteBalanceCorrections", wb, 3, 3)?
        .try_into()
        .ok()?;
    Some(mul3x3(&corr, &cam))
}

/// Camera white balance gain for `wb`, prefers TRUE engine
fn wb_gain(camf: &Camf, wb: &str) -> Option<V3> {
    let mut g = match camf
        .matrix_for_wb("WhiteBalanceGains", wb, 3, 0)
        .or_else(|| camf.matrix_for_wb("DP1_WhiteBalanceGains", wb, 3, 0))
    {
        Some(g) if g.len() == 3 => [g[0], g[1], g[2]],
        _ => {
            let n = raw_neutral(&raw_to_xyz_legacy(camf, wb)?);
            [1.0 / n[0], 1.0 / n[1], 1.0 / n[2]]
        }
    };
    for fact in [
        "SensorAdjustmentGainFact",
        "TempGainFact",
        "FNumberGainFact",
    ] {
        if let Some(f) = camf.vec3f(fact) {
            for i in 0..3 {
                g[i] *= f[i];
            }
        }
    }
    Some(g)
}

/// Camera-native (BMT) → XYZ (D65) for `wb`. prefers TRUE-engine
fn bmt_to_xyz(camf: &Camf, wb: &str) -> Option<M3> {
    if let Some(cc) = camf
        .matrix_for_wb("WhiteBalanceColorCorrections", wb, 3, 3)
        .or_else(|| camf.matrix_for_wb("DP1_WhiteBalanceColorCorrections", wb, 3, 3))
    {
        let cc: M3 = cc.try_into().ok()?;
        return Some(mul3x3(&SRGB_TO_XYZ, &cc));
    }
    let raw_to_xyz = raw_to_xyz_legacy(camf, wb)?;
    let n = raw_neutral(&raw_to_xyz);
    Some(mul3x3(&raw_to_xyz, &diag(&n)))
}

/// True iff the camera carries (DP1_)WhiteBalanceColorCorrections AND
/// (DP1_)WhiteBalanceGains property lists — the reference's `is_TRUE_engine`
/// test, which selects RawSaturationLevel over SaturationLevel. SD14 qualifies.
fn is_true_engine(camf: &Camf) -> bool {
    let cc = camf.property("WhiteBalanceColorCorrections").is_some()
        || camf.property("DP1_WhiteBalanceColorCorrections").is_some();
    let g = camf.property("WhiteBalanceGains").is_some()
        || camf.property("DP1_WhiteBalanceGains").is_some();
    cc && g
}

/// Per-channel maximum raw (saturation) level, following `x3f_get_max_raw`:
/// ImageDepth (Merrill/Quattro) → RawSaturationLevel (TRUE engine) /
/// SaturationLevel (pre-TRUE), with robust fallbacks.
fn max_raw(camf: &Camf) -> V3 {
    let pick = |v: &[i32]| [v[0] as f64, v[1] as f64, v[2] as f64];
    if let Some(d) = camf.uints("ImageDepth")
        && d.len() == 1
        && d[0] < 32
    {
        let m = ((1u32 << d[0]) - 1) as f64;
        return [m, m, m];
    }
    let order = if is_true_engine(camf) {
        ["RawSaturationLevel", "SaturationLevel"]
    } else {
        ["SaturationLevel", "RawSaturationLevel"]
    };
    for name in order {
        if let Some(v) = camf.ints(name)
            && v.len() == 3
        {
            return pick(v);
        }
    }
    if let Some(v) = camf.ints("MaxOutputLevel")
        && v.len() == 3
    {
        return pick(v);
    }
    [4095.0, 4095.0, 4095.0] // 12-bit fallback
}

/// Transform a CAMF rect `[x0,y0,x1,y1]` (KeepImageArea coords, inclusive) into
/// the decoded image's pixel coordinates. Mirrors `x3f_transform_rect_to_keep_image`.
fn transform_rect(camf: &Camf, cols: usize, rows: usize, rect: [u32; 4]) -> Option<[usize; 4]> {
    let keep = camf.uints("KeepImageArea")?;
    if keep.len() != 4 {
        return None;
    }
    let (kx0, ky0, kx1, ky1) = (keep[0], keep[1], keep[2], keep[3]);
    if kx1 < kx0 || ky1 < ky0 {
        return None; // malformed KeepImageArea
    }
    let keep_cols = (kx1 - kx0 + 1) as usize;
    let keep_rows = (ky1 - ky0 + 1) as usize;
    let mut x0 = rect[0].max(kx0);
    let mut y0 = rect[1].max(ky0);
    let mut x1 = rect[2].min(kx1);
    let mut y1 = rect[3].min(ky1);
    if x0 > x1 || y0 > y1 {
        return None;
    }
    x0 -= kx0;
    y0 -= ky0;
    x1 -= kx0;
    y1 -= ky0;
    // Rescale from KeepImageArea resolution to the decoded image (identity for SD14).
    let xs = |x: u32| (x as usize * cols / keep_cols).min(cols.saturating_sub(1));
    let ys = |y: u32| (y as usize * rows / keep_rows).min(rows.saturating_sub(1));
    Some([xs(x0), ys(y0), xs(x1), ys(y1)])
}

fn camf_rect(camf: &Camf, name: &str) -> Option<[u32; 4]> {
    let v = camf.uints(name)?;
    if v.len() == 4 {
        Some([v[0], v[1], v[2], v[3]])
    } else {
        None
    }
}

/// Mean per-channel black level from the dark-shield reference regions
fn black_level(camf: &Camf, raw: &Raw) -> V3 {
    let mut sum = [0f64; 3];
    let mut count = 0u64;
    let mut accumulate = |r: [usize; 4]| {
        for y in r[1]..=r[3] {
            for x in r[0]..=r[2] {
                let i = 3 * (y * raw.columns + x);
                for (c, s) in sum.iter_mut().enumerate() {
                    *s += raw.data[i + c] as f64;
                }
                count += 1;
            }
        }
    };
    for name in ["DarkShieldTop", "DarkShieldBottom"] {
        if let Some(rc) = camf_rect(camf, name)
            && let Some(t) = transform_rect(camf, raw.columns, raw.rows, rc)
        {
            accumulate(t);
        }
    }
    // Left / right dark columns: DarkShieldColRange = [[left0,left1],[right0,right1]];
    // each spans the full image height (clipped to KeepImageArea).
    if let Some(col) = camf.uints("DarkShieldColRange")
        && col.len() == 4
    {
        for (x0, x1) in [(col[0], col[1]), (col[2], col[3])] {
            if let Some(t) = transform_rect(camf, raw.columns, raw.rows, [x0, 0, x1, u32::MAX]) {
                accumulate(t);
            }
        }
    }
    if count == 0 {
        return [0.0, 0.0, 0.0];
    }
    [
        sum[0] / count as f64,
        sum[1] / count as f64,
        sum[2] / count as f64,
    ]
}

/// DNG ActiveArea `[top,left,bottom,right]` (exclusive bottom/right).
fn active_area(camf: &Camf, raw: &Raw) -> Option<[u32; 4]> {
    let rc = camf_rect(camf, "ActiveImageArea")?;
    let t = transform_rect(camf, raw.columns, raw.rows, rc)?;
    Some([t[1] as u32, t[0] as u32, t[3] as u32 + 1, t[2] as u32 + 1])
}

/// Resolve the white-balance name to use, honouring the as-shot tag, a CLI
/// override, and falling back to any key the camera actually provides.
fn resolve_wb(camf: &Camf, header: &Header, override_wb: Option<&str>) -> String {
    // A WB is usable if any of the gain (TRUE-engine) or illuminant/correction
    // (pre-TRUE) property lists carry an entry for it.
    let has = |w: &str| {
        [
            "WhiteBalanceGains",
            "DP1_WhiteBalanceGains",
            "WhiteBalanceIlluminants",
            "WhiteBalanceCorrections",
        ]
        .iter()
        .any(|list| camf.property_get(list, w).is_some())
    };
    if let Some(w) = override_wb
        && has(w)
    {
        return w.to_string();
    }
    let asshot = header.white_balance.trim();
    if !asshot.is_empty() && has(asshot) {
        return asshot.to_string();
    }
    for w in ["Sunlight", "Daylight", "Auto", "Overcast", "Cloudy"] {
        if has(w) {
            return w.to_string();
        }
    }
    // Last resort: first available key from any WB list, else the as-shot string.
    [
        "WhiteBalanceGains",
        "DP1_WhiteBalanceGains",
        "WhiteBalanceIlluminants",
        "WhiteBalanceCorrections",
    ]
    .iter()
    .find_map(|list| camf.property(list).and_then(|p| p.first()))
    .map(|(n, _)| n.clone())
    .unwrap_or_else(|| asshot.to_string())
}

struct Calibration {
    color_matrix1: M3,   // XYZ(D65) -> camera (BMT)
    forward_matrix1: M3, // camera (BMT) -> XYZ(D50)
    camera_calibration1: M3,
    as_shot_neutral: V3,
    baseline_exposure: f64,
    iso: f64,
    /// Per-channel (raw - black)/(max-black) -> [0,1]
    black: V3,
    max: V3,
    gain: V3,
}

struct SpatialGain {
    rows: u32,
    cols: u32,
    channels: u32,
    gain: Vec<f32>,
}

fn classic_spatial_gain(camf: &Camf, wb: &str) -> Option<SpatialGain> {
    let matrix = camf
        .property_get("SpatialGainTables", wb)
        .and_then(|name| camf.matrix(name))
        .or_else(|| camf.matrix("SpatialGain"))?;
    let channels = if matrix.dim >= 3 { matrix.dims[2] } else { 1 };
    let (rows, cols) = (matrix.dims[0], matrix.dims[1]);
    if rows < 2 || cols < 2 || channels == 0 {
        return None;
    }
    let want = rows.checked_mul(cols)?.checked_mul(channels)?;
    let Mat::F64(values) = &matrix.data else {
        return None;
    };
    if values.len() != want {
        return None;
    }
    Some(SpatialGain {
        rows: rows as u32,
        cols: cols as u32,
        channels: channels as u32,
        gain: values.iter().map(|&v| v as f32).collect(),
    })
}

/// The D65 reference illuminant. CalibrationIlluminant1 is tagged D65, and the
/// reference (`x3f_output_dng.c`) uses "Overcast" as its D65 proxy for the SD9/14.
const D65_WB: &str = "Overcast";

fn build_calibration(camf: &Camf, raw: &Raw, wb: &str) -> R<Calibration> {
    let gain = wb_gain(camf, wb).ok_or_else(|| format!("no white-balance gain for '{wb}'"))?;
    let bmt = bmt_to_xyz(camf, wb).ok_or_else(|| format!("no colour matrix for '{wb}'"))?;

    let color_matrix1 = inv3x3(&bmt); // XYZ -> BMT (as-shot illuminant)
    let forward_matrix1 = mul3x3(&BRADFORD_D65_TO_D50, &bmt); // BMT -> XYZ(D50)
    let as_shot_neutral = [1.0 / gain[0], 1.0 / gain[1], 1.0 / gain[2]];

    // CameraCalibration1 = diag(1/gain(D65)), exactly as the reference. With the
    // as-shot colour matrices this reconciles the as-shot AsShotNeutral against the
    // D65 calibration illuminant. Apple's Core Image RAW pipeline applies this
    // matrix materially (identity here yields a strong yellow/green cast), so it is
    // required — not a no-op. Falls back to identity if no D65 gain is available.
    let gain_d65 = wb_gain(camf, D65_WB).unwrap_or([1.0, 1.0, 1.0]);
    let camera_calibration1 = diag(&[1.0 / gain_d65[0], 1.0 / gain_d65[1], 1.0 / gain_d65[2]]);

    let capture_iso = camf.float("CaptureISO").filter(|&v| v > 0.0);
    let baseline_exposure = match (capture_iso, camf.float("SensorISO")) {
        (Some(cap), Some(sen)) if sen > 0.0 => (cap / sen).log2(),
        _ => 0.0,
    };

    Ok(Calibration {
        color_matrix1,
        forward_matrix1,
        camera_calibration1,
        as_shot_neutral,
        baseline_exposure,
        iso: capture_iso.unwrap_or(0.0),
        black: black_level(camf, raw),
        max: max_raw(camf),
        gain,
    })
}

/// Normalise raw BMT to a uniform [0,65535] linear signal (BlackLevel 0 /
/// WhiteLevel 65535). This is a per-channel affine remap using the camera's own
/// black & saturation — no gain, colour, or tone is applied. The rendered-linear
/// value is identical to the reference, so `AsShotNeutral = 1/gain` stays valid.
fn normalise(raw: &Raw, cal: &Calibration) -> Vec<u16> {
    let scale: V3 = [
        1.0 / (cal.max[0] - cal.black[0]).max(1.0),
        1.0 / (cal.max[1] - cal.black[1]).max(1.0),
        1.0 / (cal.max[2] - cal.black[2]).max(1.0),
    ];
    let mut out = vec![0u16; raw.data.len()];
    let row_len = raw.columns * 3;
    // The per-channel remap is a pure function of the 16-bit sample, so bake it
    // into a LUT once (same f64 expression → bit-identical output) and reduce
    // each sample to a single table load
    let lut: [Vec<u16>; 3] = std::array::from_fn(|c| {
        (0..=u16::MAX)
            .map(|s| {
                let n = (s as f64 - cal.black[c]) * scale[c];
                (n.clamp(0.0, 1.0) * 65535.0).round() as u16
            })
            .collect()
    });
    let base = SyncPtr(out.as_mut_ptr());
    parallel_rows(raw.rows, ROW_CHUNK, |row| {
        let src = &raw.data[row * row_len..][..row_len];
        // SAFETY: each output row [row*row_len, +row_len) is claimed by exactly
        // one worker, so the disjoint writes never alias.
        let dst = unsafe { std::slice::from_raw_parts_mut(base.add(row * row_len), row_len) };
        for (s, d) in src.chunks_exact(3).zip(dst.chunks_exact_mut(3)) {
            for c in 0..3 {
                d[c] = lut[c][s[c] as usize];
            }
        }
    });
    out
}

// sRGB preview (embedded thumbnail)

#[inline]
fn srgb_encode(lin: f64) -> u8 {
    let l = lin.clamp(0.0, 1.0);
    let s = if l <= 0.0031308 {
        12.92 * l
    } else {
        1.055 * l.powf(1.0 / 2.4) - 0.055
    };
    (s * 255.0).round().clamp(0.0, 255.0) as u8
}

struct Preview {
    columns: usize,
    rows: usize,
    data: Vec<u8>, // RGB8 interleaved
}

/// Build a small, correct sRGB preview from the normalised raster within the
/// active area (so DNG browsers show a sensible thumbnail; CIRAWFilter ignores it).
fn build_preview(
    norm: &[u16],
    raw: &Raw,
    cal: &Calibration,
    area: Option<[u32; 4]>,
    max_w: usize,
) -> Preview {
    let (top, left, bottom, right) = match area {
        Some(a) => (a[0] as usize, a[1] as usize, a[2] as usize, a[3] as usize),
        None => (0, 0, raw.rows, raw.columns),
    };
    let aw = right.saturating_sub(left).max(1);
    let ah = bottom.saturating_sub(top).max(1);
    let reduction = aw.div_ceil(max_w);
    let pcols = (aw / reduction).max(1);
    let prows = (ah / reduction).max(1);

    // conv = XYZ->sRGB · (BMT->XYZ) · diag(gain) ; reconstruct BMT->XYZ from ColorMatrix1.
    let bmt = inv3x3(&cal.color_matrix1);
    let conv = mul3x3(&XYZ_TO_SRGB, &mul3x3(&bmt, &diag(&cal.gain)));

    let mut data = vec![0u8; pcols * prows * 3];
    let r2 = (reduction * reduction) as f64;
    let stride = pcols * 3;
    let base = SyncPtr(data.as_mut_ptr());
    parallel_rows(prows, ROW_CHUNK, |py| {
        // SAFETY: each preview row [py*stride, +stride) is claimed by exactly one worker
        let row = unsafe { std::slice::from_raw_parts_mut(base.add(py * stride), stride) };
        for px in 0..pcols {
            let mut acc = [0f64; 3];
            for ry in 0..reduction {
                for rx in 0..reduction {
                    let y = top + py * reduction + ry;
                    let x = left + px * reduction + rx;
                    let i = 3 * (y * raw.columns + x);
                    for c in 0..3 {
                        acc[c] += norm[i + c] as f64;
                    }
                }
            }
            let input = [
                acc[0] / r2 / 65535.0,
                acc[1] / r2 / 65535.0,
                acc[2] / r2 / 65535.0,
            ];
            let out = mul3x1(&conv, &input);
            for c in 0..3 {
                row[px * 3 + c] = srgb_encode(out[c]);
            }
        }
    });
    Preview {
        columns: pcols,
        rows: prows,
        data,
    }
}

/// integrated development into scene-linear sRGB
struct Developed {
    width: usize,
    height: usize,
    orientation: u16,
    /// scene-linear sRGB, little-endian IEEE binary16 bytes, channels interleaved
    data: Vec<u8>,
    /// samples per pixel: 3 (RGB, for the TIFF container) or 4 (RGBA, alpha = 1)
    channels: usize,
    mono: [f32; 3],
}

/// IEEE binary16 1.0 — the alpha fill for 4-channel output.
const HALF_ONE: u16 = 0x3c00;

/// Bilinearly sample the spatial-gain grid for channel `ch` at active-area pixel `(px, py)` of a `w x h` crop
/// grid is `sg.rows x sg.cols` with `sg.channels` channels per grid point
struct GainInterp<'a> {
    gain: &'a [f32],
    col0: Vec<usize>, // c0 * channels, per output column
    col1: Vec<usize>, // c1 * channels, per output column
    cf: Vec<f32>,     // column fraction, per output column
    chn: usize,
    last_row: usize, // sg.rows - 1
    stride: usize,   // cols * channels (one grid row)
    h: usize,
}

impl<'a> GainInterp<'a> {
    fn new(sg: &'a SpatialGain, w: usize, h: usize) -> Self {
        let (cols, chn) = (sg.cols as usize, sg.channels as usize);
        let last_col = cols - 1;
        let mut col0 = vec![0usize; w];
        let mut col1 = vec![0usize; w];
        let mut cf = vec![0f32; w];
        for px in 0..w {
            let gc = if w > 1 {
                px as f32 / (w - 1) as f32 * last_col as f32
            } else {
                0.0
            };
            let c0 = (gc as usize).min(last_col); // gc >= 0, so truncation == floor
            col0[px] = c0 * chn;
            col1[px] = (c0 + 1).min(last_col) * chn;
            cf[px] = gc - c0 as f32;
        }
        GainInterp {
            gain: &sg.gain,
            col0,
            col1,
            cf,
            chn,
            last_row: sg.rows as usize - 1,
            stride: cols * chn,
            h,
        }
    }

    /// Row base offsets and fraction for output row `py`.
    #[inline]
    fn row(&self, py: usize) -> (usize, usize, f32) {
        let gr = if self.h > 1 {
            py as f32 / (self.h - 1) as f32 * self.last_row as f32
        } else {
            0.0
        };
        let r0 = (gr as usize).min(self.last_row);
        let r1 = (r0 + 1).min(self.last_row);
        (r0 * self.stride, r1 * self.stride, gr - r0 as f32)
    }

    /// Bilinearly interpolated gain for channel `c` at output column `px`.
    #[inline]
    fn sample(&self, px: usize, c: usize, rb0: usize, rb1: usize, rf: f32) -> f32 {
        let cch = if self.chn > 1 { c } else { 0 };
        let (c0, c1, cf) = (self.col0[px] + cch, self.col1[px] + cch, self.cf[px]);
        let top = self.gain[rb0 + c0] + cf * (self.gain[rb0 + c1] - self.gain[rb0 + c0]);
        let bot = self.gain[rb1 + c0] + cf * (self.gain[rb1 + c1] - self.gain[rb1 + c0]);
        top + rf * (bot - top)
    }
}

/// Rec.709 luma — the neutral monochrome fallback when no top-layer weights apply.
const REC709_LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];

/// a Foveon highlight where one stacked layer saturates before the others
/// renders magenta, so we fade such pixels toward neutral etc
const CLIP_KNEE: f32 = 0.88;
/// Reciprocal of the highlight-reconstruction knee span. The per-pixel path
/// multiplies by this instead of dividing (an FDIV is ~10× the latency of an
/// FMUL); it is a compile-time constant, so `x * CLIP_SPAN_INV` is the identical
/// operation in the scalar and NEON paths — they stay bit-for-bit matched.
const CLIP_SPAN_INV: f32 = 1.0 / (1.0 - CLIP_KNEE);

/// Develop one pixel of decoded raw BMT into a scene-linear sRGB half-float triple
fn develop_pixel(
    s: &[u16],
    gain: Option<[f32; 3]>,
    black: &[f32; 3],
    scale: &[f32; 3],
    m: &[f32; 9],
) -> [u16; 3] {
    let n = [
        (s[0] as f32 - black[0]) * scale[0],
        (s[1] as f32 - black[1]) * scale[1],
        (s[2] as f32 - black[2]) * scale[2],
    ];
    let sat = n[0].max(n[1]).max(n[2]); // raw-referred clip indicator
    let v = match gain {
        Some(g) => [
            (n[0] * g[0]).max(0.0),
            (n[1] * g[1]).max(0.0),
            (n[2] * g[2]).max(0.0),
        ],
        None => [n[0].max(0.0), n[1].max(0.0), n[2].max(0.0)],
    };
    // Colour matrix (XYZ→sRGB · BMT→XYZ · diag(gain)); keep linear headroom
    let mut rgb = [
        m[2].mul_add(v[2], m[1].mul_add(v[1], m[0] * v[0])),
        m[5].mul_add(v[2], m[4].mul_add(v[1], m[3] * v[0])),
        m[8].mul_add(v[2], m[7].mul_add(v[1], m[6] * v[0])),
    ];
    // Highlight reconstruction
    let t = ((sat - CLIP_KNEE) * CLIP_SPAN_INV).clamp(0.0, 1.0);
    if t > 0.0 {
        let mx = rgb[0].max(rgb[1]).max(rgb[2]);
        for v in &mut rgb {
            *v += t * (mx - *v);
        }
    }

    pack_rgb_f16(rgb)
}

/// Develop the decoded raw BMT planes into scene-linear sRGB over active area
/// `step` 1 develops every pixel (NEON fast path); `step` 2 emits a
/// half-resolution proxy, box-averaging each 2×2 block of raw BMT before the
/// same per-pixel develop — a cheap, alias-free reduction for thumbnails.
/// `channels` 3 packs RGB (TIFF container); 4 pads alpha = 1.0
fn develop_linear_srgb(
    raw: &Raw,
    cal: &Calibration,
    sgain: Option<&SpatialGain>,
    area: Option<[u32; 4]>,
    orientation: u16,
    step: usize,
    channels: usize,
) -> Developed {
    // BMT→XYZ is the inverse of ColorMatrix1; diag(gain) folds in white balance.
    // The neutral diagonal baked into bmt_to_xyz cancels gain for grey, so this is
    // the same radiometric result the reference produces on its sRGB path. The
    // matrix is built in f64 for precision, then narrowed for the per-pixel loop.
    let bmt = inv3x3(&cal.color_matrix1);
    let m = mul3x3(&XYZ_TO_SRGB, &mul3x3(&bmt, &diag(&cal.gain)));
    let m32: [f32; 9] = std::array::from_fn(|i| m[i] as f32);

    // Monochrome weights: the top (T) row of the inverted develop matrix, so that
    // `mono · developed_sRGB` recovers the top Foveon layer — blue, the most
    // dynamic and least-noisy plane — on its own. Normalised to sum 1 so neutral
    // greys pass through unchanged, a drop-in for Rec.709 luma.
    let mi = inv3x3(&m);
    let wsum = mi[6] + mi[7] + mi[8];
    let mono = if wsum.is_finite() && wsum.abs() > 1e-6 {
        [
            (mi[6] / wsum) as f32,
            (mi[7] / wsum) as f32,
            (mi[8] / wsum) as f32,
        ]
    } else {
        REC709_LUMA
    };

    let (top, left, bottom, right) = match area {
        Some(a) => (a[0] as usize, a[1] as usize, a[2] as usize, a[3] as usize),
        None => (0, 0, raw.rows, raw.columns),
    };
    // Clamp the crop to the decoded raster, keeping a non-empty region.
    let left = left.min(raw.columns.saturating_sub(1));
    let top = top.min(raw.rows.saturating_sub(1));
    let w = right.min(raw.columns).saturating_sub(left).max(1);
    let h = bottom.min(raw.rows).saturating_sub(top).max(1);

    let black32: [f32; 3] = std::array::from_fn(|c| cal.black[c] as f32);
    let scale32: [f32; 3] =
        std::array::from_fn(|c| (1.0 / (cal.max[c] - cal.black[c]).max(1.0)) as f32);

    // Output dimensions (== crop for step 1).
    let ow = w.div_ceil(step);
    let oh = h.div_ceil(step);
    let interp = sgain.map(|sg| GainInterp::new(sg, ow, oh));
    let cols = raw.columns;
    let ch = channels;
    // Byte buffer so the FFI can hand the allocation over as-is; the workers
    // write through a u16 view (samples are packed little-endian below).
    let mut data = vec![0u8; ow * oh * ch * 2];
    assert!((data.as_ptr() as usize).is_multiple_of(align_of::<u16>()));

    let develop_row = |py: usize, out: &mut [u16]| {
        let y = top + py;
        // The active-area columns are contiguous in the decoded raster, so a single
        // slice covers the row; iterating it elides per-access bounds checks.
        let src = &raw.data[3 * (y * cols + left)..][..w * 3];
        let row = interp.as_ref().map(|gi| gi.row(py));
        // Interpolated spatial gain for one pixel (shared by both code paths).
        let gain = |px: usize| -> Option<[f32; 3]> {
            match (&interp, row) {
                (Some(gi), Some((rb0, rb1, rf))) => Some([
                    gi.sample(px, 0, rb0, rb1, rf),
                    gi.sample(px, 1, rb0, rb1, rf),
                    gi.sample(px, 2, rb0, rb1, rf),
                ]),
                _ => None,
            }
        };

        // AArch64: develop four pixels per iteration with NEON
        #[cfg(target_arch = "aarch64")]
        {
            use core::arch::aarch64::*;
            unsafe {
                let bl = [
                    vdupq_n_f32(black32[0]),
                    vdupq_n_f32(black32[1]),
                    vdupq_n_f32(black32[2]),
                ];
                let sc = [
                    vdupq_n_f32(scale32[0]),
                    vdupq_n_f32(scale32[1]),
                    vdupq_n_f32(scale32[2]),
                ];
                let mm: [float32x4_t; 9] = std::array::from_fn(|i| vdupq_n_f32(m32[i]));
                let zero = vdupq_n_f32(0.0);
                let one = vdupq_n_f32(1.0);
                let knee = vdupq_n_f32(CLIP_KNEE);
                let inv_span = vdupq_n_f32(CLIP_SPAN_INV);
                let alpha = vdup_n_u16(HALF_ONE);
                let quads = w / 4;
                for q in 0..quads {
                    let px = q * 4;
                    // Deinterleave four BMT pixels and widen u16 → f32.
                    let u = vld3_u16(src.as_ptr().add(px * 3));
                    let nb = vmulq_f32(vsubq_f32(vcvtq_f32_u32(vmovl_u16(u.0)), bl[0]), sc[0]);
                    let nm = vmulq_f32(vsubq_f32(vcvtq_f32_u32(vmovl_u16(u.1)), bl[1]), sc[1]);
                    let nt = vmulq_f32(vsubq_f32(vcvtq_f32_u32(vmovl_u16(u.2)), bl[2]), sc[2]);
                    let sat = vmaxq_f32(vmaxq_f32(nb, nm), nt);
                    let (vb, vm, vt) = if let (Some(gi), Some((rb0, rb1, rf))) = (&interp, row) {
                        let (mut gb, mut gm, mut gt) = ([0f32; 4], [0f32; 4], [0f32; 4]);
                        for l in 0..4 {
                            gb[l] = gi.sample(px + l, 0, rb0, rb1, rf);
                            gm[l] = gi.sample(px + l, 1, rb0, rb1, rf);
                            gt[l] = gi.sample(px + l, 2, rb0, rb1, rf);
                        }
                        (
                            vmaxq_f32(vmulq_f32(nb, vld1q_f32(gb.as_ptr())), zero),
                            vmaxq_f32(vmulq_f32(nm, vld1q_f32(gm.as_ptr())), zero),
                            vmaxq_f32(vmulq_f32(nt, vld1q_f32(gt.as_ptr())), zero),
                        )
                    } else {
                        (
                            vmaxq_f32(nb, zero),
                            vmaxq_f32(nm, zero),
                            vmaxq_f32(nt, zero),
                        )
                    };
                    // Colour matrix via FMA, same accumulation order as the scalar
                    // path (m0·v0 first, then fused +m1·v1, +m2·v2) so the two stay
                    // bit-matched: fewer ops and one less rounding step per channel.
                    let mut rr = vfmaq_f32(vfmaq_f32(vmulq_f32(mm[0], vb), mm[1], vm), mm[2], vt);
                    let mut rg = vfmaq_f32(vfmaq_f32(vmulq_f32(mm[3], vb), mm[4], vm), mm[5], vt);
                    let mut rb = vfmaq_f32(vfmaq_f32(vmulq_f32(mm[6], vb), mm[7], vm), mm[8], vt);
                    // Highlight reconstruction toward the neutral max
                    let t = vmaxq_f32(vminq_f32(vmulq_f32(vsubq_f32(sat, knee), inv_span), one), zero);
                    let mx = vmaxq_f32(vmaxq_f32(rr, rg), rb);
                    rr = vaddq_f32(rr, vmulq_f32(t, vsubq_f32(mx, rr)));
                    rg = vaddq_f32(rg, vmulq_f32(t, vsubq_f32(mx, rg)));
                    rb = vaddq_f32(rb, vmulq_f32(t, vsubq_f32(mx, rb)));
                    // Narrow to half (FCVTN) and re-interleave. Negative sRGB
                    // components are kept: they carry the camera's wider-than-
                    // sRGB gamut into the extended-linear working space.
                    let hr = vreinterpret_u16_f16(vcvt_f16_f32(rr));
                    let hg = vreinterpret_u16_f16(vcvt_f16_f32(rg));
                    let hb = vreinterpret_u16_f16(vcvt_f16_f32(rb));
                    if ch == 4 {
                        vst4_u16(out.as_mut_ptr().add(px * 4), uint16x4x4_t(hr, hg, hb, alpha));
                    } else {
                        vst3_u16(out.as_mut_ptr().add(px * 3), uint16x4x3_t(hr, hg, hb));
                    }
                }
                // Finish the < 4 pixel remainder with the scalar kernel.
                for px in quads * 4..w {
                    let h = develop_pixel(&src[px * 3..], gain(px), &black32, &scale32, &m32);
                    out[px * ch..px * ch + 3].copy_from_slice(&h);
                    if ch == 4 {
                        out[px * ch + 3] = HALF_ONE;
                    }
                }
            }
        }
        #[cfg(not(target_arch = "aarch64"))]
        for (px, (s, o)) in src.chunks_exact(3).zip(out.chunks_exact_mut(ch)).enumerate() {
            let h = develop_pixel(s, gain(px), &black32, &scale32, &m32);
            // Samples are declared little-endian
            o[..3].copy_from_slice(&h.map(u16::to_le));
            if ch == 4 {
                o[3] = HALF_ONE.to_le();
            }
        }
    };

    // Proxy path: box-average each step×step block (corner taps, edge-clamped)
    // in the raw domain, then run the identical per-pixel develop. A quarter of
    // the pixels — scalar is already ~1ms, so no NEON variant is warranted.
    let develop_proxy_row = |py: usize, out: &mut [u16]| {
        let y0 = top + py * step;
        let y1 = (y0 + step - 1).min(top + h - 1);
        let row = interp.as_ref().map(|gi| gi.row(py));
        let gain = |px: usize| -> Option<[f32; 3]> {
            match (&interp, row) {
                (Some(gi), Some((rb0, rb1, rf))) => Some([
                    gi.sample(px, 0, rb0, rb1, rf),
                    gi.sample(px, 1, rb0, rb1, rf),
                    gi.sample(px, 2, rb0, rb1, rf),
                ]),
                _ => None,
            }
        };
        for (px, o) in out.chunks_exact_mut(ch).enumerate() {
            let x0 = left + px * step;
            let x1 = (x0 + step - 1).min(left + w - 1);
            let avg: [u16; 3] = std::array::from_fn(|c| {
                let s = raw.data[3 * (y0 * cols + x0) + c] as u32
                    + raw.data[3 * (y0 * cols + x1) + c] as u32
                    + raw.data[3 * (y1 * cols + x0) + c] as u32
                    + raw.data[3 * (y1 * cols + x1) + c] as u32;
                (s / 4) as u16
            });
            let h = develop_pixel(&avg, gain(px), &black32, &scale32, &m32);
            o[..3].copy_from_slice(&h.map(u16::to_le));
            if ch == 4 {
                o[3] = HALF_ONE.to_le();
            }
        }
    };

    let stride = ow * ch;
    let base = SyncPtr(data.as_mut_ptr().cast::<u16>());
    // Output rows are independent; the shared atomic cursor lets P-cores out-pace
    // E-cores instead of every core waiting on a fixed equal band.
    parallel_rows(oh, ROW_CHUNK, |py| {
        // SAFETY: each output row [py*stride, +stride) is claimed by exactly one
        // worker, so the disjoint writes never alias.
        let row = unsafe { std::slice::from_raw_parts_mut(base.add(py * stride), stride) };
        if step == 1 {
            develop_row(py, row);
        } else {
            develop_proxy_row(py, row);
        }
    });

    Developed {
        width: ow,
        height: oh,
        orientation,
        data,
        channels: ch,
        mono,
    }
}

// Minimal TIFF/DNG writer

// TIFF field types.
const T_BYTE: u16 = 1;
const T_ASCII: u16 = 2;
const T_SHORT: u16 = 3;
const T_LONG: u16 = 4;
const T_RATIONAL: u16 = 5;
const T_UNDEFINED: u16 = 7;
const T_SRATIONAL: u16 = 10;

const LIGHTROOM_CRS: &[(&str, &str)] = &[
    ("Version", "18.3"),
    ("ProcessVersion", "15.4"),
    ("HasSettings", "True"),
    ("WhiteBalance", "Auto"),
    ("Sharpness", "49"),
    ("ShadowTint", "+26"),
    ("HDREditMode", "1"),
    ("HDRMaxValue", "2.3"),
    ("AutoLateralCA", "1"),
];

/// Lens-profile CRS keys for the Sigma 30mm F1.4 DC HSM A013
const LIGHTROOM_CRS_A013: &[(&str, &str)] = &[
    ("LensProfileEnable", "1"),
    ("LensProfileSetup", "LensDefaults"),
    (
        "LensProfileName",
        "Adobe (SIGMA 30mm F1.4 DC HSM A013, NIKON CORPORATION)",
    ),
    (
        "LensProfileFilename",
        "NIKON CORPORATION (SIGMA 30mm F1.4 DC HSM A013) - RAW.lcp",
    ),
    ("LensProfileDistortionScale", "100"),
    ("LensProfileChromaticAberrationScale", "100"),
    ("LensProfileVignettingScale", "100"),
];

/// approximate the sigma lense I usually use, bc its too new
fn is_a013(c: &Capture) -> bool {
    let (Some(lo), Some(hi), Some(ap)) = (c.focal_min, c.focal_max, c.aperture_max) else {
        return false;
    };
    if matches!(c.lens_model, Some(id) if id != 255) {
        return false;
    }
    (hi - lo).abs() < 0.5 && (lo - 30.0).abs() <= 1.0 && (1.2..=1.6).contains(&ap)
}

struct Field {
    tag: u16,
    typ: u16,
    count: u32,
    data: Vec<u8>, // full little-endian value bytes
}

fn shorts(vals: &[u16]) -> Vec<u8> {
    vals.iter().flat_map(|v| v.to_le_bytes()).collect()
}
fn longs(vals: &[u32]) -> Vec<u8> {
    vals.iter().flat_map(|v| v.to_le_bytes()).collect()
}
fn rational(v: f64) -> Vec<u8> {
    let den = 1_000_000u32;
    let num = (v.max(0.0) * den as f64).round() as u32;
    [num.to_le_bytes(), den.to_le_bytes()].concat()
}
fn srational(v: f64) -> Vec<u8> {
    let den = 1_000_000i32;
    let num = (v * den as f64).round() as i32;
    [num.to_le_bytes(), den.to_le_bytes()].concat()
}
fn rationals(vals: &[f64]) -> Vec<u8> {
    vals.iter().flat_map(|&v| rational(v)).collect()
}
fn srationals(vals: &[f64]) -> Vec<u8> {
    vals.iter().flat_map(|&v| srational(v)).collect()
}

fn be32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}
fn bef32(out: &mut Vec<u8>, v: f32) {
    out.extend_from_slice(&v.to_bits().to_be_bytes());
}
fn bef64(out: &mut Vec<u8>, v: f64) {
    out.extend_from_slice(&v.to_bits().to_be_bytes());
}

fn opcode_list2_gain_map(raw: &Raw, area: [u32; 4], gain: &SpatialGain) -> Option<Vec<u8>> {
    let height = area[2].checked_sub(area[0])?;
    let width = area[3].checked_sub(area[1])?;
    if height == 0 || width == 0 || gain.rows < 2 || gain.cols < 2 || gain.channels == 0 {
        return None;
    }
    let map_bytes = u32::try_from(gain.gain.len().checked_mul(4)?).ok()?;
    let parsize = 76u32.checked_add(map_bytes)?;
    let mut out = Vec::with_capacity(4 + 16 + parsize as usize);

    be32(&mut out, 1); // opcode count
    be32(&mut out, 9); // GainMap
    be32(&mut out, 0x0103_0000);
    be32(&mut out, 0);
    be32(&mut out, parsize);
    be32(&mut out, 0); // Top
    be32(&mut out, 0); // Left
    be32(&mut out, height);
    be32(&mut out, width);
    be32(&mut out, 0); // Plane
    be32(&mut out, gain.channels);
    be32(&mut out, 1); // RowPitch
    be32(&mut out, 1); // ColPitch
    be32(&mut out, gain.rows);
    be32(&mut out, gain.cols);
    bef64(
        &mut out,
        raw.rows as f64 / height as f64 / (gain.rows - 1) as f64,
    );
    bef64(
        &mut out,
        raw.columns as f64 / width as f64 / (gain.cols - 1) as f64,
    );
    bef64(&mut out, -(area[0] as f64) / height as f64);
    bef64(&mut out, -(area[1] as f64) / width as f64);
    be32(&mut out, gain.channels);
    for &v in &gain.gain {
        bef32(&mut out, v);
    }
    Some(out)
}

fn xmp_packet(capture: &Capture) -> Vec<u8> {
    let mut xmp = String::with_capacity(1024);
    xmp.push_str("<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    xmp.push_str("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"sd14-pipeline\">\n");
    xmp.push_str(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
    xmp.push_str("  <rdf:Description rdf:about=\"\"\n");
    xmp.push_str("    xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"\n");
    let lens_profile = if is_a013(capture) {
        LIGHTROOM_CRS_A013
    } else {
        &[]
    };
    for (key, value) in LIGHTROOM_CRS.iter().chain(lens_profile) {
        xmp.push_str("    crs:");
        xmp.push_str(key);
        xmp.push_str("=\"");
        xmp.push_str(value);
        xmp.push_str("\"\n");
    }
    xmp.push_str(">\n");
    xmp.push_str("  </rdf:Description>\n");
    xmp.push_str(" </rdf:RDF>\n");
    xmp.push_str("</x:xmpmeta>\n");
    xmp.push_str("<?xpacket end=\"w\"?>");
    xmp.into_bytes()
}

impl Field {
    fn new(tag: u16, typ: u16, count: u32, data: Vec<u8>) -> Field {
        Field {
            tag,
            typ,
            count,
            data,
        }
    }
    fn short(tag: u16, v: u16) -> Field {
        Field::new(tag, T_SHORT, 1, shorts(&[v]))
    }
    fn long(tag: u16, v: u32) -> Field {
        Field::new(tag, T_LONG, 1, longs(&[v]))
    }
    fn ascii(tag: u16, s: &str) -> Field {
        let mut b = s.as_bytes().to_vec();
        b.push(0);
        let n = b.len() as u32;
        Field::new(tag, T_ASCII, n, b)
    }
}

/// Serialise one IFD
fn serialize_ifd(fields: &mut [Field], heap_off: u32, heap: &mut Vec<u8>, next: u32) -> Vec<u8> {
    fields.sort_by_key(|f| f.tag);
    let n = fields.len() as u32;
    let mut out = Vec::with_capacity(2 + 12 * fields.len() + 4);
    out.extend_from_slice(&(n as u16).to_le_bytes());
    for f in fields.iter() {
        out.extend_from_slice(&f.tag.to_le_bytes());
        out.extend_from_slice(&f.typ.to_le_bytes());
        out.extend_from_slice(&f.count.to_le_bytes());
        if f.data.len() <= 4 {
            let mut v = [0u8; 4];
            v[..f.data.len()].copy_from_slice(&f.data);
            out.extend_from_slice(&v);
        } else {
            let at = heap_off + heap.len() as u32;
            out.extend_from_slice(&at.to_le_bytes());
            heap.extend_from_slice(&f.data);
            if heap.len() % 2 == 1 {
                heap.push(0); // word alignment
            }
        }
    }
    out.extend_from_slice(&next.to_le_bytes());
    out
}

/// Assemble the full DNG byte stream
#[allow(clippy::too_many_arguments)]
fn write_dng(
    raw: &Raw,
    norm: &[u16],
    preview: &Preview,
    cal: &Calibration,
    area: Option<[u32; 4]>,
    opcode_list2: Option<Vec<u8>>,
    orientation: u16,
    model: &str,
    capture: &Capture,
) -> Vec<u8> {
    // --- IFD0: the full-resolution linear Foveon planes + DNG camera profile. ---
    // Apple's Core Image RAW engine treats IFD0 as the primary raw image and only
    // follows SubIFDs for previews, so the raster must live here (not in a SubIFD).
    let raw_bytes_len = (raw.data.len() * 2) as u32;
    let xmp = xmp_packet(capture);
    let mut ifd0: Vec<Field> = vec![
        Field::long(254, 0), // NewSubFileType = full-resolution main image (LONG per TIFF/DNG spec)
        Field::long(256, raw.columns as u32),
        Field::long(257, raw.rows as u32),
        Field::new(258, T_SHORT, 3, shorts(&[16, 16, 16])),
        Field::short(259, 1),     // Compression: none
        Field::short(262, 34892), // PhotometricInterpretation: LinearRaw
        Field::long(273, 0),      // StripOffsets (patched)
        Field::short(274, orientation),
        Field::short(277, 3),                            // SamplesPerPixel
        Field::long(278, raw.rows as u32),               // RowsPerStrip (single strip)
        Field::long(279, raw_bytes_len),                 // StripByteCounts
        Field::short(284, 1),                            // PlanarConfiguration: chunky
        Field::short(339, 1),                            // SampleFormat: unsigned integer
        Field::new(700, T_BYTE, xmp.len() as u32, xmp),  // XMP Lightroom/Camera Raw settings
        Field::long(330, 0),                             // SubIFDs -> preview (patched)
        Field::new(50706, T_BYTE, 4, vec![1, 4, 0, 0]),  // DNGVersion 1.4
        Field::new(50707, T_BYTE, 4, vec![1, 3, 0, 0]),  // DNGBackwardVersion 1.3
        Field::ascii(50708, model),                      // UniqueCameraModel
        Field::new(50714, T_LONG, 3, longs(&[0, 0, 0])), // BlackLevel (already subtracted)
        Field::new(50717, T_LONG, 3, longs(&[65535, 65535, 65535])), // WhiteLevel (normalised)
        Field::new(50721, T_SRATIONAL, 9, srationals(&cal.color_matrix1)), // ColorMatrix1
        Field::new(50964, T_SRATIONAL, 9, srationals(&cal.forward_matrix1)), // ForwardMatrix1
        Field::new(50723, T_SRATIONAL, 9, srationals(&cal.camera_calibration1)), // CameraCalibration1
        Field::new(50728, T_RATIONAL, 3, rationals(&cal.as_shot_neutral)),       // AsShotNeutral
        Field::new(50730, T_SRATIONAL, 1, srational(cal.baseline_exposure)),     // BaselineExposure
        Field::short(50778, 21), // CalibrationIlluminant1 = D65
    ];
    if let Some(a) = area {
        ifd0.push(Field::new(50829, T_LONG, 4, longs(&a))); // ActiveArea
    }
    if let Some(opcodes) = opcode_list2 {
        ifd0.push(Field::new(
            51009,
            T_UNDEFINED,
            opcodes.len() as u32,
            opcodes,
        )); // OpcodeList2: spatial GainMap
    }

    // --- Preview SubIFD: a reduced sRGB thumbnail (browsers only; RAW 9 ignores). ---
    let mut sub: Vec<Field> = vec![
        Field::long(254, 1), // NewSubFileType = reduced-resolution preview (LONG per TIFF/DNG spec)
        Field::long(256, preview.columns as u32),
        Field::long(257, preview.rows as u32),
        Field::new(258, T_SHORT, 3, shorts(&[8, 8, 8])),
        Field::short(259, 1),                        // Compression: none
        Field::short(262, 2),                        // PhotometricInterpretation: RGB
        Field::long(273, 0),                         // StripOffsets (patched)
        Field::short(277, 3),                        // SamplesPerPixel
        Field::long(278, preview.rows as u32),       // RowsPerStrip (single strip)
        Field::long(279, preview.data.len() as u32), // StripByteCounts
        Field::short(284, 1),                        // PlanarConfiguration: chunky
    ];

    // --- Plan offsets. ---
    let ifd0_off = 8u32;
    let n0 = ifd0.len();
    let n1 = sub.len();
    let ifd0_size = 2 + 12 * n0 as u32 + 4;
    let sub_off = ifd0_off + ifd0_size;
    let sub_size = 2 + 12 * n1 as u32 + 4;
    let heap_off = sub_off + sub_size;

    let mut heap = Vec::new();
    let ifd0_bytes_pre = serialize_ifd(&mut ifd0, heap_off, &mut heap, 0);
    let sub_bytes_pre = serialize_ifd(&mut sub, heap_off, &mut heap, 0);

    let mut preview_off = heap_off + heap.len() as u32;
    if preview_off % 2 == 1 {
        preview_off += 1;
    }
    let mut raw_off = preview_off + preview.data.len() as u32;
    if raw_off % 2 == 1 {
        raw_off += 1;
    }

    // Re-serialise with strip/SubIFD offsets now known (lengths are unchanged).
    patch_long(&mut ifd0, 273, raw_off); // IFD0 strip = raw raster
    patch_long(&mut ifd0, 330, sub_off); // IFD0 SubIFD = preview
    patch_long(&mut sub, 273, preview_off); // SubIFD strip = preview
    heap.clear();
    let ifd0_bytes = serialize_ifd(&mut ifd0, heap_off, &mut heap, 0);
    let sub_bytes = serialize_ifd(&mut sub, heap_off, &mut heap, 0);
    debug_assert_eq!(ifd0_bytes.len(), ifd0_bytes_pre.len());
    debug_assert_eq!(sub_bytes.len(), sub_bytes_pre.len());

    // --- Emit the file. ---
    let mut f = Vec::with_capacity(raw_off as usize + raw_bytes_len as usize);
    f.extend_from_slice(b"II");
    f.extend_from_slice(&42u16.to_le_bytes());
    f.extend_from_slice(&ifd0_off.to_le_bytes());
    f.extend_from_slice(&ifd0_bytes);
    f.extend_from_slice(&sub_bytes);
    f.extend_from_slice(&heap);
    f.resize(preview_off as usize, 0);
    f.extend_from_slice(&preview.data);
    f.resize(raw_off as usize, 0);
    if cfg!(target_endian = "little") {
        // SAFETY: `u16` has no padding or invalid bit patterns, so the slice
        // reinterprets cleanly as its native little-endian bytes.
        let (_, bytes, _) = unsafe { norm.align_to::<u8>() };
        f.extend_from_slice(bytes);
    } else {
        for &v in norm {
            f.extend_from_slice(&v.to_le_bytes());
        }
    }
    f
}

fn patch_long(fields: &mut [Field], tag: u16, value: u32) {
    if let Some(f) = fields.iter_mut().find(|f| f.tag == tag) {
        f.data = longs(&[value]);
    }
}

/// f32 → IEEE binary16 bits, sign-preserving, round-to-nearest-even.
#[cfg(not(target_arch = "aarch64"))]
#[inline]
fn f16_bits(x: f32) -> u16 {
    let bits = x.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = (bits >> 23) & 0xff;
    let mant = bits & 0x007f_ffff;
    let e = exp as i32 - 127;
    if e >= 16 {
        return sign | 0x7bff; // overflow / inf -> max finite half
    }
    if e < -14 {
        // Half subnormal or underflow to zero (scene black; rounding irrelevant).
        if e < -25 {
            return sign;
        }
        let m = mant | 0x0080_0000;
        return sign | (m >> ((-e - 14) + 13)) as u16;
    }
    // Normal half: round the dropped 13 mantissa bits to nearest, ties to even.
    let half = sign | (((e + 15) as u16) << 10) | (mant >> 13) as u16;
    let dropped = mant & 0x1fff;
    let round_up = dropped > 0x1000 || (dropped == 0x1000 && half & 1 == 1);
    half + round_up as u16
}

/// Pack a scene-linear RGB triple into three IEEE binary16 samples. Negative
/// components are preserved — they encode wider-than-sRGB chroma for the
/// extended-linear working space. On AArch64 a single `FCVTN` converts four
/// lanes at once; elsewhere we fall back to the scalar path.
#[cfg(target_arch = "aarch64")]
#[inline]
fn pack_rgb_f16(rgb: [f32; 3]) -> [u16; 3] {
    use core::arch::aarch64::*;
    unsafe {
        let src = [rgb[0], rgb[1], rgb[2], 0.0];
        let h = vcvt_f16_f32(vld1q_f32(src.as_ptr()));
        let mut out = [0u16; 4];
        vst1_u16(out.as_mut_ptr(), vreinterpret_u16_f16(h));
        [out[0], out[1], out[2]]
    }
}

#[cfg(not(target_arch = "aarch64"))]
#[inline]
fn pack_rgb_f16(rgb: [f32; 3]) -> [u16; 3] {
    [f16_bits(rgb[0]), f16_bits(rgb[1]), f16_bits(rgb[2])]
}

fn write_tiff_linear_f16<W: Write>(dev: &Developed, w: &mut W) -> std::io::Result<()> {
    debug_assert_eq!(dev.channels, 3, "TIFF output is 3-sample RGB");
    let bytes = dev.data.len() as u32;
    let mut ifd: Vec<Field> = vec![
        Field::long(256, dev.width as u32),
        Field::long(257, dev.height as u32),
        Field::new(258, T_SHORT, 3, shorts(&[16, 16, 16])),
        Field::short(259, 1),                // Compression: none
        Field::short(262, 2),                // PhotometricInterpretation: RGB
        Field::long(273, 0),                 // StripOffsets (patched)
        Field::short(274, dev.orientation),  // Orientation
        Field::short(277, 3),                // SamplesPerPixel
        Field::long(278, dev.height as u32), // RowsPerStrip (single strip)
        Field::long(279, bytes),             // StripByteCounts
        Field::short(284, 1),                // PlanarConfiguration: chunky
        Field::short(339, 3),                // SampleFormat: IEEE float
    ];

    let ifd0_off = 8u32;
    let ifd_size = 2 + 12 * ifd.len() as u32 + 4;
    let heap_off = ifd0_off + ifd_size;

    let mut heap = Vec::new();
    serialize_ifd(&mut ifd, heap_off, &mut heap, 0);
    let mut data_off = heap_off + heap.len() as u32;
    if data_off % 2 == 1 {
        data_off += 1;
    }
    patch_long(&mut ifd, 273, data_off);
    heap.clear();
    let ifd_bytes = serialize_ifd(&mut ifd, heap_off, &mut heap, 0);

    // Assemble the few-hundred-byte header, then stream the f16 raster straight
    // from `dev.data` — the whole image is never copied into a scratch buffer.
    // The sink is generic: the CLI streams to a `BufWriter<File>` while the
    // library/FFI streams to an in-memory `Vec`, both with identical bytes.
    let mut header = vec![0u8; data_off as usize];
    header[0..2].copy_from_slice(b"II");
    header[2..4].copy_from_slice(&42u16.to_le_bytes());
    header[4..8].copy_from_slice(&ifd0_off.to_le_bytes());
    header[8..8 + ifd_bytes.len()].copy_from_slice(&ifd_bytes);
    header[heap_off as usize..heap_off as usize + heap.len()].copy_from_slice(&heap);
    w.write_all(&header)?;
    // The raster is already little-endian
    w.write_all(&dev.data)
}

// Public library API (used by the C FFI in `ffi.rs` and the CLI below)

/// Decoded raw plus everything needed to emit any output format. Built once by
/// [`prepare`] and reused by the DNG and developed-TIFF paths, so the expensive
/// Huffman decode and colour calibration happen a single time per file.
struct Prepared {
    raw: Raw,
    cal: Calibration,
    area: Option<[u32; 4]>,
    sgain: Option<SpatialGain>,
    orientation: u16,
    wb: String,
    capture: Capture,
}

/// UniqueCameraModel fallback when the file's PROP list carries no CAMMODEL.
const MODEL: &str = "SIGMA SD14";

/// Parse, Huffman-decode and colour-calibrate an in-memory `.x3f`. This is the
/// heavy, CPU-parallel work shared by every output format.
fn prepare(x3f: &[u8], override_wb: Option<&str>) -> R<Prepared> {
    let container = parse_container(x3f)?;
    let raw_sect = container
        .sections
        .iter()
        .find(|s| {
            s.identifier == X3F_SECI
                && matches!(s.type_format, RAW_HUFFMAN_10BIT | RAW_HUFFMAN_X530)
        })
        .ok_or("no SD14-compatible Huffman raw image found (is this a Merrill/Quattro file?)")?;
    let camf_sect = container
        .sections
        .iter()
        .find(|s| s.identifier == X3F_SECC)
        .ok_or("no CAMF metadata section found")?;

    let raw = decode_raw(raw_sect)?;
    let camf = Camf::parse(camf_sect)?;
    let wb = resolve_wb(&camf, &container.header, override_wb);
    let cal = build_calibration(&camf, &raw, &wb)?;
    let area = active_area(&camf, &raw);
    let sgain = classic_spatial_gain(&camf, &wb);
    let orientation = match container.header.rotation {
        90 => 6,
        180 => 3,
        270 => 8,
        _ => 1,
    };
    Ok(Prepared {
        raw,
        cal,
        area,
        sgain,
        orientation,
        wb,
        capture: container.capture,
    })
}

/// Serialise the linear-Foveon DNG (Lightroom / Camera Raw workflow) in memory.
fn dng_bytes(p: &Prepared) -> Vec<u8> {
    let norm = normalise(&p.raw, &p.cal);
    let preview = build_preview(&norm, &p.raw, &p.cal, p.area, 1024);
    let opcodes = p.area.and_then(|a| {
        p.sgain
            .as_ref()
            .and_then(|g| opcode_list2_gain_map(&p.raw, a, g))
    });
    let model = p.capture.camera_model.as_deref().unwrap_or(MODEL);
    write_dng(
        &p.raw,
        &norm,
        &preview,
        &p.cal,
        p.area,
        opcodes,
        p.orientation,
        model,
        &p.capture,
    )
}

/// Output container chosen by [`render_x3f`].
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RenderMode {
    /// Linear-Foveon DNG for an Apple RAW / Lightroom workflow.
    Dng,
    /// Fully developed scene-linear sRGB, half-float RGB TIFF for Core Image.
    TiffLinearF16,
    /// Half-resolution proxy of the developed TIFF (2×2 raw box average) —
    /// thumbnails and scene analysis at a quarter of the develop cost.
    TiffProxyHalf,
    /// Bare interleaved RGBA16F scene-linear pixels (alpha = 1, no container)
    /// a Core Image bitmap with zero encode/parse overhead. Dimensions travel
    /// in [`RenderInfo`]; orientation is the caller's to apply.
    RgbaLinearF16,
    /// Half-resolution proxy of the RGBA16F bitmap (2×2 raw box average)
    RgbaProxyHalf,
}

/// Dimensions and metadata of a rendered image (handed back across the FFI).
pub struct RenderInfo {
    pub width: u32,
    pub height: u32,
    pub orientation: u16,
    pub white_balance: String,
    pub spatial_gain: bool,
    /// Weights recovering the top Foveon layer (blue) from developed sRGB, for
    /// top-layer-only monochrome. Rec.709 luma on the (undeveloped) DNG path.
    pub mono_weights: [f32; 3],
    /// As-shot lens metadata
    pub focal_length: f32,
    pub aperture: f32,
    pub focal_min: f32,
    pub focal_max: f32,
    pub aperture_max: f32,
    /// Body lens code (LENSMODEL; 0 = absent, 255 = unknown to the body).
    pub lens_model: u32,
    pub iso: f32,
    /// log2(CaptureISO/SensorISO)
    pub baseline_exposure: f32,
}

/// Emit one output format from a [`Prepared`] decode. Cheap relative to
/// [`prepare`]; call it once per requested format to reuse the Huffman decode.
fn emit(p: &Prepared, mode: RenderMode) -> R<(Vec<u8>, RenderInfo)> {
    let (bytes, width, height, mono_weights) = match mode {
        RenderMode::Dng => (
            dng_bytes(p),
            p.raw.columns as u32,
            p.raw.rows as u32,
            REC709_LUMA,
        ),
        RenderMode::TiffLinearF16
        | RenderMode::TiffProxyHalf
        | RenderMode::RgbaLinearF16
        | RenderMode::RgbaProxyHalf => {
            let proxy = matches!(mode, RenderMode::TiffProxyHalf | RenderMode::RgbaProxyHalf);
            let bitmap = matches!(mode, RenderMode::RgbaLinearF16 | RenderMode::RgbaProxyHalf);
            let dev = develop_linear_srgb(
                &p.raw,
                &p.cal,
                p.sgain.as_ref(),
                p.area,
                p.orientation,
                if proxy { 2 } else { 1 },
                if bitmap { 4 } else { 3 },
            );
            if bitmap {
                (dev.data, dev.width as u32, dev.height as u32, dev.mono)
            } else {
                let mut v = Vec::with_capacity(dev.data.len() + 256);
                write_tiff_linear_f16(&dev, &mut v).map_err(|e| e.to_string())?;
                (v, dev.width as u32, dev.height as u32, dev.mono)
            }
        }
    };
    Ok((
        bytes,
        RenderInfo {
            width,
            height,
            orientation: p.orientation,
            white_balance: p.wb.clone(),
            spatial_gain: p.sgain.is_some(),
            mono_weights,
            focal_length: p.capture.focal.unwrap_or(0.0),
            aperture: p.capture.aperture.unwrap_or(0.0),
            focal_min: p.capture.focal_min.unwrap_or(0.0),
            focal_max: p.capture.focal_max.unwrap_or(0.0),
            aperture_max: p.capture.aperture_max.unwrap_or(0.0),
            lens_model: p.capture.lens_model.unwrap_or(0),
            iso: p.cal.iso as f32,
            baseline_exposure: p.cal.baseline_exposure as f32,
        },
    ))
}

/// Render an in-memory `.x3f` to in-memory output bytes
pub fn render_x3f(
    x3f: &[u8],
    mode: RenderMode,
    override_wb: Option<&str>,
) -> R<(Vec<u8>, RenderInfo)> {
    let p = prepare(x3f, override_wb)?;
    emit(&p, mode)
}

// CLI

/// C ABI for the Swift / iOS wrapper (`foveon_render` / `foveon_bytes_free`).
pub mod ffi;

fn run(input: &Path, output: &Path, override_wb: Option<String>) -> R<()> {
    let timing = std::env::var_os("SD14_TIMING").is_some();
    let mut t = std::time::Instant::now();
    let mut lap = |label: &str| {
        if timing {
            eprintln!("  {label:8} {:.2?}", t.elapsed());
        }
        t = std::time::Instant::now();
    };
    let buf = std::fs::read(input).map_err(|e| format!("cannot read {}: {e}", input.display()))?;
    let p = prepare(&buf, override_wb.as_deref())?;
    lap("decode");

    // `.dng` keeps the linear-Foveon DNG; anything else emits the developed
    // scene-linear sRGB TIFF. The CLI streams the result straight to disk (the
    // library/FFI keeps it in memory) so nothing larger than the header is copied.
    let is_dng = output
        .extension()
        .map(|e| e.eq_ignore_ascii_case("dng"))
        .unwrap_or(false);
    let (w, h) = if is_dng {
        let dng = dng_bytes(&p);
        lap("encode");
        std::fs::write(output, &dng)
            .map_err(|e| format!("cannot write {}: {e}", output.display()))?;
        (p.raw.columns, p.raw.rows)
    } else {
        let dev =
            develop_linear_srgb(&p.raw, &p.cal, p.sgain.as_ref(), p.area, p.orientation, 1, 3);
        lap("develop");
        let file = std::fs::File::create(output)
            .map_err(|e| format!("cannot write {}: {e}", output.display()))?;
        let mut bw = std::io::BufWriter::with_capacity(1 << 16, file);
        write_tiff_linear_f16(&dev, &mut bw)
            .and_then(|()| bw.flush())
            .map_err(|e| format!("cannot write {}: {e}", output.display()))?;
        lap("encode");
        (dev.width, dev.height)
    };
    eprintln!(
        "{} -> {}  [{}x{} {}, wb={}, black={:.1},{:.1},{:.1} max={:.0},{:.0},{:.0}, sgain={}]",
        input.display(),
        output.display(),
        w,
        h,
        if is_dng { "BMT" } else { "linear sRGB f16" },
        p.wb,
        p.cal.black[0],
        p.cal.black[1],
        p.cal.black[2],
        p.cal.max[0],
        p.cal.max[1],
        p.cal.max[2],
        if p.sgain.is_some() { "yes" } else { "no" },
    );
    Ok(())
}

/// CLI entry point; `src/main.rs` just forwards here.
pub fn cli_main() {
    let mut args = std::env::args().skip(1);
    let mut input: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut wb: Option<String> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--wb" | "-w" => wb = args.next(),
            "-h" | "--help" => {
                eprintln!("usage: sd14raw <in.x3f> [out.dng] [--wb NAME]");
                return;
            }
            _ if input.is_none() => input = Some(PathBuf::from(a)),
            _ if output.is_none() => output = Some(PathBuf::from(a)),
            _ => {}
        }
    }
    let Some(input) = input else {
        eprintln!("usage: sd14raw <in.x3f> [out.dng] [--wb NAME]");
        std::process::exit(2);
    };
    let output = output.unwrap_or_else(|| input.with_extension("dng"));
    if let Err(e) = run(&input, &output, wb) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
