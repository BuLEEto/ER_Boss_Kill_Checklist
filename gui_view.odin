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
		view_widget_style_dialog(s, ctx),
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
ID_OVERLAY_ALIGN  :: "obs.overlay_align"
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
ID_TEXT_TOGGLE    :: "obs.text_enabled"
ID_TEXT_DIR       :: "obs.text_dir"
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
	case .Overlay:   panel = view_obs_browser(s, ctx)
	case .Widgets:   panel = view_obs_widgets(s, ctx)
	case .Text:      panel = view_obs_text(s, ctx)
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

	looks := view_appearance(s, ctx, .Overlay, "browser",
		"How the card looks. The single-value pages have their own, on the next tab.")
	for v in looks do append(&rows, v)

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, paragraph(ctx,
		"Sources → + → Browser in OBS, then paste this into the URL field.",
		th.color.fg_muted, th.font.size_xs,
	))
	append(&rows, view_copy_row(ctx, "Overlay URL", overlay_url_string(context.temp_allocator)))
	append(&rows, view_copy_row(ctx, "Mobile view", mobile_url_string(context.temp_allocator)))

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		padding     = SCROLL_GUTTER,
		cross_align = .Stretch,
	))
}

// ---------------------------------------------------------------------------
// Single values
//
// One page per value, each its own browser source, so they can be put in
// different corners of a layout rather than stacked in one card.
//
// Every row carries its own Style… button. The controls behind it are the
// same set as the shared ones, and eight copies of that inline would be an
// unreadable page — hence a dialog, opened for one page at a time.
// ---------------------------------------------------------------------------

view_obs_widgets :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, help_row(ctx,
		"A page per value, each added to OBS as its own Browser source, so you position and size them separately. Copy the ones you want.",
		.Single_Values,
	))

	if !server_is_running(&app.server) {
		append(&rows, skald.alert(ctx,
			"The web server is off, so these pages won't load. Turn it on under Overlay card.",
			tone = .Warning,
		))
	}

	append(&rows, skald.section_header(ctx, "Pages"))
	for kind in Widget_Kind {
		custom := settings_widget_look(kind).custom

		append(&rows, skald.col(
			skald.row(
				skald.col(
					skald.text(widget_label(kind), th.color.fg, th.font.size_sm),
					skald.text(widget_example(kind), th.color.fg_muted, th.font.size_xs),
					spacing = 0,
				),
				skald.flex(1, skald.spacer(0)),
				skald.text(
					custom ? "Styled on its own" : "Shared style",
					custom ? th.color.primary : th.color.fg_muted,
					th.font.size_xs,
				),
				skald.button(ctx, "Style…", Msg(Widget_Style_Opened(kind)),
					id = skald.hash_id(fmt.tprintf("widget.style.%s", widget_slug(kind)))),
				spacing     = th.spacing.sm,
				cross_align = .Center,
			),
			skald.row(
				skald.flex(1, skald.text_selectable(
					ctx, widget_url_string(kind, context.temp_allocator),
					th.color.fg_muted, th.font.size_xs,
				), min_main = 200),
				skald.button(ctx, "Copy",
					Msg(Copy_Requested(widget_url_string(kind, context.temp_allocator)))),
				spacing     = th.spacing.sm,
				cross_align = .Center,
			),
			spacing     = th.spacing.xs,
			cross_align = .Stretch,
		))
	}

	append(&rows, paragraph(ctx,
		"Each is a browser instance in OBS, so add only the ones you'll use. The URLs never change — everything about how a page looks is resolved here, so restyling one updates it live without re-pasting anything.",
		th.color.fg_muted, th.font.size_xs,
	))

	append(&rows, skald.spacer(th.spacing.sm))
	for v in view_region_control(ctx, .Widget, "widget.region") do append(&rows, v)

	append(&rows, skald.spacer(th.spacing.sm))
	shared := view_appearance(s, ctx, .Widgets, "widget",
		"The shared look, used by every page above that hasn't been styled on its own.")
	for v in shared do append(&rows, v)

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
		on_roomy_lines, id = skald.hash_id(ID_ROOMY_LINES),
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

// ----------------------------------------------------------------------------
// One page's styling
//
// The same controls as the shared Appearance, for a single page, in a
// dialog. Inline would mean eight copies of a nine-row form on one panel,
// which is the sort of page nobody reads.
//
// A page either follows the shared look or has one entirely of its own —
// there's no per-field inheritance. Mixing the two means every control
// needs a third "not set" state, and "why didn't that one change?" is a
// worse question than "this page is styled on its own".
// ----------------------------------------------------------------------------

view_widget_style_dialog :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	kind, open := s.widget_style_open.?
	if !open {
		// Still has to be built: dialog animates its own dismissal, and a
		// view that vanishes outright takes the animation with it.
		return skald.dialog(
			ctx, open = false, on_dismiss = on_widget_style_closed,
			content = skald.spacer(0),
		)
	}

	custom := settings_widget_look(kind).custom

	body := make([dynamic]skald.View, context.temp_allocator)
	append(&body, skald.checkbox(
		ctx, custom, "Style this page on its own",
		kind, on_widget_custom_set,
		id = skald.hash_id("widget.style.custom"),
	))
	append(&body, paragraph(ctx,
		custom \
			? "This page ignores the shared look. Untick to put it back on the shared one — what you set here is kept, so re-ticking brings it back." \
			: "This page follows the shared look set on the Single values panel. Tick to give it a look of its own, starting from a copy of the shared one.",
		th.color.fg_muted, th.font.size_xs,
	))

	if custom {
		append(&body, skald.spacer(th.spacing.sm))
		for v in view_appearance(s, ctx, look_target_for(kind), "one",
			"Applies to this page only.") {
			append(&body, v)
		}
	}

	return skald.dialog(
		ctx,
		open = true,
		on_dismiss = on_widget_style_closed,
		width = 640,
		max_width = 700,
		content = skald.col(
			skald.text(widget_label(kind), th.color.fg, th.font.size_lg),
			skald.text(widget_example(kind), th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.md),
			skald.scroll(ctx, {0, 420}, skald.col(
				..body[:], spacing = th.spacing.sm, cross_align = .Stretch,
			)),
			skald.spacer(th.spacing.md),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Done", Msg(Widget_Style_Closed{}),
					bg = th.color.primary, fg = th.color.on_primary),
				cross_align = .Center,
			),
			spacing     = 0,
			cross_align = .Stretch,
		),
	)
}

on_widget_style_closed :: proc() -> Msg { return Widget_Style_Closed{} }
on_widget_custom_set :: proc(kind: Widget_Kind, on: bool) -> Msg {
	return Widget_Style_Custom_Set{kind = kind, custom = on}
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
// Deliberately carries nothing but the page's type.
//
// Alignment used to be a query parameter, which meant the URL changed
// whenever the setting did and a source you'd already pasted kept the old
// value until you re-pasted it. Everything about how a page looks is now
// resolved server-side from settings, so this string never changes and a
// restyle reaches OBS on the next live update instead.
widget_url_string :: proc(kind: Widget_Kind, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"http://localhost:%d/widget?type=%s",
		app.server.port, widget_slug(kind),
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

on_roomy_lines :: proc(v: bool) -> Msg { return Roomy_Lines_Set(v) }

on_obs_text_set :: proc(v: bool) -> Msg { return Obs_Text_Set(v) }
on_obs_text_dir :: proc(v: string) -> Msg { return Obs_Text_Dir_Draft(v) }

