use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp::pdu::geometry::{InclusiveRectangle, Rectangle as _};
use ironrdp::session::image::DecodedImage;

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
}
