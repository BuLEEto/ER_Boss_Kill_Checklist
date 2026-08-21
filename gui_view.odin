package main

import "core:fmt"
import "core:strings"
import "gui:skald"

// ============================================================================
// Desktop GUI — view
//
// Pure: reads Gui + `app`, emits widgets. Every allocation here belongs to
// the frame arena (fmt.tprintf, context.temp_allocator) — see Skald's
// gotchas.md.
//
// Reads of `app` need no lock: the GUI thread is the only writer, and it
// isn't inside `update` while `view` runs.
// ============================================================================

gui_view :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Skald has no startup-command hook, so the first frame asks for the
	// poll loop to begin. `update` latches Gui.started so this fires once.
	if !s.started {
		append(ctx.msgs, Msg(Startup{}))
	}

	labels := TAB_LABELS
	body: skald.View
	switch s.tab {
	case .Setup:     body = view_setup(s, ctx)
	case .Checklist: body = view_checklist(s, ctx)
	case .OBS:       body = view_obs(s, ctx)
	case .About:     body = view_about(s, ctx)
	}

	return skald.col(
		skald.tabs(ctx, labels[:], int(s.tab), on_tab_selected),
		skald.divider(ctx),
		skald.flex(1, body),
		view_status_bar(s, ctx),
		// Both return an empty spacer when closed, so they cost nothing here.
		view_save_dialog(s, ctx),
		view_help_dialog(s, ctx),
		skald.toast(
			ctx,
			s.toast_on,
			s.toast_msg,
			on_toast_dismissed,
			kind = s.toast_kind,
			dismiss_after = 4,
		),
		spacing     = th.spacing.sm,
		padding     = th.spacing.md,
		cross_align = .Stretch,
	)
}


// ----------------------------------------------------------------------------
// Wrapping body text
//
// skald.text only word-wraps when handed an explicit max_width in pixels.
// `sized` looks like the answer — it defers the build until layout has
// assigned a rect — but it contributes no intrinsic height to a stack, so
// a column of them lays every following sibling on top of the text. It's
// for fill-mode widgets that are given a slot (scroll, table), not for
// content-sized prose.
//
// So measure instead. The renderer knows the window's logical width, and
// the chrome between it and a paragraph is all ours: the root column's
// padding, the scroll gutter, and the scrollbar. Recomputed every frame,
// so it tracks window resizes and the text-size setting for free.
// ----------------------------------------------------------------------------

// Room on the right for the scroll bar, which otherwise paints over the
// last few pixels of whatever the content put there — an Apply button, as
// it turned out.
SCROLL_GUTTER :: f32(14)

// Width available to prose inside a scrolling tab body.
content_width :: proc(ctx: ^skald.Ctx(Msg)) -> f32 {
	th := ctx.theme
	if ctx.renderer == nil do return 480 // headless / unit-test Ctx

	w := f32(ctx.renderer.fb_size.x)
	w -= th.spacing.md * 2   // root column padding
	w -= SCROLL_GUTTER * 2   // scroll content padding
	w -= SCROLL_GUTTER       // the scrollbar itself
	if w < 200 do w = 200
	return w
}

// `width` of 0 means "the width of a scrolling tab body". Anything inside
// a dialog must pass its own — a dialog card is far narrower than the
// window, and measuring the window would run the text off the card.
paragraph :: proc(
	ctx:   ^skald.Ctx(Msg),
	str:   string,
	color: skald.Color,
	size:  f32,
	width: f32 = 0,
) -> skald.View {
	w := width if width > 0 else content_width(ctx)
	return skald.text(str, color, size, max_width = w)
}

// Stable widget ids.
//
// Skald keys retained widget state (focus, open, pressed) off an
// auto-generated call-site counter. A `select` builds its option rows only
// while the dropdown is open, so opening one shifts the auto-id of every
// widget built after it — and conditional rows (an error alert, the
// overlay controls that only appear when the server is up) shift them
// again. Either way the state read next frame belongs to a different
// widget, which shows up as controls that misfire.
//
// Skald's documented remedy is an explicit id from `hash_id`, which lands
// in a reserved high range that auto-ids never touch. Everything stateful
// on the Setup and OBS tabs gets one.
ID_CHARACTER      :: "setup.character"
ID_BOSS_LIST      :: "setup.boss_list"
ID_POLL_RATE      :: "setup.poll_rate"
ID_THEME          :: "setup.theme"
ID_UI_SCALE       :: "setup.ui_scale"
ID_SERVER_TOGGLE  :: "obs.server"
ID_PORT           :: "obs.port"
ID_OVERLAY_MODE   :: "obs.overlay_mode"
ID_OVERLAY_COUNT  :: "obs.overlay_count"
ID_OVERLAY_REGION :: "obs.overlay_region"
ID_ROOMY_LINES    :: "obs.roomy_lines"
ID_WS_ROOMY       :: "obs.ws_roomy"
ID_OVERLAY_ALIGN  :: "obs.overlay_align"
ID_SOURCE_STYLE   :: "obs.source_style"
ID_OBS_TAB        :: "obs.subtab"
ID_THEME_ACCENT   :: "obs.theme_accent"
ID_THEME_TEXT     :: "obs.theme_text"
ID_THEME_SIZE     :: "obs.theme_size"
ID_THEME_FONT     :: "obs.theme_font"
ID_THEME_OUTLINE  :: "obs.theme_outline"
ID_THEME_CSS      :: "obs.theme_css"
ID_OVERLAY_BG     :: "obs.overlay_bg"
ID_SHOW_DEATHS    :: "obs.show_deaths"
ID_SHOW_ATTEMPTS  :: "obs.show_attempts"
ID_SHOW_SESSION   :: "obs.show_session"
ID_KILL_BANNER    :: "obs.kill_banner"
ID_BANNER_SECS    :: "obs.banner_secs"
ID_WS_SCENE       :: "obs.ws_scene"
ID_WIDGET_URLS    :: "obs.widget_urls"
ID_TEXT_TOGGLE    :: "obs.text_enabled"
ID_TEXT_DIR       :: "obs.text_dir"
ID_WS_TOGGLE      :: "obs.ws_enabled"
ID_WS_HOST        :: "obs.ws_host"
ID_WS_PORT        :: "obs.ws_port"
ID_WS_PASS        :: "obs.ws_pass"
ID_WS_REMEMBER    :: "obs.ws_remember"
ID_HIDE_COMPLETED :: "checklist.hide_completed"
ID_RESET_ATTEMPTS :: "checklist.reset_attempts"
ID_RESET_SESSION  :: "checklist.reset_session"

// ----------------------------------------------------------------------------
// Setup tab
// ----------------------------------------------------------------------------

view_setup :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, skald.section_header(ctx, "Save file"))

	if len(app.settings.save_path) == 0 {
		append(&rows, paragraph(ctx,
			"No save file selected yet.",
			th.color.fg_muted, th.font.size_sm,
		))
	} else {
		append(&rows, paragraph(ctx, app.settings.save_path, th.color.fg_muted, th.font.size_sm))
	}

	if len(app.save_error) > 0 {
		append(&rows, skald.alert(ctx, app.save_error, tone = .Danger))
	}

	append(&rows, skald.row(
		skald.button(ctx,
			len(app.settings.save_path) == 0 ? "Choose save file…" : "Change save file…",
			Msg(Save_Dialog_Opened{}),
			bg = th.color.primary, fg = th.color.on_primary),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	// -- Character ----------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Character"))

	if !app.save_loaded {
		append(&rows, skald.text("Load a save file first.", th.color.fg_muted, th.font.size_sm))
	} else {
		names := make([dynamic]string, context.temp_allocator)
		for sl in app.slots {
			if !sl.active do continue
			append(&names, fmt.tprintf("%d — %s (RL %d)", sl.index + 1, sl.name, sl.level))
		}
		if len(names) == 0 {
			append(&rows, skald.text(
				"That save has no active characters.", th.color.danger, th.font.size_sm,
			))
		} else {
			append(&rows, skald.select(
				ctx, active_slot_label(ctx), names[:], on_slot_selected, width = 320,
				placeholder = "Pick a character", id = skald.hash_id(ID_CHARACTER),
			))
		}
	}

	// -- Boss list ----------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Boss list"))
	append(&rows, skald.select(
		ctx,
		boss_list_label(app.boss_list_type),
		boss_list_labels(),
		on_boss_list_selected,
		width = 320,
		id = skald.hash_id(ID_BOSS_LIST),
	))

	// -- Options ------------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Options"))

	append(&rows, skald.form_row(ctx,
		fmt.tprintf("Check every %ds", app.settings.poll_seconds),
		skald.slider(
			ctx, f32(app.settings.poll_seconds), on_poll_rate,
			min_value = POLL_SECONDS_MIN, max_value = POLL_SECONDS_MAX,
			step = 1, width = 240, id = skald.hash_id(ID_POLL_RATE),
		),
		label_width = 160,
	))
	append(&rows, skald.form_row(ctx, "Theme",
		skald.select(
			ctx, theme_label(app.settings.theme), theme_labels(),
			on_theme_selected, width = 200, id = skald.hash_id(ID_THEME),
		),
		label_width = 160,
	))
	append(&rows, skald.form_row(ctx, "Text size",
		skald.select(
			ctx, ui_scale_label(app.settings.ui_scale), ui_scale_labels(),
			on_ui_scale_selected, width = 200, id = skald.hash_id(ID_UI_SCALE),
		),
		label_width = 160,
	))

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		padding     = SCROLL_GUTTER,
		cross_align = .Stretch,
	))
}

// The save picker, as a modal. It used to be a list that unfolded inline
// on the Setup tab, which shoved everything below it down the page and
// left choosing a character as a separate second step.
// The save picker, as a modal. It used to be a list that unfolded inline
// on the Setup tab, which shoved everything below it down the page and
// left choosing a character as a separate second step.
view_save_dialog :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	body: skald.View
	switch {
	case s.scanning:
		body = skald.col(
			skald.spacer(th.spacing.lg),
			skald.row(
				skald.spinner(ctx, size = 18),
				skald.text("Searching Steam libraries…", th.color.fg_muted, th.font.size_md),
				spacing     = th.spacing.sm,
				cross_align = .Center,
			),
			skald.spacer(th.spacing.xs),
			skald.text(
				"Including Proton prefixes, Flatpak Steam and Seamless Co-op.",
				th.color.fg_muted, th.font.size_xs,
			),
			skald.spacer(th.spacing.lg),
			height      = 380,
			main_align  = .Center,
			cross_align = .Center,
		)

	case len(s.scan_results) == 0:
		body = skald.col(
			skald.empty_state(
				ctx,
				"No Elden Ring saves found",
				"Nothing turned up in your Steam libraries. Use Browse… to point at an ER0000.sl2, .co2 or .rd2 yourself.",
			),
			height      = 380,
			main_align  = .Center,
			cross_align = .Stretch,
		)

	case:
		// Zero width means "fill the slot my parent gives me" — the
		// dialog's content column stretches, so the viewport tracks the
		// card's real inner width. Hardcoding it overflowed the
		// scrollbar and clipped the right-hand column.
		body = skald.scroll(ctx, {0, 380}, view_save_list(s, ctx))
	}

	return skald.dialog(
		ctx,
		open = s.save_dialog_open,
		on_dismiss = on_save_dialog_closed,
		width = 720,
		max_width = 760,
		content = skald.col(
			skald.text("Choose a save file", th.color.fg, th.font.size_lg),
			skald.text(
				"Pick a character to start tracking it.",
				th.color.fg_muted, th.font.size_sm,
			),
			skald.spacer(th.spacing.md),
			body,
			skald.spacer(th.spacing.md),
			skald.row(
				skald.button(ctx, "Rescan", Msg(Scan_Requested{})),
				skald.button(ctx, "Browse…", Msg(Browse_Requested{})),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Save_Dialog_Closed{})),
				spacing     = th.spacing.sm,
				cross_align = .Center,
			),
			spacing     = 0,
			cross_align = .Stretch,
		),
	)
}

view_save_list :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	cards := make([dynamic]skald.View, context.temp_allocator)

	for found, save_idx in s.scan_results {
		is_current := found.path == app.settings.save_path
		rows := make([dynamic]skald.View, context.temp_allocator)

		append(&rows, skald.row(
			skald.text(found.filename, th.color.fg, th.font.size_md),
			skald.badge(ctx, fmt.tprintf("AppID %s", found.app_id), tone = .Neutral),
			is_current \
				? skald.badge(ctx, "in use", tone = .Success) \
				: skald.spacer(0),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		))
		append(&rows, skald.text(
			elide_start(found.path, 78), th.color.fg_muted, th.font.size_xs,
		))
		append(&rows, skald.spacer(th.spacing.xs))

		if len(found.characters) == 0 {
			// Either an empty save or one the quick look couldn't read.
			// Offer it anyway — the full parser may manage.
			append(&rows, skald.clickable(
				ctx,
				skald.row(
					skald.text(
						"No characters found — use this file anyway",
						th.color.fg_muted, th.font.size_sm,
					),
					padding     = th.spacing.sm,
					cross_align = .Center,
				),
				Msg(Scan_Result_Picked(save_idx)),
			))
		} else {
			for c in found.characters {
				selected := is_current && c.index == app.settings.active_slot
				append(&rows, skald.clickable(
					ctx,
					skald.row(
						skald.text(selected ? "◆" : "◇", th.color.fg_muted, th.font.size_sm),
						skald.text(c.name, th.color.fg, th.font.size_md),
						skald.flex(1, skald.spacer(0)),
						skald.text(
							fmt.tprintf("RL %d", c.level), th.color.fg_muted, th.font.size_sm,
						),
						skald.spacer(th.spacing.sm),
						skald.text(
							fmt.tprintf("slot %d", c.index + 1),
							th.color.fg_muted, th.font.size_xs,
						),
						spacing     = th.spacing.sm,
						padding     = th.spacing.sm,
						bg          = selected ? th.color.selection : skald.Color{},
						radius      = th.radius.sm,
						cross_align = .Center,
					),
					Msg(Save_Character_Picked{save = save_idx, slot = c.index}),
				))
			}
		}

		append(&cards, skald.col(
			..rows[:],
			spacing     = 2,
			padding     = th.spacing.sm,
			bg          = th.color.surface,
			radius      = th.radius.md,
			cross_align = .Stretch,
		))
	}

	return skald.col(
		..cards[:],
		spacing     = th.spacing.sm,
		padding     = th.spacing.xs,
		cross_align = .Stretch,
	)
}

// Trim a long path from the front, keeping the tail — the Steam ID and
// filename at the end are what tell two saves apart, the leading
// /home/user/.steam/... is the same on every row.
elide_start :: proc(path: string, max_chars: int) -> string {
	if len(path) <= max_chars do return path
	return fmt.tprintf("…%s", path[len(path) - max_chars:])
}

// ----------------------------------------------------------------------------
// Checklist tab
// ----------------------------------------------------------------------------

view_checklist :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	if !app.save_loaded || app.settings.active_slot < 0 {
		return skald.empty_state(
			ctx,
			"Nothing tracked yet",
			"Pick a save file and a character on the Setup tab.",
			skald.button(ctx, "Go to Setup", Msg(Tab_Selected(int(Tab.Setup))),
				bg = th.color.primary, fg = th.color.on_primary),
		)
	}

	total, killed := count_bosses(app.regions)
	name, level := app_active_character()
	fraction := total > 0 ? f32(killed) / f32(total) : 0

	header := skald.col(
		skald.row(
			skald.text(
				len(name) > 0 ? fmt.tprintf("%s — RL %d", name, level) : "Unknown character",
				th.color.fg, th.font.size_lg,
			),
			skald.flex(1, skald.spacer(0)),
			skald.text(
				fmt.tprintf("%d / %d  (%d left)", killed, total, total - killed),
				th.color.fg, th.font.size_lg,
			),
			cross_align = .Center,
		),
		skald.progress(ctx, fraction, height = 8),
		skald.row(
			skald.text(
				fmt.tprintf("Deaths: %d", app.death_count), th.color.fg_muted, th.font.size_sm,
			),
			skald.flex(1, skald.spacer(0)),
			skald.text(boss_list_label(app.boss_list_type), th.color.fg_muted, th.font.size_sm),
			cross_align = .Center,
		),
		// The two counters the OBS sources publish, where someone can see
		// what's actually going out and put either one back to zero.
		skald.row(
			skald.text(counters_text(), th.color.fg_muted, th.font.size_sm),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Reset attempts", Msg(Attempts_Reset{}),
				id = skald.hash_id(ID_RESET_ATTEMPTS)),
			skald.button(ctx, "Reset session", Msg(Session_Reset{}),
				id = skald.hash_id(ID_RESET_SESSION)),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		spacing     = th.spacing.xs,
		cross_align = .Stretch,
	)

	controls := skald.row(
		skald.button(ctx, "Expand all", Msg(Expand_All(true))),
		skald.button(ctx, "Collapse all", Msg(Expand_All(false))),
		skald.flex(1, skald.spacer(0)),
		skald.checkbox(ctx, app.settings.hide_completed, "Hide cleared regions", on_hide_completed,
			id = skald.hash_id(ID_HIDE_COMPLETED)),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	)

	sections := make([dynamic]skald.View, context.temp_allocator)
	shown := 0
	for &r, i in app.regions {
		r_total, r_killed := count_region_bosses(&r)
		complete := r_killed == r_total
		if app.settings.hide_completed && complete do continue
		shown += 1
		append(&sections, view_region(s, ctx, i, &r, r_total, r_killed, complete))
	}

	list: skald.View
	if shown == 0 {
		list = skald.empty_state(
			ctx, "Every region cleared", "Uncheck \"Hide cleared regions\" to see them again.",
		)
	} else {
		list = skald.scroll(ctx, {0, 0}, skald.col(
			..sections[:],
			spacing     = th.spacing.xs,
			cross_align = .Stretch,
		))
	}

	return skald.col(
		header,
		controls,
		skald.flex(1, list),
		spacing     = th.spacing.sm,
		cross_align = .Stretch,
	)
}

view_region :: proc(
	s: Gui,
	ctx: ^skald.Ctx(Msg),
	index: int,
	region: ^Region,
	total, killed: int,
	complete: bool,
) -> skald.View {
	th := ctx.theme
	open := index < len(s.expanded) && s.expanded[index]

	header := skald.row(
		skald.text(open ? "▼" : "▶", th.color.fg_muted, th.font.size_sm),
		skald.text(region.region_name, complete ? th.color.fg_muted : th.color.fg, th.font.size_md),
		skald.flex(1, skald.spacer(0)),
		skald.badge(
			ctx,
			fmt.tprintf("%d/%d", killed, total),
			tone = complete ? .Success : .Neutral,
		),
		spacing     = th.spacing.sm,
		padding     = th.spacing.xs,
		cross_align = .Center,
	)

	if !open {
		return skald.clickable(ctx, header, Msg(Region_Toggled(index)))
	}

	boss_rows := make([dynamic]skald.View, context.temp_allocator)
	for &b in region.bosses {
		if app.settings.hide_completed && b.killed do continue

		marker := b.killed ? "✔" : "•" // ✔ / •
		colour := b.killed ? th.color.success : th.color.fg
		name := b.boss
		if b.difficulty > 0 {
			name = fmt.tprintf("[%d] %s", b.difficulty, b.boss)
		}

		append(&boss_rows, skald.row(
			skald.text(marker, colour, th.font.size_sm),
			skald.text(name, b.killed ? th.color.fg_muted : th.color.fg, th.font.size_sm),
			skald.flex(1, skald.spacer(0)),
			skald.text(b.place, th.color.fg_muted, th.font.size_xs),
			spacing     = th.spacing.sm,
			padding     = 2,
			cross_align = .Center,
		))
	}

	body: skald.View = skald.text("Nothing left here.", th.color.fg_muted, th.font.size_xs)
	if len(boss_rows) > 0 {
		body = skald.col(..boss_rows[:], spacing = 0, cross_align = .Stretch)
	}

	return skald.col(
		skald.clickable(ctx, header, Msg(Region_Toggled(index))),
		skald.col(body, padding = th.spacing.sm, cross_align = .Stretch),
		spacing     = 0,
		cross_align = .Stretch,
	)
}

// ----------------------------------------------------------------------------
// OBS tab
// ----------------------------------------------------------------------------

view_obs :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	labels := OBS_TAB_LABELS
	panel: skald.View
	switch s.obs_tab {
	case .Browser:   panel = view_obs_browser(s, ctx)
	case .Text:      panel = view_obs_text(s, ctx)
	case .Setup:     panel = view_obs_setup(s, ctx)
	}

	// A segmented control rather than another tab strip: nesting tabs
	// inside tabs reads as one confused row of six, where this reads as a
	// choice within the OBS tab.
	return skald.col(
		skald.segmented(
			ctx, labels[:], int(s.obs_tab), on_obs_tab, id = skald.hash_id(ID_OBS_TAB),
		),
		skald.spacer(th.spacing.sm),
		skald.flex(1, panel),
		spacing     = 0,
		cross_align = .Stretch,
	)
}

// ---------------------------------------------------------------------------
// Browser source
//
// The overlay page, plus everything about how it looks. Appearance lives
// here rather than in its own panel because this is the integration it
// most obviously belongs to — with a note for the case where it also
// applies, which is the web-style obs-websocket sources.
// ---------------------------------------------------------------------------

view_obs_browser :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	running := server_is_running(&app.server)

	append(&rows, help_row(ctx,
		"OBS renders the overlay page directly. The best-looking option, and the only one where alignment and spacing work properly.",
		.Browser_Source,
	))

	append(&rows, skald.row(
		skald.toggle(ctx, app.settings.server_enabled, "Run the web server", on_server_set,
			id = skald.hash_id(ID_SERVER_TOGGLE)),
		skald.flex(1, skald.spacer(0)),
		skald.text("Port", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.port_draft, on_port_draft, width = 90,
			id = skald.hash_id(ID_PORT)),
		skald.button(ctx, "Apply", Msg(Port_Committed{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	if server_err := server_error_text(&app.server); len(server_err) > 0 {
		append(&rows, skald.alert(ctx, server_err, tone = .Danger))
	} else if running {
		append(&rows, skald.text(
			fmt.tprintf("Listening on port %d", app.server.port), th.color.success, th.font.size_sm,
		))
	} else {
		// The settings below stay visible with the server off. Hiding
		// them meant a control could vanish mid-edit, and they're still
		// worth setting — the mobile page and the text files read some of
		// the same values.
		append(&rows, skald.text(
			"Server stopped — the overlay and mobile pages won't load until it's running.",
			th.color.fg_muted, th.font.size_sm,
		))
	}

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "What it shows"))

	append(&rows, skald.form_row(ctx, "Overlay",
		skald.segmented(
			ctx, {"Summary", "Next up", "Region"},
			overlay_mode_index(app.settings.overlay_mode), on_overlay_mode,
			id = skald.hash_id(ID_OVERLAY_MODE),
		),
		label_width = 120,
	))

	if app.settings.overlay_mode == "next" {
		append(&rows, skald.form_row(ctx,
			fmt.tprintf("Show %d bosses", app.settings.overlay_next_count),
			skald.slider(
				ctx, f32(app.settings.overlay_next_count), on_overlay_count,
				min_value = 1, max_value = 25, step = 1, width = 220,
				id = skald.hash_id(ID_OVERLAY_COUNT),
			),
			label_width = 120,
		))
	}

	for v in view_region_control(ctx, .Browser, "browser.region") do append(&rows, v)

	append(&rows, skald.checkbox(
		ctx, app.settings.show_deaths, "Include death count", on_show_deaths,
		id = skald.hash_id(ID_SHOW_DEATHS),
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.show_attempts, "Include attempt counter", on_show_attempts,
		id = skald.hash_id(ID_SHOW_ATTEMPTS),
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.show_session, "Include session totals", on_show_session,
		id = skald.hash_id(ID_SHOW_SESSION),
	))

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Boss defeated banner"))
	append(&rows, skald.checkbox(
		ctx, app.settings.kill_banner_enabled,
		"Announce kills on the overlay", on_kill_banner,
		id = skald.hash_id(ID_KILL_BANNER),
	))
	if app.settings.kill_banner_enabled {
		append(&rows, skald.form_row(ctx,
			fmt.tprintf("Hold %d seconds", app.settings.kill_banner_seconds),
			skald.slider(
				ctx, f32(app.settings.kill_banner_seconds), on_kill_banner_secs,
				min_value = f32(KILL_BANNER_SECONDS_MIN),
				max_value = f32(KILL_BANNER_SECONDS_MAX),
				step = 1, width = 220,
				id = skald.hash_id(ID_BANNER_SECS),
			),
			label_width = 120,
		))
	}
	append(&rows, paragraph(ctx,
		"Names the boss on the overlay for a few seconds, then goes back to the numbers. It sits at the bottom of the browser source, so give that source some height below the card or the two will overlap. Only the overlay can do this — a text source has nowhere to put it. Uses this panel's Appearance colours.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.form_row(ctx, "Background",
		skald.segmented(
			ctx, {"Transparent", "Green", "Magenta"},
			overlay_bg_index(app.settings.overlay_bg), on_overlay_bg,
			id = skald.hash_id(ID_OVERLAY_BG),
		),
		label_width = 120,
	))
	append(&rows, paragraph(ctx,
		"Transparent works with a Browser Source. Use a chroma key colour only if you're capturing a window instead.",
		th.color.fg_muted, th.font.size_xs,
	))

	looks := view_appearance(s, ctx, .Browser, "browser",
		"How the overlay card looks. The single-value pages below have their own.")
	for v in looks do append(&rows, v)

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, paragraph(ctx,
		"Sources → + → Browser in OBS, then paste this into the URL field.",
		th.color.fg_muted, th.font.size_xs,
	))
	append(&rows, view_copy_row(ctx, "Overlay URL", overlay_url_string(context.temp_allocator)))
	append(&rows, view_copy_row(ctx, "Mobile view", mobile_url_string(context.temp_allocator)))

	// ---- One value per source -------------------------------------------
	//
	// The same pages obs-websocket creates when it makes browser sources.
	// They were previously reachable only by letting the app create them,
	// which made a whole capability look like it belonged to a protocol it
	// has nothing to do with. They're just URLs; here they are.
	append(&rows, skald.spacer(th.spacing.md))
	append(&rows, skald.section_header(ctx, "One value per source"))
	append(&rows, paragraph(ctx,
		"For a layout where the numbers live in different corners rather than in one card. Each is its own Browser source, so you position and size them separately in OBS. Add only the ones you want — each costs a browser instance.",
		th.color.fg_muted, th.font.size_xs,
	))

	url_rows := make([dynamic]skald.View, context.temp_allocator)
	for kind in Obs_Source {
		// The overlay is the card above, not a single value.
		if kind == .Overlay do continue
		append(&url_rows, view_copy_row(
			ctx, obs_source_short_label(kind),
			widget_url_string(kind, context.temp_allocator),
		))
	}
	append(&rows, skald.collapsible(
		ctx, fmt.tprintf("Show the %d URLs", len(url_rows)), s.widget_urls_open,
		on_widget_urls_toggled,
		skald.col(..url_rows[:], spacing = th.spacing.xs, cross_align = .Stretch),
		id = skald.hash_id(ID_WIDGET_URLS),
	))

	for v in view_region_control(ctx, .Widget, "browser.widget.region") do append(&rows, v)
	widget_looks := view_appearance(s, ctx, .Widget, "browser.widget",
		"How the single-value pages look. Shared with anything the Set up OBS panel creates as a browser source — they're the same pages.")
	for v in widget_looks do append(&rows, v)

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		padding     = SCROLL_GUTTER,
		cross_align = .Stretch,
	))
}

// ---------------------------------------------------------------------------
// Text files
// ---------------------------------------------------------------------------

view_obs_text :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, help_row(ctx,
		"Plain text files you point OBS \"Text (GDI+/FreeType)\" sources at with \"Read from file\". No browser source, no CPU cost, works on any OBS version.",
		.Text_Files,
	))
	append(&rows, skald.toggle(
		ctx, app.settings.obs_text_enabled, "Write text files", on_obs_text_set,
		id = skald.hash_id(ID_TEXT_TOGGLE),
	))
	append(&rows, skald.row(
		skald.flex(1, skald.text_input(
			ctx, s.obs_text_dir_draft, on_obs_text_dir,
			placeholder = obs_text_default_dir(context.temp_allocator),
			id = skald.hash_id(ID_TEXT_DIR),
		), min_main = 240),
		skald.button(ctx, "Browse…", Msg(Obs_Text_Dir_Browse{})),
		skald.button(ctx, "Apply", Msg(Obs_Text_Dir_Committed{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	append(&rows, skald.spacer(th.spacing.sm))
	for v in view_region_control(ctx, .Text, "text.region") do append(&rows, v)

	append(&rows, skald.checkbox(
		ctx, app.settings.text_roomy_lines, "Blank line between entries in the multi-line files",
		false, on_roomy_lines, id = skald.hash_id(ID_ROOMY_LINES),
	))
	append(&rows, paragraph(ctx,
		"OBS text sources have no line-height setting, so the only way to loosen a list up is to send the extra line.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "The files"))
	files := OBS_TEXT_FILES
	for f in files {
		append(&rows, skald.row(
			skald.text(f.name, th.color.fg, th.font.size_sm),
			skald.flex(1, skald.spacer(0)),
			skald.text(f.description, th.color.fg_muted, th.font.size_xs),
			spacing     = th.spacing.sm,
			padding     = 2,
			cross_align = .Center,
		))
	}

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		padding     = SCROLL_GUTTER,
		cross_align = .Stretch,
	))
}

// ---------------------------------------------------------------------------
// obs-websocket
// ---------------------------------------------------------------------------

view_obs_setup :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, help_row(ctx,
		"Optional. This creates and positions the sources in OBS for you instead of you adding each one by hand. It doesn't show anything the Browser source panel can't — it just saves the clicking. Needs OBS's WebSocket server on, under Tools → WebSocket Server Settings.",
		.Obs_Websocket,
	))
	append(&rows, skald.toggle(ctx, app.settings.obsws_enabled, "Let the app set up OBS", on_obsws_set,
		id = skald.hash_id(ID_WS_TOGGLE)))
	append(&rows, skald.row(
		skald.text("Host", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_host_draft, on_obsws_host, width = 160,
			id = skald.hash_id(ID_WS_HOST)),
		skald.text("Port", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_port_draft, on_obsws_port, width = 90,
			id = skald.hash_id(ID_WS_PORT)),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))
	append(&rows, skald.row(
		skald.text("Password", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_pass_draft, on_obsws_pass, width = 220, password = true,
			id = skald.hash_id(ID_WS_PASS)),
		skald.button(ctx, "Connect", Msg(Obsws_Connect_Requested{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.obsws_remember_password,
		"Remember the password (encrypted, tied to this machine)",
		on_obsws_remember, id = skald.hash_id(ID_WS_REMEMBER),
	))

	status, state := obsws_status_text()
	status_colour := th.color.fg_muted
	switch state {
	case .Connected: status_colour = th.color.success
	case .Failed:    status_colour = th.color.danger
	case .Connecting, .Disconnected: // muted
	}
	append(&rows, skald.text(status, status_colour, th.font.size_sm))

	// Scene picker. Populated from OBS, so it only has real names once
	// we've connected at least once.
	scenes := obsws_scene_names()
	chosen := app.settings.obsws_scene
	scene_value := len(chosen) > 0 ? chosen : OBSWS_SCENE_NONE_LABEL

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.form_row(ctx, "Add to scene",
		skald.select(
			ctx, scene_value, scenes, on_obsws_scene,
			width = 280, placeholder = OBSWS_SCENE_NONE_LABEL,
			id = skald.hash_id(ID_WS_SCENE),
		),
		label_width = 120,
	))

	// Nothing is created until a scene is picked, so say so where the
	// choice is rather than leaving someone waiting for sources that are
	// never coming.
	switch {
	case len(scenes) == 0:
		append(&rows, paragraph(ctx,
			"Connect and your scenes will be listed here. No sources are created until you pick one.",
			th.color.fg_muted, th.font.size_xs,
		))
	case len(chosen) == 0:
		append(&rows, paragraph(ctx,
			"Pick the scene the sources should go in. Nothing is created until you do — otherwise they'd land in whichever scene happened to be live when the app connected, which is a nasty surprise if that was your Starting Soon scene.",
			th.color.warning, th.font.size_xs,
		))
	case:
		append(&rows, paragraph(ctx,
			fmt.tprintf(
				"New sources are created in %s. Change it and the app reconnects and adds them to the new scene; the copies in the old one are left alone, so delete those in OBS if you don't want them.",
				chosen,
			),
			th.color.fg_muted, th.font.size_xs,
		))
	}

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "What to create"))
	append(&rows, skald.form_row(ctx, "As",
		skald.segmented(
			ctx, {"Browser sources", "Text sources"},
			app.settings.obsws_source_style == "web" ? 0 : 1, on_obs_source_style,
			id = skald.hash_id(ID_SOURCE_STYLE),
		),
		label_width = 120,
	))
	append(&rows, paragraph(ctx,
		app.settings.obsws_source_style == "web" \
			? "Creates the same single-value pages the Browser source panel hands out URLs for — so they're styled by the same Appearance settings, and alignment and line height work. Costs a browser instance per source." \
			: "Creates OBS text sources instead. Much lighter — no browser instance — but OBS gives text sources no alignment and no line height, and they're styled in OBS rather than here.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.spacer(th.spacing.xs))
	for kind in Obs_Source {
		append(&rows, skald.checkbox(
			ctx, obs_source_enabled(kind), obs_source_label(kind),
			kind, on_obs_source_toggled,
			id = skald.hash_id(obs_source_name(kind)),
		))
	}
	append(&rows, paragraph(ctx,
		"Only the ticked ones are created. Unticking hides the source in OBS rather than deleting it, so anything you've styled survives — re-tick to bring it back.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.spacer(th.spacing.sm))
	for v in view_region_control(ctx, .Widget, "ws.region") do append(&rows, v)
	append(&rows, skald.checkbox(
		ctx, app.settings.ws_roomy_lines, "Blank line between entries in the multi-line sources",
		true, on_roomy_lines, id = skald.hash_id(ID_WS_ROOMY),
	))

	if app.settings.obsws_source_style == "web" {
		// The same controls as the Browser source panel, deliberately
		// repeated rather than cross-referenced: they're one setting, and
		// being told to go and look at another tab to restyle what you're
		// looking at is exactly the shuffle this tab used to demand.
		looks := view_appearance(s, ctx, .Widget, "ws",
			"How the single-value pages look. The same setting as on the Browser source panel — these are the same pages.")
		for v in looks do append(&rows, v)
	}

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		padding     = SCROLL_GUTTER,
		cross_align = .Stretch,
	))
}

view_copy_row :: proc(ctx: ^skald.Ctx(Msg), label, value: string) -> skald.View {
	th := ctx.theme
	return skald.form_row(ctx, label,
		skald.row(
			skald.flex(1, skald.text_selectable(ctx, value, th.color.fg, th.font.size_sm), min_main = 200),
			skald.button(ctx, "Copy", Msg(Copy_Requested(value))),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		),
		label_width = 120,
	)
}

// ----------------------------------------------------------------------------
// About tab
// ----------------------------------------------------------------------------

view_about :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	config, _ := settings_path(context.temp_allocator)

	return skald.scroll(ctx, {0, 0}, skald.col(
		skald.text("Elden Ring Boss Checklist", th.color.fg, th.font.size_xl),
		skald.text(APP_VERSION, th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.sm),
		skald.text(
			"Reads your save file read-only to track which bosses you've beaten. It never writes to the save, so it's safe alongside EAC.",
			th.color.fg_muted, th.font.size_sm,
		),
		skald.spacer(th.spacing.sm),
		skald.section_header(ctx, "Settings"),
		view_copy_row(ctx, "Config file", config),
		skald.spacer(th.spacing.sm),
		skald.section_header(ctx, "Credits"),
		skald.text(
			"GUI by Skald (zlib) · SDL3 (zlib) · Inter typeface (SIL OFL 1.1)",
			th.color.fg_muted, th.font.size_sm,
		),
		// Reproduced verbatim: this is the attribution the bundled font's
		// own notice designates, and CC-BY requires the one the licensor
		// specified. "Twitter, Inc." is the copyright holder named when
		// the artwork was licensed — the 2023 rename to X Corp doesn't
		// change an attribution already fixed by the licence, and the
		// project is community-maintained now in any case.
		skald.text(
			"Twemoji by Twitter, Inc. and contributors — CC-BY 4.0 — https://twemoji.twitter.com",
			th.color.fg_muted, th.font.size_sm,
		),
		skald.text(
			"Save format research: ClayAmore, Hapfel, The Grand Archives, and the Souls modding community. Full credits in THIRD_PARTY.md.",
			th.color.fg_muted, th.font.size_sm,
		),
		spacing     = th.spacing.xs,
		cross_align = .Stretch,
	))
}

// ----------------------------------------------------------------------------
// Status bar
// ----------------------------------------------------------------------------

view_status_bar :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	left := "No save loaded"
	if app.save_loaded {
		name, level := app_active_character()
		left = len(name) > 0 \
			? fmt.tprintf("%s · RL %d", name, level) \
			: "Save loaded — no character selected"
	}

	right := server_is_running(&app.server) \
		? fmt.tprintf("Web server on :%d", app.server.port) \
		: "Web server off"

	return skald.row(
		skald.text(left, th.color.fg_muted, th.font.size_xs),
		skald.flex(1, skald.spacer(0)),
		skald.text(right, th.color.fg_muted, th.font.size_xs),
		cross_align = .Center,
	)
}

// ----------------------------------------------------------------------------
// URL building
// ----------------------------------------------------------------------------

// The URL for one single-value page.
//
// Shared with obs-websocket rather than built twice: when the app creates
// a browser source it points it at exactly the URL the Copy button hands
// out, so a source you made yourself and one the app made are the same
// thing. Two builders would have drifted the first time either changed.
widget_url_string :: proc(kind: Obs_Source, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"http://localhost:%d/widget?type=%s&align=%s",
		app.server.port, obs_source_widget(kind), app.settings.ws_look.align,
		allocator = allocator,
	)
}

overlay_url_string :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "http://localhost:%d/overlay?mode=%s",
		app.server.port, app.settings.overlay_mode)
	if app.settings.overlay_mode == "next" {
		fmt.sbprintf(&b, "&count=%d", app.settings.overlay_next_count)
	}
	// A pinned region goes into the URL so the browser source shows the
	// same area even though the page can't see our settings. The
	// automatic modes deliberately don't: leaving the parameter off makes
	// the server resolve it on every request, so the page keeps following
	// along instead of freezing on whichever area was current when the
	// URL was copied.
	if app.settings.overlay_mode == "region" &&
	   len(app_pinned_region_name(app.settings.browser_region)) > 0 {
		if idx := app_focus_region(app.settings.browser_region); idx >= 0 {
			fmt.sbprintf(&b, "&region=%d", idx)
		}
	}
	if app.settings.overlay_bg != "none" {
		fmt.sbprintf(&b, "&bg=%s", app.settings.overlay_bg)
	}
	if app.settings.browser_look.align != "left" {
		fmt.sbprintf(&b, "&align=%s", app.settings.browser_look.align)
	}
	if app.settings.show_deaths {
		strings.write_string(&b, "&deaths=true")
	}
	return strings.to_string(b)
}

mobile_url_string :: proc(allocator := context.allocator) -> string {
	host := len(app.lan_ip) > 0 ? app.lan_ip : "localhost"
	return fmt.aprintf("http://%s:%d/mobile", host, app.server.port, allocator = allocator)
}

// ----------------------------------------------------------------------------
// Small view helpers
// ----------------------------------------------------------------------------

// The attempts and session line under the checklist progress bar.
counters_text :: proc() -> string {
	session := fmt.tprintf("Session: %s", session_summary())
	n, ok := app_attempts()
	if !ok do return session
	return fmt.tprintf("Attempt %d  ·  %s", n, session)
}

boss_list_labels :: proc() -> []string {
	out := make([]string, len(Boss_List_Type), context.temp_allocator)
	for t, i in Boss_List_Type {
		out[i] = boss_list_label(t)
	}
	return out
}

active_slot_label :: proc(ctx: ^skald.Ctx(Msg)) -> string {
	slot := app.settings.active_slot
	if slot < 0 || slot >= len(app.slots) do return ""
	s := app.slots[slot]
	return fmt.tprintf("%d — %s (RL %d)", s.index + 1, s.name, s.level)
}

overlay_mode_index :: proc(mode: string) -> int {
	switch mode {
	case "next":   return 1
	case "region": return 2
	case:          return 0
	}
}

overlay_bg_index :: proc(bg: string) -> int {
	switch bg {
	case "green":   return 1
	case "magenta": return 2
	case:           return 0
	}
}

// ----------------------------------------------------------------------------
// Widget callbacks
//
// Skald's callbacks are plain procs, not closures — anything row-specific
// goes through a Msg value (see `clickable`) rather than a captured index.
// ----------------------------------------------------------------------------

on_tab_selected :: proc(i: int) -> Msg { return Tab_Selected(i) }
on_obs_tab :: proc(i: int) -> Msg { return Obs_Tab_Selected(i) }
on_toast_dismissed :: proc() -> Msg { return Toast_Dismissed{} }
on_save_dialog_closed :: proc() -> Msg { return Save_Dialog_Closed{} }

on_slot_selected :: proc(label: string) -> Msg {
	// Labels are "<n> — <name> (RL <level>)"; the leading number is the
	// slot index as the user sees it, so subtract the 1 we added.
	n := 0
	for c in label {
		if c < '0' || c > '9' do break
		n = n * 10 + int(c - '0')
	}
	return Slot_Selected(n - 1)
}

on_boss_list_selected :: proc(label: string) -> Msg {
	for t in Boss_List_Type {
		if boss_list_label(t) == label do return Boss_List_Selected(boss_list_name(t))
	}
	return Boss_List_Selected("standard")
}

on_poll_rate :: proc(v: f32) -> Msg { return Poll_Rate_Changed(int(v + 0.5)) }
on_show_deaths :: proc(v: bool) -> Msg { return Show_Deaths_Set(v) }
on_show_attempts :: proc(v: bool) -> Msg { return Show_Attempts_Set(v) }
on_show_session :: proc(v: bool) -> Msg { return Show_Session_Set(v) }
on_kill_banner :: proc(v: bool) -> Msg { return Kill_Banner_Set(v) }
on_kill_banner_secs :: proc(v: f32) -> Msg { return Kill_Banner_Secs(int(v + 0.5)) }
on_obsws_scene :: proc(label: string) -> Msg { return Obsws_Scene_Selected(label) }
on_widget_urls_toggled :: proc(open: bool) -> Msg { return Widget_Urls_Toggled(open) }
on_hide_completed :: proc(v: bool) -> Msg { return Hide_Completed_Set(v) }

on_theme_selected :: proc(label: string) -> Msg {
	return Theme_Selected(theme_name_for_label(label))
}

on_ui_scale_selected :: proc(label: string) -> Msg {
	return Ui_Scale_Selected(ui_scale_for_label(label))
}

on_server_set :: proc(v: bool) -> Msg { return Server_Set(v) }
on_port_draft :: proc(v: string) -> Msg { return Port_Draft_Changed(v) }

on_overlay_mode :: proc(i: int) -> Msg {
	switch i {
	case 1:  return Overlay_Mode_Selected("next")
	case 2:  return Overlay_Mode_Selected("region")
	case:    return Overlay_Mode_Selected("summary")
	}
}

on_overlay_bg :: proc(i: int) -> Msg {
	switch i {
	case 1:  return Overlay_Bg_Selected("green")
	case 2:  return Overlay_Bg_Selected("magenta")
	case:    return Overlay_Bg_Selected("none")
	}
}

on_overlay_count :: proc(v: f32) -> Msg { return Overlay_Count_Changed(int(v + 0.5)) }

on_obs_source_style :: proc(i: int) -> Msg {
	return Obs_Source_Style_Selected(i == 0 ? "web" : "text")
}

on_obs_source_toggled :: proc(kind: Obs_Source, on: bool) -> Msg {
	return Obs_Source_Toggled{kind = kind, on = on}
}

on_roomy_lines :: proc(websocket: bool, v: bool) -> Msg {
	return Roomy_Lines_Set{websocket = websocket, on = v}
}

on_obs_text_set :: proc(v: bool) -> Msg { return Obs_Text_Set(v) }
on_obs_text_dir :: proc(v: string) -> Msg { return Obs_Text_Dir_Draft(v) }

on_obsws_set :: proc(v: bool) -> Msg { return Obsws_Set(v) }
on_obsws_host :: proc(v: string) -> Msg { return Obsws_Host_Draft(v) }
on_obsws_port :: proc(v: string) -> Msg { return Obsws_Port_Draft(v) }
on_obsws_pass :: proc(v: string) -> Msg { return Obsws_Pass_Draft(v) }
on_obsws_remember :: proc(v: bool) -> Msg { return Obsws_Remember_Set(v) }
