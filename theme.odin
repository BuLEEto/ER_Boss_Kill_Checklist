package main

import "gui:skald"

// ============================================================================
// Elden Ring theme
//
// The game's own palette: warm near-black surfaces the colour of soot and
// old leather, Erdtree gold for anything the user acts on, and parchment
// for text. Nothing here is a hue-rotated version of Skald's stock dark
// theme — the neutrals are deliberately warm (a touch of red and yellow
// in every step) so gold sits on them without looking like a highlighter.
//
// Roles that need to stay legible as *states* rather than decoration:
//
//   success  A muted sage. Marks defeated bosses and cleared regions.
//            Gold would have read as "interactive" next to the buttons,
//            and a saturated green would have been the one thing on
//            screen that isn't from the game.
//   danger   Blood red, for errors and failed connections.
//   warning  Amber, one step hotter than the gold so the two don't merge.
//
// Skald themes are plain data, so this is just a struct literal. Every
// field has to be populated — widgets read the palette directly and
// don't fall back to neighbouring roles.
// ============================================================================

theme_elden_ring :: proc() -> skald.Theme {
	th := skald.theme_dark() // inherit radius / spacing / font scales
	th.color = skald.Theme_Colors {
		// Warm neutral ladder. Each step lifts enough to separate a card
		// from the page and a popover from the card, without any step
		// going cold or grey.
		bg       = skald.rgb(0x14110c), // soot
		surface  = skald.rgb(0x1d1913), // cards, panels
		elevated = skald.rgb(0x282118), // popovers, menus, the save picker
		border   = skald.rgb(0x3d3325), // hairlines, worn bronze

		// Parchment, not white — white on a warm ground reads blue.
		fg       = skald.rgb(0xe6dcc4),
		fg_muted = skald.rgb(0x9d9075),

		// Erdtree gold. on_primary is near-black rather than white:
		// gold is a light fill, so dark text is what stays readable.
		primary    = skald.rgb(0xc7a44a),
		on_primary = skald.rgb(0x14110c),

		// Gold at ~30% for selection fills, so the text under it survives.
		selection = skald.rgba(0xc7a44a4d),

		success = skald.rgb(0x8a9a5b), // sage — defeated
		warning = skald.rgb(0xd9963a), // amber
		danger  = skald.rgb(0xa8392a), // blood
	}
	return th
}

// The app's themes, in the order they appear in the Setup tab's picker.
// Stored in settings.json by `name`.
Theme_Choice :: struct {
	name:  string,
	label: string,
}

THEME_CHOICES :: [?]Theme_Choice {
	{"elden",  "Elden Ring"},
	{"dark",   "Dark"},
	{"light",  "Light"},
	{"system", "Follow system"},
}

theme_for_name :: proc(name: string, scale: f32 = 1) -> skald.Theme {
	th: skald.Theme
	switch name {
	case "dark":
		th = skald.theme_dark()
	case "light":
		th = skald.theme_light()
	case "system":
		// Follow the OS, but use our own dark rather than Skald's stock
		// one — someone who picked "follow system" still chose this app.
		th = skald.system_theme() == .Light ? skald.theme_light() : theme_elden_ring()
	case:
		th = theme_elden_ring()
	}
	return theme_scaled(th, scale)
}

// ----------------------------------------------------------------------------
// Text size
//
// Skald's stock scale tops out at 14 px body text and 11 px for captions,
// which is small on a large or high-resolution display. Rather than
// hardcode bigger numbers — and be wrong for someone else's monitor —
// scale the whole token set and let the user pick.
//
// Spacing and radii scale alongside the type. Growing the text on its own
// leaves rows visually cramped, because a widget's padding comes from the
// spacing scale, not from its font size.
// ----------------------------------------------------------------------------

UI_SCALE_MIN :: f32(0.8)
UI_SCALE_MAX :: f32(1.6)

Ui_Scale_Choice :: struct {
	scale: f32,
	label: string,
}

// Discrete steps rather than a slider: a drag would re-theme on every
// frame, and each intermediate size is a fresh set of glyphs for the text
// atlas to rasterize and cache.
UI_SCALE_CHOICES :: [?]Ui_Scale_Choice {
	{0.90, "Small"},
	{1.00, "Normal"},
	{1.15, "Large"},
	{1.30, "Larger"},
	{1.50, "Largest"},
}

theme_scaled :: proc(th: skald.Theme, scale: f32) -> skald.Theme {
	s := clamp(scale, UI_SCALE_MIN, UI_SCALE_MAX)
	if s == 1 do return th

	out := th
	out.font = skald.Theme_Font {
		size_xs      = th.font.size_xs * s,
		size_sm      = th.font.size_sm * s,
		size_md      = th.font.size_md * s,
		size_lg      = th.font.size_lg * s,
		size_xl      = th.font.size_xl * s,
		size_display = th.font.size_display * s,
	}
	out.spacing = skald.Theme_Spacing {
		xs = th.spacing.xs * s,
		sm = th.spacing.sm * s,
		md = th.spacing.md * s,
		lg = th.spacing.lg * s,
		xl = th.spacing.xl * s,
	}
	out.radius = skald.Theme_Radii {
		sm   = th.radius.sm * s,
		md   = th.radius.md * s,
		lg   = th.radius.lg * s,
		xl   = th.radius.xl * s,
		pill = th.radius.pill, // already "as round as it goes"
	}
	return out
}

ui_scale_label :: proc(scale: f32) -> string {
	choices := UI_SCALE_CHOICES
	best := choices[0]
	for c in choices {
		if abs(c.scale - scale) < abs(best.scale - scale) do best = c
	}
	return best.label
}

ui_scale_for_label :: proc(label: string) -> f32 {
	choices := UI_SCALE_CHOICES
	for c in choices {
		if c.label == label do return c.scale
	}
	return 1
}

ui_scale_labels :: proc(allocator := context.temp_allocator) -> []string {
	choices := UI_SCALE_CHOICES
	out := make([]string, len(choices), allocator)
	for c, i in choices do out[i] = c.label
	return out
}

theme_label :: proc(name: string) -> string {
	choices := THEME_CHOICES
	for c in choices {
		if c.name == name do return c.label
	}
	return "Elden Ring"
}

theme_name_for_label :: proc(label: string) -> string {
	choices := THEME_CHOICES
	for c in choices {
		if c.label == label do return c.name
	}
	return "elden"
}

theme_labels :: proc(allocator := context.temp_allocator) -> []string {
	choices := THEME_CHOICES
	out := make([]string, len(choices), allocator)
	for c, i in choices do out[i] = c.label
	return out
}
