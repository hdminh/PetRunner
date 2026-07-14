#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MotionState {
    pub x: f64,
    pub y: f64,
    pub velocity_x: f64,
    pub velocity_y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsConfig {
    pub velocity_retention_per_second: f64,
    pub restitution: f64,
    pub stop_speed: f64,
    pub maximum_delta_time: f64,
}

impl Default for PhysicsConfig {
    fn default() -> Self {
        Self {
            velocity_retention_per_second: 0.18,
            restitution: 0.72,
            stop_speed: 8.0,
            maximum_delta_time: 1.0,
        }
    }
}

impl PhysicsConfig {
    pub fn step(
        self,
        motion: &mut MotionState,
        size: Size,
        bounds: Rect,
        delta_time: f64,
    ) -> (bool, bool) {
        let dt = delta_time.clamp(0.0, self.maximum_delta_time);
        if dt <= 0.0 || !dt.is_finite() {
            return (false, false);
        }
        motion.x += motion.velocity_x * dt;
        motion.y += motion.velocity_y * dt;
        let max_x = bounds.x.max(bounds.x + bounds.width - size.width);
        let max_y = bounds.y.max(bounds.y + bounds.height - size.height);
        let mut horizontal = false;
        let mut vertical = false;
        if motion.x < bounds.x {
            motion.x = bounds.x;
            motion.velocity_x = motion.velocity_x.abs() * self.restitution;
            horizontal = true;
        } else if motion.x > max_x {
            motion.x = max_x;
            motion.velocity_x = -motion.velocity_x.abs() * self.restitution;
            horizontal = true;
        }
        if motion.y < bounds.y {
            motion.y = bounds.y;
            motion.velocity_y = motion.velocity_y.abs() * self.restitution;
            vertical = true;
        } else if motion.y > max_y {
            motion.y = max_y;
            motion.velocity_y = -motion.velocity_y.abs() * self.restitution;
            vertical = true;
        }
        let retention = self.velocity_retention_per_second.powf(dt);
        motion.velocity_x *= retention;
        motion.velocity_y *= retention;
        if motion.velocity_x.hypot(motion.velocity_y) < self.stop_speed {
            motion.velocity_x = 0.0;
            motion.velocity_y = 0.0;
        }
        (horizontal, vertical)
    }

    #[must_use]
    pub fn clamped_origin(origin_x: f64, origin_y: f64, size: Size, bounds: Rect) -> (f64, f64) {
        let max_x = bounds.x.max(bounds.x + bounds.width - size.width);
        let max_y = bounds.y.max(bounds.y + bounds.height - size.height);
        (
            origin_x.clamp(bounds.x, max_x),
            origin_y.clamp(bounds.y, max_y),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_bounces_and_stops() {
        let mut motion = MotionState {
            x: 95.0,
            y: 40.0,
            velocity_x: 200.0,
            velocity_y: 0.0,
        };
        let (horizontal, _) = PhysicsConfig {
            velocity_retention_per_second: 1.0,
            stop_speed: 0.0,
            ..PhysicsConfig::default()
        }
        .step(
            &mut motion,
            Size {
                width: 10.0,
                height: 10.0,
            },
            Rect {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            },
            0.1,
        );
        assert!(horizontal);
        assert_eq!(motion.x, 90.0);
        assert!(motion.velocity_x < 0.0);
    }
}
