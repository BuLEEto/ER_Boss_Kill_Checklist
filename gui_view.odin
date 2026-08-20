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
ID_OVERLAY_BG     :: "obs.overlay_bg"
ID_SHOW_DEATHS    :: "obs.show_deaths"
ID_TEXT_TOGGLE    :: "obs.text_enabled"
ID_TEXT_DIR       :: "obs.text_dir"
ID_WS_TOGGLE      :: "obs.ws_enabled"
ID_WS_HOST        :: "obs.ws_host"
ID_WS_PORT        :: "obs.ws_port"
ID_WS_PASS        :: "obs.ws_pass"
ID_WS_REMEMBER    :: "obs.ws_remember"
ID_HIDE_COMPLETED :: "checklist.hide_completed"

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
	rows := make([dynamic]skald.View, context.temp_allocator)

	running := server_is_running(&app.server)

	// -- Browser source -----------------------------------------------------
	append(&rows, skald.section_header(ctx, "Browser source"))
	append(&rows, paragraph(ctx,
		"The original route, and the best-looking one: OBS renders the overlay page directly.",
		th.color.fg_muted, th.font.size_sm,
	))
	append(&rows, help_button(ctx, .Browser_Source))

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
		append(&rows, skald.text("Server stopped", th.color.fg_muted, th.font.size_sm))
	}

	if running {
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
		append(&rows, skald.checkbox(
			ctx, app.settings.show_deaths, "Include death count", on_show_deaths,
			id = skald.hash_id(ID_SHOW_DEATHS),
		))

		overlay_url := overlay_url_string(context.temp_allocator)
		append(&rows, view_copy_row(ctx, "Overlay URL", overlay_url))
		append(&rows, view_copy_row(ctx, "Mobile view", mobile_url_string(context.temp_allocator)))
	}

	// -- Text files ---------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Text files"))
	append(&rows, paragraph(ctx,
		"Writes plain text files you point OBS \"Text (GDI+/FreeType)\" sources at with \"Read from file\". No browser source, no CPU cost, works on any OBS version.",
		th.color.fg_muted, th.font.size_sm,
	))
	append(&rows, help_button(ctx, .Text_Files))
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

	// -- obs-websocket ------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "obs-websocket"))
	append(&rows, paragraph(ctx,
		"The way most OBS integrations work. Connects to OBS directly and pushes progress into text sources — enable the WebSocket server in OBS under Tools → WebSocket Server Settings.",
		th.color.fg_muted, th.font.size_sm,
	))
	append(&rows, help_button(ctx, .Obs_Websocket))
	append(&rows, skald.toggle(ctx, app.settings.obsws_enabled, "Connect to OBS", on_obsws_set,
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

overlay_url_string :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "http://localhost:%d/overlay?mode=%s",
		app.server.port, app.settings.overlay_mode)
	if app.settings.overlay_mode == "next" {
		fmt.sbprintf(&b, "&count=%d", app.settings.overlay_next_count)
	}
	if app.settings.overlay_bg != "none" {
		fmt.sbprintf(&b, "&bg=%s", app.settings.overlay_bg)
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

on_obs_text_set :: proc(v: bool) -> Msg { return Obs_Text_Set(v) }
on_obs_text_dir :: proc(v: string) -> Msg { return Obs_Text_Dir_Draft(v) }

on_obsws_set :: proc(v: bool) -> Msg { return Obsws_Set(v) }
on_obsws_host :: proc(v: string) -> Msg { return Obsws_Host_Draft(v) }
on_obsws_port :: proc(v: string) -> Msg { return Obsws_Port_Draft(v) }
on_obsws_pass :: proc(v: string) -> Msg { return Obsws_Pass_Draft(v) }
on_obsws_remember :: proc(v: bool) -> Msg { return Obsws_Remember_Set(v) }
