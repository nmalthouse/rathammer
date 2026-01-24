pub const min_volume: f32 = 0.125;
pub const min_snap: f32 = 0.001;

pub const min_grid: f32 = 1.0 / 8.0;
pub const max_grid: f32 = 4096;

pub const delta_drawn: f32 = 0.001;
pub const csg_epsilon: f64 = 2E-14;

pub const IS_DEBUG = @import("builtin").mode == .Debug;
