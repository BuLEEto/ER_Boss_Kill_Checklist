package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gui:skald"

// ============================================================================
// Overlay appearance controls
//
// Colours are stored as "#rrggbb" because that's what goes into the
// generated stylesheet; Skald's picker works in [4]f32. These convert
// between the two, and are lossy in the way you'd expect — the picker's
// alpha channel has nowhere to go in a six-digit hex, so it's dropped.
// ============================================================================

// Skald's Color is *linear* — skald.rgb applies the sRGB transfer
// function on the way in, because the renderer blends in linear space.
// Settings store sRGB "#rrggbb", which is what CSS wants. Getting this
// wrong isn't subtle: feeding sRGB straight in as linear renders #ff4444
// as roughly #ff8d8d.
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

// The appearance section of the OBS tab.
//
// It lives in the app rather than being left to OBS because OBS's Custom
// CSS box is per source: with seven sources, theming through OBS means
// pasting the same rules seven times and again on every change. Set here,
// one value repaints the overlay and every widget at once. OBS's box
// still works and still wins, which makes it the right place for a
// one-off tweak to a single source.
view_overlay_theme :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, skald.section_header(ctx, "Appearance"))
	append(&rows, paragraph(ctx,
		"Applies to the overlay and every widget at once. OBS's own Custom CSS box still works on top, per source, for one-off changes.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.form_row(ctx, "Accent",
		skald.color_picker(
			ctx, hex_to_color(app.settings.overlay_accent), on_accent_picked,
			width = 220, id = skald.hash_id(ID_THEME_ACCENT),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx, "Text",
		skald.color_picker(
			ctx, hex_to_color(app.settings.overlay_text_color), on_text_color_picked,
			width = 220, id = skald.hash_id(ID_THEME_TEXT),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx,
		fmt.tprintf("Size %dpx", app.settings.overlay_font_size),
		skald.slider(
			ctx, f32(app.settings.overlay_font_size), on_font_size,
			min_value = 12, max_value = 96, step = 1, width = 220,
			id = skald.hash_id(ID_THEME_SIZE),
		),
		label_width = 120,
	))
	append(&rows, skald.form_row(ctx, "Font",
		skald.row(
			skald.text_input(
				ctx, s.font_family_draft, on_font_family_draft,
				placeholder = "default", width = 220,
				id = skald.hash_id(ID_THEME_FONT),
			),
			skald.button(ctx, "Apply", Msg(Overlay_Font_Committed{})),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		label_width = 120,
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.overlay_outline, "Dark outline behind the text",
		on_overlay_outline, id = skald.hash_id(ID_THEME_OUTLINE),
	))

	append(&rows, skald.spacer(th.spacing.xs))
	append(&rows, skald.text("Advanced — custom CSS", th.color.fg, th.font.size_sm))
	append(&rows, paragraph(ctx,
		"Added after everything above, so it overrides it. Selectors worth knowing: .widget-value and .widget-line for the individual sources, .overlay for the card, and the variables --gold, --gold-dim, --text, --text-dim, --red, --green.",
		th.color.fg_muted, th.font.size_xs,
	))
	append(&rows, skald.text_input(
		ctx, s.custom_css_draft, on_custom_css_draft,
		placeholder = ".widget-line { letter-spacing: 1px; }",
		multiline = true, wrap = true, min_lines = 3, max_lines = 10,
		id = skald.hash_id(ID_THEME_CSS),
	))
	append(&rows, skald.row(
		skald.button(ctx, "Apply CSS", Msg(Overlay_Css_Committed{})),
		skald.button(ctx, "Reset appearance", Msg(Overlay_Theme_Reset{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	return rows[:]
}

on_accent_picked :: proc(c: skald.Color) -> Msg {
	return Overlay_Accent_Set(color_to_hex(c))
}
on_text_color_picked :: proc(c: skald.Color) -> Msg {
	return Overlay_Text_Color_Set(color_to_hex(c))
}
on_font_size :: proc(v: f32) -> Msg { return Overlay_Font_Size_Set(int(v + 0.5)) }
on_overlay_outline :: proc(v: bool) -> Msg { return Overlay_Outline_Set(v) }
on_font_family_draft :: proc(v: string) -> Msg { return Overlay_Font_Draft(v) }
on_custom_css_draft :: proc(v: string) -> Msg { return Overlay_Css_Draft(v) }
