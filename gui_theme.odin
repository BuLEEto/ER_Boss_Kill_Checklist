package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "gui:skald"

// ============================================================================
// Per-integration appearance and region controls
//
// Both are built once and rendered on whichever OBS panel owns them, with
// the panel passed as a payload so one set of callbacks serves all of
// them. Nothing here reads a setting belonging to a different panel.
// ============================================================================

// The panels that serve a styled page and so have an appearance.
Look_Target :: enum {
	Browser,   // the overlay card
	Websocket, // the individual widget pages
}

// The panels that show a region. Text files have no appearance but do
// have a region, hence two enums rather than one.
Region_Target :: enum {
	Browser,
	Text,
	Websocket,
}

settings_look :: proc(t: Look_Target) -> ^Appearance {
	switch t {
	case .Browser:   return &app.settings.browser_look
	case .Websocket: return &app.settings.ws_look
	}
	return &app.settings.browser_look
}

settings_region :: proc(t: Region_Target) -> ^Region_Choice {
	switch t {
	case .Browser:   return &app.settings.browser_region
	case .Text:      return &app.settings.text_region
	case .Websocket: return &app.settings.ws_region
	}
	return &app.settings.browser_region
}

// ----------------------------------------------------------------------------
// Colour conversion
//
// Skald's Color is *linear* — skald.rgb applies the sRGB transfer
// function on the way in, because the renderer blends in linear space.
// Settings store sRGB "#rrggbb", which is what CSS wants. Getting this
// wrong isn't subtle: feeding sRGB straight in as linear renders #ff4444
// as roughly #ff8d8d.
// ----------------------------------------------------------------------------

hex_to_color :: proc(hex: string) -> skald.Color {
	if !is_hex_colour(hex) do return skald.rgb(0xffffff)
	v, ok := strconv.parse_u64_of_base(hex[1:], 16)
	if !ok do return skald.rgb(0xffffff)
	return skald.rgb(u32(v))
}

color_to_hex :: proc(c: skald.Color, allocator := context.temp_allocator) -> string {
	// The inverse of skald.srgb_to_linear. Skald doesn't export one, and
	// the picker hands back linear values, so a round trip through the
	// picker would drift without it.
	channel :: proc(linear: f32) -> int {
		v := clamp(linear, 0, 1)
		srgb := v <= 0.0031308 \
			? v * 12.92 \
			: 1.055 * math.pow(v, 1.0 / 2.4) - 0.055
		return clamp(int(srgb * 255 + 0.5), 0, 255)
	}
	return fmt.aprintf(
		"#%02x%02x%02x",
		channel(c.r), channel(c.g), channel(c.b),
		allocator = allocator,
	)
}

// ----------------------------------------------------------------------------
// Region control
// ----------------------------------------------------------------------------

REGION_FIRST_LABEL :: "Auto — first unfinished"
REGION_LAST_KILL_LABEL :: "Auto — where I last killed"

region_choice_labels :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(app.regions) + 2, allocator)
	append(&out, REGION_FIRST_LABEL, REGION_LAST_KILL_LABEL)
	for &r in app.regions do append(&out, r.region_name)
	return out[:]
}

region_choice_label :: proc(t: Region_Target) -> string {
	c := settings_region(t)^
	switch c.mode {
	case "last_kill":
		return REGION_LAST_KILL_LABEL
	case "pinned":
		if name := app_pinned_region_name(c); len(name) > 0 do return name
	}
	return REGION_FIRST_LABEL
}

region_choice_hint :: proc(t: Region_Target) -> string {
	c := settings_region(t)^
	switch c.mode {
	case "last_kill":
		if len(app.settings.last_kill_region) > 0 {
			return fmt.tprintf(
				"Following %s, where the last kill happened. Moves on its own as you play; falls back to the first unfinished area until the next kill once that one is cleared.",
				app.settings.last_kill_region,
			)
		}
		return "Follows whichever area you most recently killed something in. The save records that a boss is dead, never when — so this only counts kills the app was open for. Until then it shows the first unfinished area."
	case "pinned":
		return "Pinned — stays on this area until you change it."
	}
	return "Follows the first area you haven't finished, in list order."
}

view_region_control :: proc(ctx: ^skald.Ctx(Msg), t: Region_Target, id_key: string) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, skald.form_row(ctx, "Region",
		skald.select(
			ctx, region_choice_label(t), region_choice_labels(),
			t, on_region_selected, width = 280, id = skald.hash_id(id_key),
		),
		label_width = 120,
	))
	append(&rows, paragraph(ctx, region_choice_hint(t), th.color.fg_muted, th.font.size_xs))
	return rows[:]
}

// ----------------------------------------------------------------------------
// Appearance control
// ----------------------------------------------------------------------------

view_appearance :: proc(
	s: Gui,
	ctx: ^skald.Ctx(Msg),
	t: Look_Target,
	prefix: string,
	blurb: string,
) -> []skald.View {
	th := ctx.theme
	look := settings_look(t)^
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, skald.section_header(ctx, "Appearance"))
	append(&rows, paragraph(ctx, blurb, th.color.fg_muted, th.font.size_xs))

	append(&rows, skald.form_row(ctx, "Align",
		skald.segmented(
			ctx, {"Left", "Centre", "Right"},
			overlay_align_index(look.align), t, on_look_align,
			id = skald.hash_id(fmt.tprintf("%s.align", prefix)),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx, "Accent",
		skald.color_picker(
			ctx, hex_to_color(look.accent), t, on_accent_picked,
			width = 220, id = skald.hash_id(fmt.tprintf("%s.accent", prefix)),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx, "Text",
		skald.color_picker(
			ctx, hex_to_color(look.text_color), t, on_text_color_picked,
			width = 220, id = skald.hash_id(fmt.tprintf("%s.text", prefix)),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx,
		fmt.tprintf("Size %dpx", look.font_size),
		skald.slider(
			ctx, f32(look.font_size), t, on_font_size,
			min_value = 12, max_value = 96, step = 1, width = 220,
			id = skald.hash_id(fmt.tprintf("%s.size", prefix)),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx, "Font",
		skald.row(
			skald.text_input(
				ctx, s.font_family_draft[t], t, on_font_family_draft,
				placeholder = "default", width = 220,
				id = skald.hash_id(fmt.tprintf("%s.font", prefix)),
			),
			skald.button(ctx, "Apply", Msg(Look_Font_Committed{target = t})),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		label_width = 120,
	))
	append(&rows, skald.checkbox(
		ctx, look.outline, "Dark outline behind the text",
		t, on_look_outline, id = skald.hash_id(fmt.tprintf("%s.outline", prefix)),
	))

	append(&rows, skald.spacer(th.spacing.xs))
	append(&rows, skald.text("Advanced — custom CSS", th.color.fg, th.font.size_sm))
	append(&rows, paragraph(ctx,
		"Added after everything above, so it overrides it. Selectors worth knowing: .widget-value and .widget-line for the individual sources, .overlay for the card, and the variables --gold, --gold-dim, --text, --text-dim, --red, --green.",
		th.color.fg_muted, th.font.size_xs,
	))
	append(&rows, skald.text_input(
		ctx, s.custom_css_draft[t], t, on_custom_css_draft,
		placeholder = ".widget-line { letter-spacing: 1px; }",
		multiline = true, wrap = true, min_lines = 3, max_lines = 10,
		id = skald.hash_id(fmt.tprintf("%s.css", prefix)),
	))
	append(&rows, skald.row(
		skald.button(ctx, "Apply CSS", Msg(Look_Css_Committed{target = t})),
		skald.button(ctx, "Reset appearance", Msg(Look_Reset{target = t})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	return rows[:]
}

overlay_align_index :: proc(a: string) -> int {
	switch a {
	case "center": return 1
	case "right":  return 2
	case:          return 0
	}
}

// ----------------------------------------------------------------------------
// Callbacks. Skald's payload variants let one proc serve every panel.
// ----------------------------------------------------------------------------

on_region_selected :: proc(t: Region_Target, label: string) -> Msg {
	switch label {
	case REGION_FIRST_LABEL:     return Region_Selected{target = t, choice = "first"}
	case REGION_LAST_KILL_LABEL: return Region_Selected{target = t, choice = "last_kill"}
	}
	return Region_Selected{target = t, choice = label} // a region name is a pin
}

on_accent_picked :: proc(t: Look_Target, c: skald.Color) -> Msg {
	return Look_Accent_Set{target = t, hex = color_to_hex(c)}
}
on_text_color_picked :: proc(t: Look_Target, c: skald.Color) -> Msg {
	return Look_Text_Set{target = t, hex = color_to_hex(c)}
}
on_font_size :: proc(t: Look_Target, v: f32) -> Msg {
	return Look_Size_Set{target = t, size = int(v + 0.5)}
}
on_look_outline :: proc(t: Look_Target, v: bool) -> Msg {
	return Look_Outline_Set{target = t, on = v}
}
on_look_align :: proc(t: Look_Target, i: int) -> Msg {
	align := "left"
	switch i {
	case 1: align = "center"
	case 2: align = "right"
	}
	return Look_Align_Set{target = t, align = align}
}
on_font_family_draft :: proc(t: Look_Target, v: string) -> Msg {
	return Look_Font_Draft{target = t, text = v}
}
on_custom_css_draft :: proc(t: Look_Target, v: string) -> Msg {
	return Look_Css_Draft{target = t, text = v}
}
