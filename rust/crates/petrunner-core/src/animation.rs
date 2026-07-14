use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum AnimationState {
    Idle = 0,
    RunningRight = 1,
    RunningLeft = 2,
    Waving = 3,
    Jumping = 4,
    Failed = 5,
    Waiting = 6,
    Running = 7,
    Review = 8,
}

impl TryFrom<i32> for AnimationState {
    type Error = ();

    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Idle),
            1 => Ok(Self::RunningRight),
            2 => Ok(Self::RunningLeft),
            3 => Ok(Self::Waving),
            4 => Ok(Self::Jumping),
            5 => Ok(Self::Failed),
            6 => Ok(Self::Waiting),
            7 => Ok(Self::Running),
            8 => Ok(Self::Review),
            _ => Err(()),
        }
    }
}

impl AnimationState {
    #[must_use]
    pub const fn row(self) -> i32 {
        self as i32
    }

    #[must_use]
    pub fn frame_durations(self) -> &'static [f64] {
        match self {
            Self::Idle => &[0.84, 0.33, 0.33, 0.42, 0.42, 0.96],
            Self::RunningRight | Self::RunningLeft => {
                &[0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
            }
            Self::Waving => &[0.14, 0.14, 0.14, 0.28],
            Self::Jumping => &[0.14, 0.14, 0.14, 0.14, 0.28],
            Self::Failed => &[0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.24],
            Self::Waiting => &[0.15, 0.15, 0.15, 0.15, 0.15, 0.26],
            Self::Running => &[0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
            Self::Review => &[0.15, 0.15, 0.15, 0.15, 0.15, 0.28],
        }
    }

    #[must_use]
    pub const fn cycles_before_idle(self) -> Option<u32> {
        match self {
            Self::Jumping => Some(3),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(C)]
pub struct AtlasAddress {
    pub row: i32,
    pub column: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdleAction {
    pub columns: Vec<usize>,
}

impl IdleAction {
    #[must_use]
    pub fn new(columns: impl IntoIterator<Item = usize>) -> Self {
        let columns = columns
            .into_iter()
            .filter(|column| *column < AnimationState::Idle.frame_durations().len())
            .collect::<Vec<_>>();
        Self {
            columns: if columns.is_empty() { vec![0] } else { columns },
        }
    }

    #[must_use]
    pub fn standard() -> Self {
        Self::new(0..6)
    }
}

#[derive(Clone, Debug)]
pub struct AnimationPlayback {
    state: AnimationState,
    frame_index: usize,
    elapsed_in_frame: f64,
    idle_actions: Vec<IdleAction>,
    idle_action_index: usize,
    idle_action_columns: Vec<usize>,
    idle_action_position: usize,
    idle_pause_remaining: f64,
    completed_state_cycles: u32,
}

impl Default for AnimationPlayback {
    fn default() -> Self {
        Self::new(AnimationState::Idle, vec![IdleAction::standard()], 0)
    }
}

impl AnimationPlayback {
    #[must_use]
    pub fn new(
        state: AnimationState,
        idle_actions: Vec<IdleAction>,
        idle_action_index: usize,
    ) -> Self {
        let idle_actions = if idle_actions.is_empty() {
            vec![IdleAction::standard()]
        } else {
            idle_actions
        };
        let mut playback = Self {
            state,
            frame_index: 0,
            elapsed_in_frame: 0.0,
            idle_actions,
            idle_action_index,
            idle_action_columns: Vec::new(),
            idle_action_position: 0,
            idle_pause_remaining: 0.0,
            completed_state_cycles: 0,
        };
        if state == AnimationState::Idle {
            playback.begin_idle_action();
        }
        playback
    }

    pub fn start(&mut self, state: AnimationState) {
        self.state = state;
        self.frame_index = 0;
        self.elapsed_in_frame = 0.0;
        self.idle_pause_remaining = 0.0;
        self.completed_state_cycles = 0;
        if state == AnimationState::Idle {
            self.begin_idle_action();
        }
    }

    pub fn advance(&mut self, delta_time: f64) {
        if !delta_time.is_finite() || delta_time <= 0.0 {
            return;
        }
        if self.state == AnimationState::Idle {
            self.advance_idle(delta_time);
            return;
        }

        self.elapsed_in_frame += delta_time;
        while self.elapsed_in_frame + 1e-12 >= self.state.frame_durations()[self.frame_index] {
            self.elapsed_in_frame -= self.state.frame_durations()[self.frame_index];
            self.frame_index += 1;
            if self.frame_index == self.state.frame_durations().len() {
                if let Some(cycles_before_idle) = self.state.cycles_before_idle() {
                    self.completed_state_cycles += 1;
                    if self.completed_state_cycles == cycles_before_idle {
                        self.start(AnimationState::Idle);
                        return;
                    }
                }
                self.frame_index = 0;
            }
        }
    }

    #[must_use]
    pub const fn state(&self) -> AnimationState {
        self.state
    }
    #[must_use]
    pub const fn frame_index(&self) -> usize {
        self.frame_index
    }
    #[must_use]
    pub const fn elapsed_in_frame(&self) -> f64 {
        self.elapsed_in_frame
    }
    #[must_use]
    pub fn atlas_address(&self) -> AtlasAddress {
        AtlasAddress {
            row: self.state.row(),
            column: self.frame_index as i32,
        }
    }

    fn advance_idle(&mut self, delta_time: f64) {
        let mut remaining = delta_time;
        while remaining > 1e-12 {
            if self.idle_pause_remaining > 0.0 {
                if remaining + 1e-12 < self.idle_pause_remaining {
                    self.idle_pause_remaining -= remaining;
                    return;
                }
                remaining = (remaining - self.idle_pause_remaining).max(0.0);
                self.idle_pause_remaining = 0.0;
                self.begin_idle_action();
                continue;
            }
            let time_to_boundary =
                AnimationState::Idle.frame_durations()[self.frame_index] - self.elapsed_in_frame;
            if remaining + 1e-12 < time_to_boundary {
                self.elapsed_in_frame += remaining;
                return;
            }
            remaining = (remaining - time_to_boundary).max(0.0);
            self.elapsed_in_frame = 0.0;
            self.idle_action_position += 1;
            if self.idle_action_position == self.idle_action_columns.len() {
                self.frame_index = 0;
                self.idle_pause_remaining = 1.0;
            } else {
                self.frame_index = self.idle_action_columns[self.idle_action_position];
            }
        }
    }

    fn begin_idle_action(&mut self) {
        let index = self.idle_action_index % self.idle_actions.len();
        self.idle_action_columns = self.idle_actions[index].columns.clone();
        self.idle_action_position = 0;
        self.frame_index = self.idle_action_columns[0];
        self.elapsed_in_frame = 0.0;
    }
}

pub struct LookDirection;

impl LookDirection {
    #[must_use]
    pub fn frame_index(dx: f64, dy: f64, deadzone: f64) -> Option<i32> {
        if dx.hypot(dy) < deadzone || !dx.is_finite() || !dy.is_finite() {
            return None;
        }
        let mut angle = dx.atan2(dy);
        if angle < 0.0 {
            angle += 2.0 * PI;
        }
        Some((angle / (PI / 8.0)).round() as i32 % 16)
    }

    #[must_use]
    pub const fn atlas_address(frame_index: i32) -> Option<AtlasAddress> {
        if frame_index < 0 || frame_index >= 16 {
            return None;
        }
        if frame_index < 8 {
            Some(AtlasAddress {
                row: 9,
                column: frame_index,
            })
        } else {
            Some(AtlasAddress {
                row: 10,
                column: frame_index - 8,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jumping_returns_to_idle_after_three_cycles() {
        let mut playback = AnimationPlayback::default();
        playback.start(AnimationState::Jumping);
        let cycle = AnimationState::Jumping
            .frame_durations()
            .iter()
            .sum::<f64>();
        playback.advance(cycle * 3.0);
        assert_eq!(playback.state(), AnimationState::Idle);
        assert_eq!(playback.frame_index(), 0);
    }

    #[test]
    fn idle_pause_matches_legacy_timing() {
        let mut playback = AnimationPlayback::default();
        playback.advance(AnimationState::Idle.frame_durations().iter().sum());
        playback.advance(0.999);
        assert_eq!(playback.frame_index(), 0);
        playback.advance(0.001 + AnimationState::Idle.frame_durations()[0]);
        assert_eq!(playback.frame_index(), 1);
    }

    #[test]
    fn look_direction_maps_all_quadrants() {
        assert_eq!(LookDirection::frame_index(0.0, 100.0, 24.0), Some(0));
        assert_eq!(LookDirection::frame_index(100.0, 0.0, 24.0), Some(4));
        assert_eq!(LookDirection::frame_index(0.0, -100.0, 24.0), Some(8));
        assert_eq!(
            LookDirection::atlas_address(15),
            Some(AtlasAddress { row: 10, column: 7 })
        );
    }
}
