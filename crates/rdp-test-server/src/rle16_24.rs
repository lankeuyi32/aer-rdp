//! Interleaved RLE encoder for 16bpp (RGB565 LE) and 24bpp (BGR24) bitmaps per MS-RDPBCGR
//! section 2.2.9.1.1.3.1.2.4, compatible with `ironrdp::graphics::rle::decompress`.

fn encode_color_run(out: &mut Vec<u8>, run_len: usize, pixel: &[u8]) {
    let mut rem = run_len;
    while rem > 0 {
        let chunk = rem.min(65_535);
        if chunk <= 31 {
            out.push((0x03 << 5) | (chunk as u8));
        } else if chunk <= 287 {
            out.push(0x03 << 5);
            out.push((chunk - 32) as u8);
        } else {
            out.push(0xF3);
            out.extend_from_slice(&(chunk as u16).to_le_bytes());
        }
        out.extend_from_slice(pixel);
        rem -= chunk;
    }
}

fn encode_color_image(out: &mut Vec<u8>, pixels: &[u8], bpp_bytes: usize) {
    let total_pixels = pixels.len() / bpp_bytes;
    let mut offset_px = 0;
    while offset_px < total_pixels {
        let chunk = (total_pixels - offset_px).min(65_535);
        if chunk <= 31 {
            out.push((0x04 << 5) | (chunk as u8));
        } else if chunk <= 287 {
            out.push(0x04 << 5);
            out.push((chunk - 32) as u8);
        } else {
            out.push(0xF4);
            out.extend_from_slice(&(chunk as u16).to_le_bytes());
        }
        let byte_start = offset_px * bpp_bytes;
        let byte_end = (offset_px + chunk) * bpp_bytes;
        out.extend_from_slice(&pixels[byte_start..byte_end]);
        offset_px += chunk;
    }
}

/// Compresses tightly packed bottom-up pixel bytes (`width * height * bpp_bytes`) into an
/// Interleaved RLE stream (`NO_BITMAP_COMPRESSION_HDR`).
pub fn compress_interleaved(bottom_up_pixels: &[u8], bpp_bytes: usize) -> Vec<u8> {
    assert!(bpp_bytes == 2 || bpp_bytes == 3);
    assert_eq!(bottom_up_pixels.len() % bpp_bytes, 0);

    let total_pixels = bottom_up_pixels.len() / bpp_bytes;
    let mut out = Vec::with_capacity(bottom_up_pixels.len());
    let mut i = 0;

    while i < total_pixels {
        let cur_px = &bottom_up_pixels[i * bpp_bytes..(i + 1) * bpp_bytes];
        let mut run = 1;
        while i + run < total_pixels {
            let next_px = &bottom_up_pixels[(i + run) * bpp_bytes..(i + run + 1) * bpp_bytes];
            if next_px == cur_px {
                run += 1;
            } else {
                break;
            }
        }

        if run >= 2 {
            encode_color_run(&mut out, run, cur_px);
            i += run;
        } else {
            let lit_start = i;
            i += 1;
            while i < total_pixels {
                let p = &bottom_up_pixels[i * bpp_bytes..(i + 1) * bpp_bytes];
                if i + 1 < total_pixels {
                    let q = &bottom_up_pixels[(i + 1) * bpp_bytes..(i + 2) * bpp_bytes];
                    if p == q {
                        break;
                    }
                }
                i += 1;
            }
            encode_color_image(&mut out, &bottom_up_pixels[lit_start * bpp_bytes..i * bpp_bytes], bpp_bytes);
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::graphics::rle::{RlePixelFormat, decompress};

    #[test]
    fn rle16_round_trips_through_ironrdp_decompress() {
        let width = 322usize;
        let height = 240usize;
        let mut raw = Vec::with_capacity(width * height * 2);
        for y in 0..height {
            for x in 0..width {
                let val: u16 = if (x / 16 + y / 16) % 2 == 0 {
                    0xF800
                } else {
                    ((x as u16) << 5) | (y as u16 & 0x1F)
                };
                raw.extend_from_slice(&val.to_le_bytes());
            }
        }
        let compressed = compress_interleaved(&raw, 2);
        let mut decoded = Vec::new();
        let fmt = decompress(&compressed, &mut decoded, width, height, 16).unwrap();
        assert_eq!(fmt, RlePixelFormat::Rgb16);
        assert_eq!(decoded, raw);
    }

    #[test]
    fn rle24_round_trips_through_ironrdp_decompress() {
        let width = 322usize;
        let height = 240usize;
        let mut raw = Vec::with_capacity(width * height * 3);
        for y in 0..height {
            for x in 0..width {
                if (x + y) % 5 == 0 {
                    raw.extend_from_slice(&[0x11, 0x22, 0x33]);
                } else {
                    raw.extend_from_slice(&[(x % 255) as u8, (y % 255) as u8, 0xAA]);
                }
            }
        }
        let compressed = compress_interleaved(&raw, 3);
        let mut decoded = Vec::new();
        let fmt = decompress(&compressed, &mut decoded, width, height, 24).unwrap();
        assert_eq!(fmt, RlePixelFormat::Rgb24);
        assert_eq!(decoded, raw);
    }
}
