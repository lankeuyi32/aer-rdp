use ironrdp::input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};

pub struct InputController {
    db: Database,
    desktop_width: u16,
    desktop_height: u16,
}

impl InputController {
    pub fn new(desktop_width: u16, desktop_height: u16) -> Self {
        Self {
            db: Database::new(),
            desktop_width: desktop_width.max(1),
            desktop_height: desktop_height.max(1),
        }
    }

    pub fn set_desktop_size(&mut self, width: u16, height: u16) {
        self.desktop_width = width.max(1);
        self.desktop_height = height.max(1);
    }

    pub fn clamp_coords(&self, x: u16, y: u16) -> (u16, u16) {
        let max_x = self.desktop_width.saturating_sub(1);
        let max_y = self.desktop_height.saturating_sub(1);
        (x.min(max_x), y.min(max_y))
    }

    pub fn pointer_events(
        &mut self,
        x: u16,
        y: u16,
        button_mask: u8,
        down: bool,
        wheel_delta_v: i16,
        wheel_delta_h: i16,
    ) -> Vec<FastPathInputEvent> {
        let (cx, cy) = self.clamp_coords(x, y);
        let mut ops = Vec::new();
        ops.push(Operation::MouseMove(MousePosition { x: cx, y: cy }));

        let buttons = [
            (0x01u8, MouseButton::Left),
            (0x02u8, MouseButton::Right),
            (0x04u8, MouseButton::Middle),
            (0x08u8, MouseButton::X1),
            (0x10u8, MouseButton::X2),
        ];

        for (bit, btn) in buttons {
            if (button_mask & bit) != 0 {
                if down {
                    ops.push(Operation::MouseButtonPressed(btn));
                } else {
                    ops.push(Operation::MouseButtonReleased(btn));
                }
            }
        }

        if wheel_delta_v != 0 {
            ops.push(Operation::WheelRotations(WheelRotations {
                is_vertical: true,
                rotation_units: wheel_delta_v.clamp(-256, 255),
            }));
        }
        if wheel_delta_h != 0 {
            ops.push(Operation::WheelRotations(WheelRotations {
                is_vertical: false,
                rotation_units: wheel_delta_h.clamp(-256, 255),
            }));
        }

        self.db.apply(ops).into_vec()
    }

    pub fn scancode_events(&mut self, code: u8, extended: bool, down: bool) -> Vec<FastPathInputEvent> {
        let sc = Scancode::from_u8(extended, code);
        let op = if down {
            Operation::KeyPressed(sc)
        } else {
            Operation::KeyReleased(sc)
        };
        self.db.apply([op]).into_vec()
    }

    pub fn unicode_events(&mut self, code_unit: u16, down: bool) -> Vec<FastPathInputEvent> {
        if let Some(ch) = char::from_u32(u32::from(code_unit)) {
            let op = if down {
                Operation::UnicodeKeyPressed(ch)
            } else {
                Operation::UnicodeKeyReleased(ch)
            };
            return self.db.apply([op]).into_vec();
        }

        let flags = if down {
            KeyboardFlags::empty()
        } else {
            KeyboardFlags::RELEASE
        };
        vec![FastPathInputEvent::UnicodeKeyboardEvent(flags, code_unit)]
    }

    pub fn release_all(&mut self) -> Vec<FastPathInputEvent> {
        self.db.release_all().into_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pointer_coords_clamped_to_desktop_bounds() {
        let mut ctrl = InputController::new(800, 600);
        let evs = ctrl.pointer_events(2000, 1000, 0x01, true, 120, -120);
        assert!(evs.iter().any(|e| matches!(
            e,
            FastPathInputEvent::MouseEvent(m) if m.x_position == 799 && m.y_position == 599
        )));
    }

    #[test]
    fn release_all_emits_releases_for_held_keys_and_buttons() {
        let mut ctrl = InputController::new(1280, 720);
        assert!(!ctrl.pointer_events(10, 20, 0x07, true, 0, 0).is_empty());
        assert!(!ctrl.scancode_events(0x1E, false, true).is_empty());
        assert!(!ctrl.unicode_events(b'A' as u16, true).is_empty());

        let released = ctrl.release_all();
        assert_eq!(released.len(), 5, "3 mouse buttons + 1 scancode + 1 unicode");
    }
}
