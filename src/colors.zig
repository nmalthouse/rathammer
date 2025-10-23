pub const colors = Colors{};

const Colors = struct {
    clear: u32 = 0x9e8e7c_ff,
    splash_clear: u32 = 0x678caa_ff,
    progress: u32 = 0xf7a41d_ff,
    //splash_tint: u32 = 0x88,
    splash_tint: u32 = 0x0,

    selected: u32 = 0x00ff00_ff,

    tentative: u32 = 0xfca73f_ff,
    good: u32 = 0x00ff00_ff,
    bad: u32 = 0xff0000_ff,
};
