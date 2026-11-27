use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::geometry::{InclusiveRectangle, Rectangle as _};
use ironrdp_session::image::DecodedImage;

use crate::cert_sha256_hex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirtyRect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

impl DirtyRect {
    pub fn union(self, other: Self) -> Self {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = self
            .x
            .saturating_add(self.w)
            .max(other.x.saturating_add(other.w));
        let y1 = self
            .y
            .saturating_add(self.h)
            .max(other.y.saturating_add(other.h));
        Self {
            x: x0,
            y: y0,
            w: x1.saturating_sub(x0),
            h: y1.saturating_sub(y0),
        }
    }
}

/// Clamps an inclusive RDP update rectangle to `[0..width, 0..height)`.
/// Returns `None` if the rectangle falls completely outside the framebuffer.
pub fn clamp_inclusive_rect(rect: &InclusiveRectangle, width: u16, height: u16) -> Option<DirtyRect> {
    if width == 0 || height == 0 || rect.left >= width || rect.top >= height {
        return None;
    }
    if rect.right < rect.left || rect.bottom < rect.top {
        return None;
    }
    let right = rect.right.min(width - 1);
    let bottom = rect.bottom.min(height - 1);
    let w = right - rect.left + 1;
    let h = bottom - rect.top + 1;
    if w == 0 || h == 0 {
        return None;
    }
    Some(DirtyRect {
        x: rect.left,
        y: rect.top,
        w,
        h,
    })
}

pub struct Framebuffer {
    image: DecodedImage,
    width: u16,
    height: u16,
}

impl Framebuffer {
    pub fn new(width: u16, height: u16) -> Self {
        let w = width.max(1);
        let h = height.max(1);
        Self {
            image: DecodedImage::new(PixelFormat::RgbA32, w, h),
            width: w,
            height: h,
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        let w = width.max(1);
        let h = height.max(1);
        if self.width != w || self.height != h {
            self.image = DecodedImage::new(PixelFormat::RgbA32, w, h);
            self.width = w;
            self.height = h;
        }
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn image_mut(&mut self) -> &mut DecodedImage {
        &mut self.image
    }

    /// Synchronizes cached `(width, height)` if `ActiveStage::process` resized `DecodedImage`
    /// in-place (for example via MS-RDPEGFX `RDPGFX_RESET_GRAPHICS_PDU`).
    pub fn sync_dimensions_from_image(&mut self) -> Option<(u16, u16)> {
        let img_w = self.image.width().max(1);
        let img_h = self.image.height().max(1);
        if self.width != img_w || self.height != img_h {
            self.width = img_w;
            self.height = img_h;
            Some((img_w, img_h))
        } else {
            None
        }
    }

    pub fn data(&self) -> &[u8] {
        self.image.data()
    }

    pub fn pixel_rgba(&self, x: u16, y: u16) -> Option<[u8; 4]> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let idx = (usize::from(y) * usize::from(self.width) + usize::from(x)) * 4;
        let data = self.image.data();
        Some([data[idx], data[idx + 1], data[idx + 2], data[idx + 3]])
    }

    pub fn clamp_rect(&self, rect: &InclusiveRectangle) -> Option<DirtyRect> {
        // `DecodedImage` / `FastPathProcessor` returns `InclusiveRectangle::empty()` (0, 0, 0, 0)
        // when an out-of-bounds or empty update is skipped. Do not call `rect.width()`/`height()`
        // before `clamp_inclusive_rect` checks `right >= left && bottom >= top`.
        if *rect == InclusiveRectangle::empty() {
            return None;
        }
        clamp_inclusive_rect(rect, self.width, self.height)
    }

    pub fn sha256_hex(&self) -> String {
        cert_sha256_hex(self.image.data())
    }
}

/// Lock-minimal front buffer holding only completed, tear-free RGBA frames for FFI readers.
pub struct PublishedFramebuffer {
    width: u16,
    height: u16,
    rgba: Vec<u8>,
}

impl PublishedFramebuffer {
    pub fn new(width: u16, height: u16) -> Self {
        let w = width.max(1);
        let h = height.max(1);
        Self {
            width: w,
            height: h,
            rgba: vec![0u8; usize::from(w) * usize::from(h) * 4],
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        let w = width.max(1);
        let h = height.max(1);
        if self.width != w || self.height != h {
            self.width = w;
            self.height = h;
            self.rgba.clear();
            self.rgba.resize(usize::from(w) * usize::from(h) * 4, 0);
        }
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn data(&self) -> &[u8] {
        &self.rgba
    }

    pub fn sha256_hex(&self) -> String {
        cert_sha256_hex(&self.rgba)
    }

    pub fn commit_from(&mut self, src: &Framebuffer, dirty: DirtyRect) {
        self.commit_rgba_slice(src.width(), src.height(), src.data(), dirty);
    }

    pub fn commit_rgba_slice(&mut self, fb_w: u16, fb_h: u16, src_data: &[u8], dirty: DirtyRect) {
        let expected = usize::from(fb_w) * usize::from(fb_h) * 4;
        if src_data.len() < expected {
            return;
        }
        if self.width != fb_w || self.height != fb_h || self.rgba.len() != expected {
            self.width = fb_w;
            self.height = fb_h;
            self.rgba.resize(expected, 0);
            self.rgba.copy_from_slice(&src_data[..expected]);
            return;
        }
        if dirty.x >= fb_w || dirty.y >= fb_h || dirty.w == 0 || dirty.h == 0 {
            return;
        }
        let w = dirty.w.min(fb_w - dirty.x);
        let h = dirty.h.min(fb_h - dirty.y);
        if dirty.x == 0 && dirty.y == 0 && w == fb_w && h == fb_h {
            self.rgba.copy_from_slice(&src_data[..expected]);
            return;
        }
        let stride = usize::from(fb_w) * 4;
        let row_bytes = usize::from(w) * 4;
        let x_bytes = usize::from(dirty.x) * 4;
        for row in 0..usize::from(h) {
            let offset = (usize::from(dirty.y) + row) * stride + x_bytes;
            self.rgba[offset..offset + row_bytes]
                .copy_from_slice(&src_data[offset..offset + row_bytes]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_rect_handles_in_bounds_partial_and_oob() {
        let in_bounds = InclusiveRectangle {
            left: 10,
            top: 20,
            right: 29,
            bottom: 39,
        };
        assert_eq!(
            clamp_inclusive_rect(&in_bounds, 100, 100),
            Some(DirtyRect {
                x: 10,
                y: 20,
                w: 20,
                h: 20
            })
        );

        let partial = InclusiveRectangle {
            left: 90,
            top: 80,
            right: 120,
            bottom: 110,
        };
        assert_eq!(
            clamp_inclusive_rect(&partial, 100, 100),
            Some(DirtyRect {
                x: 90,
                y: 80,
                w: 10,
                h: 20
            })
        );

        let oob = InclusiveRectangle {
            left: 100,
            top: 50,
            right: 110,
            bottom: 60,
        };
        assert_eq!(clamp_inclusive_rect(&oob, 100, 100), None);
    }

    #[test]
    fn dirty_rect_union_combines_bounds() {
        let a = DirtyRect {
            x: 10,
            y: 10,
            w: 10,
            h: 10,
        };
        let b = DirtyRect {
            x: 15,
            y: 25,
            w: 20,
            h: 5,
        };
        assert_eq!(
            a.union(b),
            DirtyRect {
                x: 10,
                y: 10,
                w: 25,
                h: 20
            }
        );
    }

    #[test]
    fn framebuffer_rgba_layout_and_resize() {
        let mut fb = Framebuffer::new(64, 48);
        assert_eq!(fb.data().len(), 64 * 48 * 4);
        assert!(fb.pixel_rgba(64, 0).is_none());
        assert!(fb.pixel_rgba(63, 47).is_some());
        fb.resize(32, 24);
        assert_eq!(fb.width(), 32);
        assert_eq!(fb.height(), 24);
        assert_eq!(fb.data().len(), 32 * 24 * 4);
    }

    #[test]
    fn clamp_rect_rejects_empty_and_inverted_without_panic() {
        let fb = Framebuffer::new(64, 48);
        assert_eq!(fb.clamp_rect(&InclusiveRectangle::empty()), None);
        assert_eq!(
            fb.clamp_rect(&InclusiveRectangle {
                left: 20,
                top: 10,
                right: 10,
                bottom: 5
            }),
            None
        );
        assert_eq!(
            fb.clamp_rect(&InclusiveRectangle {
                left: 10,
                top: 20,
                right: 10,
                bottom: 19
            }),
            None
        );
        assert_eq!(
            fb.clamp_rect(&InclusiveRectangle {
                left: 0,
                top: 0,
                right: u16::MAX,
                bottom: u16::MAX
            }),
            Some(DirtyRect {
                x: 0,
                y: 0,
                w: 64,
                h: 48
            })
        );
        assert_eq!(
            fb.clamp_rect(&InclusiveRectangle {
                left: 1,
                top: 0,
                right: 1,
                bottom: 0
            }),
            Some(DirtyRect {
                x: 1,
                y: 0,
                w: 1,
                h: 1
            })
        );
    }

    #[test]
    fn published_framebuffer_commits_only_dirty_region_atomically() {
        let src_bytes = [0xAA, 0xBB, 0xCC, 0xFF].repeat(8 * 8);
        let mut pub_fb = PublishedFramebuffer::new(8, 8);
        assert_eq!(&pub_fb.data()[0..4], &[0, 0, 0, 0]);

        pub_fb.commit_rgba_slice(
            8,
            8,
            &src_bytes,
            DirtyRect {
                x: 2,
                y: 2,
                w: 3,
                h: 2,
            },
        );
        // Outside dirty rect stays untouched (old frame preserved without tearing).
        assert_eq!(&pub_fb.data()[0..4], &[0, 0, 0, 0]);
        // Inside dirty rect (2, 2) is updated.
        let inside_idx = (2 * 8 + 2) * 4;
        assert_eq!(
            &pub_fb.data()[inside_idx..inside_idx + 4],
            &[0xAA, 0xBB, 0xCC, 0xFF]
        );
    }
}
