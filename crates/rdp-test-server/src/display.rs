use ironrdp_core::{Encode as _, WriteCursor, encode_vec};
use ironrdp_graphics::rdp6::{BitmapStreamEncoder, RgbAChannels};
use ironrdp_pdu::bitmap::{BitmapData, BitmapUpdateData, CompressedDataHeader, Compression};
use ironrdp_pdu::fast_path::{
    EncryptionFlags, FastPathHeader, FastPathUpdatePdu, Fragmentation, UpdateCode,
};
use ironrdp_pdu::geometry::InclusiveRectangle;
use ironrdp_pdu::mcs::SendDataIndication;
use ironrdp_pdu::pointer::{
    CachedPointerAttribute, ColorPointerAttribute, Point16, PointerAttribute,
    PointerPositionAttribute,
};
use ironrdp_pdu::x224::X224;
use std::borrow::Cow;

use crate::rle16_24::compress_interleaved;
use crate::{PixelEncoding, PointerTestUpdate};

#[derive(Debug, Clone)]
pub struct DisplaySceneState {
    pub width: u16,
    pub height: u16,
    pub pointer_x: u16,
    pub pointer_y: u16,
    pub left_pressed: bool,
    pub right_pressed: bool,
    pub last_key_code: u16,
    pub audio_beat_active: bool,
}

impl DisplaySceneState {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            pointer_x: width / 2,
            pointer_y: height / 2,
            left_pressed: false,
            right_pressed: false,
            last_key_code: 0,
            audio_beat_active: false,
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.pointer_x = self.pointer_x.min(width.saturating_sub(1));
        self.pointer_y = self.pointer_y.min(height.saturating_sub(1));
    }

    /// Renders deterministic RGBA8888 scene matching `PROJECT.md § Interface Contracts (c)`
    /// and `explorer_m2_2 §3.5`.
    pub fn render_rgba(&self) -> Vec<u8> {
        let w = usize::from(self.width);
        let h = usize::from(self.height);
        let mut rgba = vec![0u8; w * h * 4];

        let box_left = i32::from(self.pointer_x) - 16;
        let box_top = i32::from(self.pointer_y) - 16;
        let box_color: [u8; 3] = if self.left_pressed {
            [0xE5, 0x39, 0x35]
        } else if self.right_pressed {
            [0x8E, 0x24, 0xAA]
        } else {
            [0xFF, 0xB3, 0x00]
        };

        let key_palette: [[u8; 3]; 4] = [
            [0xEC, 0x40, 0x7A],
            [0x26, 0xA6, 0x9A],
            [0xAB, 0x47, 0xBC],
            [0xFF, 0x70, 0x43],
        ];
        let key_color = key_palette[usize::from(self.last_key_code % 4)];

        let header_color: [u8; 3] = if self.audio_beat_active {
            [0x2E, 0x7D, 0x32]
        } else {
            [0x1E, 0x88, 0xE5]
        };

        for y in 0..h {
            for x in 0..w {
                let rgb: [u8; 3] = if y < 16 && x < 64 {
                    // Deterministic Golden Anchor Strip (0..64, 0..16): 4x16px primary blocks
                    match x / 16 {
                        0 => [255, 0, 0],
                        1 => [0, 255, 0],
                        2 => [0, 0, 255],
                        _ => [255, 255, 255],
                    }
                } else if y < 48 {
                    if self.last_key_code != 0 && (64..128).contains(&x) && (8..40).contains(&y) {
                        key_color
                    } else {
                        header_color
                    }
                } else {
                    // Base 32x32 checkerboard
                    if ((x / 32) + (y / 32)) % 2 == 0 {
                        [0x20, 0x24, 0x2C]
                    } else {
                        [0x2E, 0x34, 0x40]
                    }
                };

                let ix = x as i32;
                let iy = y as i32;
                let final_rgb = if ix >= box_left && ix < box_left + 32 && iy >= box_top && iy < box_top + 32 {
                    box_color
                } else {
                    rgb
                };

                let idx = (y * w + x) * 4;
                rgba[idx] = final_rgb[0];
                rgba[idx + 1] = final_rgb[1];
                rgba[idx + 2] = final_rgb[2];
                rgba[idx + 3] = 0xFF;
            }
        }
        rgba
    }
}

#[inline]
pub fn rgb888_to_rgb565_le(r: u8, g: u8, b: u8) -> [u8; 2] {
    let val = ((u16::from(r) >> 3) << 11) | ((u16::from(g) >> 2) << 5) | (u16::from(b) >> 3);
    val.to_le_bytes()
}

fn encode_fastpath_frame(update_code: UpdateCode, data: &[u8]) -> anyhow::Result<Vec<u8>> {
    let update = FastPathUpdatePdu {
        fragmentation: Fragmentation::Single,
        update_code,
        compression_flags: None,
        compression_type: None,
        data,
    };
    let update_bytes = encode_vec(&update)?;
    let header = FastPathHeader::new(EncryptionFlags::empty(), update_bytes.len());
    let mut out = encode_vec(&header)?;
    out.extend_from_slice(&update_bytes);
    Ok(out)
}

fn build_tile_bitmap_bytes(
    rgba: &[u8],
    full_width: usize,
    x0: usize,
    y0: usize,
    tile_w: usize,
    tile_h: usize,
    encoding: PixelEncoding,
) -> anyhow::Result<(u16, Compression, Option<CompressedDataHeader>, Vec<u8>)> {
    let effective_enc = if matches!(encoding, PixelEncoding::Rdp6Rle32) && !tile_w.is_multiple_of(4) {
        PixelEncoding::Raw32
    } else {
        encoding
    };

    match effective_enc {
        PixelEncoding::Raw32 => {
            let mut buf = Vec::with_capacity(tile_w * tile_h * 4);
            for y in (y0..y0 + tile_h).rev() {
                for x in x0..x0 + tile_w {
                    let i = (y * full_width + x) * 4;
                    buf.extend_from_slice(&[rgba[i + 2], rgba[i + 1], rgba[i], 0xFF]);
                }
            }
            Ok((32, Compression::empty(), None, buf))
        }
        PixelEncoding::Rdp6Rle32 => {
            let mut encoder = BitmapStreamEncoder::new(tile_w, tile_h);
            let row_stride = full_width * 4;
            let row_bytes = tile_w * 4;
            let mut dst = vec![0u8; row_bytes * tile_h + 1024];
            let pixels = (y0..y0 + tile_h).rev().flat_map(|y| {
                let start = y * row_stride + x0 * 4;
                rgba[start..start + row_bytes]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| c.as_slice())
            });
            let written = encoder.encode_pixels_stream::<_, RgbAChannels>(pixels, &mut dst, true)?;
            dst.truncate(written);
            let hdr = CompressedDataHeader {
                main_body_size: u16::try_from(written)?,
                scan_width: u16::try_from(tile_w)?,
                uncompressed_size: u16::try_from(tile_h * row_bytes)?,
            };
            Ok((32, Compression::BITMAP_COMPRESSION, Some(hdr), dst))
        }
        PixelEncoding::Raw24 => {
            let row_bytes = tile_w * 3;
            let padded_row = (row_bytes + 3) & !3;
            let pad = padded_row - row_bytes;
            let mut buf = Vec::with_capacity(padded_row * tile_h);
            for y in (y0..y0 + tile_h).rev() {
                for x in x0..x0 + tile_w {
                    let i = (y * full_width + x) * 4;
                    buf.extend_from_slice(&[rgba[i + 2], rgba[i + 1], rgba[i]]);
                }
                buf.resize(buf.len() + pad, 0);
            }
            Ok((24, Compression::empty(), None, buf))
        }
        PixelEncoding::Rle24 => {
            let mut packed = Vec::with_capacity(tile_w * tile_h * 3);
            for y in (y0..y0 + tile_h).rev() {
                for x in x0..x0 + tile_w {
                    let i = (y * full_width + x) * 4;
                    packed.extend_from_slice(&[rgba[i + 2], rgba[i + 1], rgba[i]]);
                }
            }
            let rle = compress_interleaved(&packed, 3);
            Ok((
                24,
                Compression::BITMAP_COMPRESSION | Compression::NO_BITMAP_COMPRESSION_HDR,
                None,
                rle,
            ))
        }
        PixelEncoding::Raw16 => {
            let row_bytes = tile_w * 2;
            let padded_row = (row_bytes + 3) & !3;
            let pad = padded_row - row_bytes;
            let mut buf = Vec::with_capacity(padded_row * tile_h);
            for y in (y0..y0 + tile_h).rev() {
                for x in x0..x0 + tile_w {
                    let i = (y * full_width + x) * 4;
                    buf.extend_from_slice(&rgb888_to_rgb565_le(rgba[i], rgba[i + 1], rgba[i + 2]));
                }
                buf.resize(buf.len() + pad, 0);
            }
            Ok((16, Compression::empty(), None, buf))
        }
        PixelEncoding::Rle16 => {
            let mut packed = Vec::with_capacity(tile_w * tile_h * 2);
            for y in (y0..y0 + tile_h).rev() {
                for x in x0..x0 + tile_w {
                    let i = (y * full_width + x) * 4;
                    packed.extend_from_slice(&rgb888_to_rgb565_le(rgba[i], rgba[i + 1], rgba[i + 2]));
                }
            }
            let rle = compress_interleaved(&packed, 2);
            Ok((
                16,
                Compression::BITMAP_COMPRESSION | Compression::NO_BITMAP_COMPRESSION_HDR,
                None,
                rle,
            ))
        }
    }
}

/// Encodes the full framebuffer as 64x64 (or smaller edge) Fast-Path `BitmapData` tiles
/// followed by a `UpdateCode::Synchronize` frame-boundary marker.
pub fn encode_scene_fastpath_frames(
    scene: &DisplaySceneState,
    encoding: PixelEncoding,
) -> anyhow::Result<Vec<Vec<u8>>> {
    encode_scene_region_fastpath_frames(scene, encoding, 0, usize::from(scene.height))
}

/// Encodes `[y_start..y_end)` rows of the scene as Fast-Path `BitmapData` tiles + `Synchronize`.
pub fn encode_scene_region_fastpath_frames(
    scene: &DisplaySceneState,
    encoding: PixelEncoding,
    y_start: usize,
    y_end: usize,
) -> anyhow::Result<Vec<Vec<u8>>> {
    let rgba = scene.render_rgba();
    let full_w = usize::from(scene.width);
    let full_h = usize::from(scene.height);
    let y_lo = y_start.min(full_h);
    let y_hi = y_end.min(full_h);
    let tile_dim = 64usize;
    let mut frames = Vec::new();

    for y0 in (y_lo..y_hi).step_by(tile_dim) {
        let th = (y_hi - y0).min(tile_dim);
        for x0 in (0..full_w).step_by(tile_dim) {
            let tw = (full_w - x0).min(tile_dim);
            let (bpp, flags, hdr, bytes) =
                build_tile_bitmap_bytes(&rgba, full_w, x0, y0, tw, th, encoding)?;

            let rect = InclusiveRectangle {
                left: u16::try_from(x0)?,
                top: u16::try_from(y0)?,
                right: u16::try_from(x0 + tw - 1)?,
                bottom: u16::try_from(y0 + th - 1)?,
            };
            let bitmap = BitmapData {
                rectangle: rect,
                width: u16::try_from(tw)?,
                height: u16::try_from(th)?,
                bits_per_pixel: bpp,
                compression_flags: flags,
                compressed_data_header: hdr,
                bitmap_data: &bytes,
            };
            let upd = BitmapUpdateData {
                rectangles: vec![bitmap],
            };
            let payload = encode_vec(&upd)?;
            frames.push(encode_fastpath_frame(UpdateCode::Bitmap, &payload)?);
        }
    }

    // Frame boundary marker (`UpdateCode::Synchronize`)
    frames.push(encode_fastpath_frame(UpdateCode::Synchronize, &[0x00, 0x00])?);
    Ok(frames)
}

#[derive(Debug, Clone, Copy)]
pub struct SlowPathTile {
    pub x0: usize,
    pub y0: usize,
    pub width: usize,
    pub height: usize,
}

/// Encodes a rectangle using a Slow-Path `ShareDataPdu::Update` (`GraphicsUpdateType::Bitmap`).
pub fn encode_slowpath_bitmap_pdu(
    io_channel_id: u16,
    user_channel_id: u16,
    share_id: u32,
    scene: &DisplaySceneState,
    tile: SlowPathTile,
    encoding: PixelEncoding,
) -> anyhow::Result<Vec<u8>> {
    let rgba = scene.render_rgba();
    let full_w = usize::from(scene.width);
    let (bpp, flags, hdr, bytes) = build_tile_bitmap_bytes(
        &rgba,
        full_w,
        tile.x0,
        tile.y0,
        tile.width,
        tile.height,
        encoding,
    )?;
    let rect = InclusiveRectangle {
        left: u16::try_from(tile.x0)?,
        top: u16::try_from(tile.y0)?,
        right: u16::try_from(tile.x0 + tile.width - 1)?,
        bottom: u16::try_from(tile.y0 + tile.height - 1)?,
    };
    let bitmap = BitmapData {
        rectangle: rect,
        width: u16::try_from(tile.width)?,
        height: u16::try_from(tile.height)?,
        bits_per_pixel: bpp,
        compression_flags: flags,
        compressed_data_header: hdr,
        bitmap_data: &bytes,
    };
    let upd = BitmapUpdateData {
        rectangles: vec![bitmap],
    };
    // Slow-Path Graphics Update starts with `updateType: u16 = 0x0001 (Bitmap)` followed by `BitmapUpdateData`!
    // Wait: BitmapUpdateData::encode writes `flags: 0x0001` (BITMAP_UPDATE_TYPE) + `nrect` + rectangles!
    // And `slow_path::read_graphics_update_type` reads `updateType(u16)` FIRST, and THEN `decode_slow_path_bitmap`
    // reads `numberRectangles(u16)` + rectangles! So Slow-Path Bitmap has exact layout `[0x01, 0x00, nrect_lo, nrect_hi, BitmapData...]` —
    // which is IDENTICAL to `BitmapUpdateData::encode`!
    let mut upd_bytes = vec![0u8; upd.size()];
    let mut cursor = WriteCursor::new(&mut upd_bytes);
    upd.encode(&mut cursor)?;

    // Encode ShareControlHeader (10 bytes) + ShareDataHeader (8 bytes) + upd_bytes
    // because `ironrdp_pdu::ShareDataPdu::Update` returns "Encoding not implemented".
    let total_len = u16::try_from(10 + 8 + upd_bytes.len())?;
    let uncompressed_len = u16::try_from(upd_bytes.len())?;
    let mut user_data = Vec::with_capacity(usize::from(total_len));
    // ShareControlHeader: totalLength(2), pduType(2 = 0x0017 DataPdu|v1), pduSource(2), shareId(4)
    user_data.extend_from_slice(&total_len.to_le_bytes());
    user_data.extend_from_slice(&0x0017u16.to_le_bytes());
    user_data.extend_from_slice(&io_channel_id.to_le_bytes());
    user_data.extend_from_slice(&share_id.to_le_bytes());
    // ShareDataHeader: pad1(1), streamPriority(1 = Medium=2), uncompressedLength(2), pduType2(1 = Update=2), compressedType(1), compressedLength(2)
    user_data.push(0);
    user_data.push(2);
    user_data.extend_from_slice(&uncompressed_len.to_le_bytes());
    user_data.push(0x02);
    user_data.push(0);
    user_data.extend_from_slice(&0u16.to_le_bytes());
    user_data.extend_from_slice(&upd_bytes);

    let mcs = SendDataIndication {
        initiator_id: user_channel_id,
        channel_id: io_channel_id,
        user_data: Cow::Owned(user_data),
    };
    Ok(encode_vec(&X224(mcs))?)
}

pub fn encode_pointer_update_fastpath(kind: &PointerTestUpdate) -> anyhow::Result<Vec<u8>> {
    match kind {
        PointerTestUpdate::Rgba {
            cache_index,
            width,
            height,
            hot_x,
            hot_y,
            rgba,
        } => {
            let ptr = PointerAttribute {
                xor_bpp: 32,
                color_pointer: ColorPointerAttribute {
                    cache_index: *cache_index,
                    hot_spot: Point16 {
                        x: *hot_x,
                        y: *hot_y,
                    },
                    width: *width,
                    height: *height,
                    xor_mask: rgba,
                    and_mask: &[],
                },
            };
            encode_fastpath_frame(UpdateCode::NewPointer, &encode_vec(&ptr)?)
        }
        PointerTestUpdate::Color {
            cache_index,
            width,
            height,
            hot_x,
            hot_y,
            xor_mask,
            and_mask,
        } => {
            let ptr = ColorPointerAttribute {
                cache_index: *cache_index,
                hot_spot: Point16 {
                    x: *hot_x,
                    y: *hot_y,
                },
                width: *width,
                height: *height,
                xor_mask,
                and_mask,
            };
            encode_fastpath_frame(UpdateCode::ColorPointer, &encode_vec(&ptr)?)
        }
        PointerTestUpdate::Position { x, y } => {
            let pos = PointerPositionAttribute { x: *x, y: *y };
            encode_fastpath_frame(UpdateCode::PositionPointer, &encode_vec(&pos)?)
        }
        PointerTestUpdate::Cached(cache_index) => {
            let cached = CachedPointerAttribute {
                cache_index: *cache_index,
            };
            encode_fastpath_frame(UpdateCode::CachedPointer, &encode_vec(&cached)?)
        }
        PointerTestUpdate::Hidden => encode_fastpath_frame(UpdateCode::HiddenPointer, &[]),
        PointerTestUpdate::Default => encode_fastpath_frame(UpdateCode::DefaultPointer, &[]),
    }
}

pub fn make_checkerboard_rgba(width: u16, height: u16) -> Vec<u8> {
    let mut s = DisplaySceneState::new(width, height);
    s.pointer_x = 0;
    s.pointer_y = 0;
    s.render_rgba()
}
