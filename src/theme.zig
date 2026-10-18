//! nanomon's colors: Harness's Codegraff palettes, as nanoterm's (warm
//! charcoal or cream, amber for what is chosen, rust, sage, gold, slate
//! and violet for the parts of the machine), Geist for words and
//! JetBrains Mono for figures; light or dark as the system is.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    sidebar: Color,
    /// The selected sidebar item, and the text on it.
    picked: Color,
    on_picked: Color,
    page: Color,
    card: Color,
    /// Cards' and wells' edges.
    border: Color,
    /// The well a graph sits in, and a cell with nothing in it.
    well: Color,
    empty: Color,
    separator: Color,
    text: Color,
    secondary: Color,
    tertiary: Color,
    accent: Color,
    /// Table rows: every other one, the selection, the ones marked.
    stripe: Color,
    selection: Color,
    on_selection: Color,
    marked: Color,
    control: Color,
    control_on: Color,
    hover: Color,
    /// The graphs' series.
    user: Color,
    system: Color,
    fast: Color,
    frugal: Color,
    // Parts of the machine.
    gray: Color,
    blue: Color,
    green: Color,
    red: Color,
    orange: Color,
    teal: Color,
    purple: Color,
    yellow: Color,
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const bg = Color.hex(0x16140f);
        const amber = Color.hex(0xe8a33d);
        return .{
            .sidebar = .hex(0x1b1914),
            .picked = amber,
            .on_picked = bg,
            .page = bg,
            .card = .hex(0x1f1c16),
            .border = bg.mix(white, 0.09),
            .well = .hex(0x191712),
            .empty = .hex(0x2c2820),
            .separator = bg.mix(white, 0.08),
            .text = .hex(0xedeae2),
            .secondary = .hex(0x9a9384),
            .tertiary = .hex(0x5c564b),
            .accent = amber,
            .stripe = .hex(0x1a1813),
            .selection = bg.mix(amber, 0.20),
            .on_selection = .hex(0xedeae2),
            .marked = bg.mix(amber, 0.09),
            .control = .hex(0x221f19),
            .control_on = .hex(0x37322a),
            .hover = white.alpha(0.05),
            .user = amber,
            .system = .hex(0xd2674f),
            .fast = amber,
            .frugal = .hex(0xc9b48a),
            .gray = .hex(0x9a9384),
            .blue = .hex(0x8a9bb0),
            .green = .hex(0x7fa86b),
            .red = .hex(0xd2674f),
            .orange = .hex(0xd9a441),
            .teal = .hex(0x6fb0a8),
            .purple = .hex(0xbd80e4),
            .yellow = .hex(0xd9a441),
        };
    }
    const bg = Color.hex(0xfaf8f3);
    const amber = Color.hex(0xc77d20);
    return .{
        .sidebar = .hex(0xf3efe6),
        .picked = amber,
        .on_picked = .hex(0xfffdf8),
        .page = bg,
        .card = .hex(0xf0ece3),
        .border = bg.mix(black, 0.09),
        .well = .hex(0xe9e3d6),
        .empty = .hex(0xd9d1c0),
        .separator = bg.mix(black, 0.08),
        .text = .hex(0x1a1813),
        .secondary = .hex(0x6b6557),
        .tertiary = .hex(0xa8a090),
        .accent = amber,
        .stripe = .hex(0xf5f2ea),
        .selection = bg.mix(amber, 0.18),
        .on_selection = .hex(0x1a1813),
        .marked = bg.mix(amber, 0.08),
        .control = .hex(0xebe5d9),
        .control_on = .hex(0xfffdf8),
        .hover = black.alpha(0.04),
        .user = amber,
        .system = .hex(0xb14228),
        .fast = amber,
        .frugal = .hex(0xa88d5c),
        .gray = .hex(0x6b6557),
        .blue = .hex(0x3b6fb0),
        .green = .hex(0x5c7e47),
        .red = .hex(0xb14228),
        .orange = .hex(0x9a6e1b),
        .teal = .hex(0x2f8f9d),
        .purple = .hex(0x7a4ea3),
        .yellow = .hex(0x9a6e1b),
    };
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.page;
    t.surface = k.control_on;
    t.surface_hover = k.control;
    t.text = k.text;
    t.muted = k.secondary;
    t.border = k.border;
    t.accent = k.accent;
    // Deeper amber under the pointer, not the default theme's blue.
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.14);
    t.accent_text = k.on_picked;
    t.track = k.control;
    t.danger = k.red;
    t.success = k.green;
    t.font = "Geist";
    t.mono_font = "JetBrains Mono";
    return t;
}
