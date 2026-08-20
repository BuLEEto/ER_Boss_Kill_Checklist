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
// Setup tab
// ----------------------------------------------------------------------------

view_setup :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, skald.section_header(ctx, "Save file"))

	if len(app.settings.save_path) == 0 {
		append(&rows, skald.text(
			"No save file selected yet. Scan finds Elden Ring saves in your Steam libraries, including Proton prefixes.",
			th.color.fg_muted, th.font.size_sm,
		))
	} else {
		append(&rows, skald.text(app.settings.save_path, th.color.fg_muted, th.font.size_sm))
	}

	if len(app.save_error) > 0 {
		append(&rows, skald.alert(ctx, app.save_error, tone = .Danger))
	}

	append(&rows, skald.row(
		skald.button(ctx, s.scanning ? "Scanning…" : "Scan for saves", Msg(Scan_Requested{}),
			bg = th.color.primary, fg = th.color.on_primary),
		skald.button(ctx, "Browse…", Msg(Browse_Requested{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))

	if s.scanning {
		append(&rows, skald.row(
			skald.spinner(ctx, size = 16),
			skald.text("Searching Steam libraries…", th.color.fg_muted, th.font.size_sm),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		))
	} else if len(s.scan_results) > 0 {
		append(&rows, view_scan_results(s, ctx))
	} else if s.scan_ran {
		append(&rows, skald.text(
			"Nothing found. Use Browse… to point at ER0000.sl2 / .co2 / .rd2 yourself.",
			th.color.fg_muted, th.font.size_sm,
		))
	}

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
				placeholder = "Pick a character",
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
	))

	// -- Options ------------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Options"))

	append(&rows, skald.form_row(ctx,
		fmt.tprintf("Check every %ds", app.settings.poll_seconds),
		skald.slider(
			ctx, f32(app.settings.poll_seconds), on_poll_rate,
			min_value = 1, max_value = 60, step = 1, width = 240,
		),
		label_width = 160,
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.show_deaths, "Show death count in the overlay", on_show_deaths,
	))
	append(&rows, skald.form_row(ctx, "Theme",
		skald.select(
			ctx, theme_label(app.settings.theme),
			{"Dark", "Light", "Follow system"},
			on_theme_selected, width = 200,
		),
		label_width = 160,
	))

	return skald.scroll(ctx, {0, 0}, skald.col(
		..rows[:],
		spacing     = th.spacing.sm,
		cross_align = .Stretch,
	))
}

view_scan_results :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	for found, i in s.scan_results {
		who := "no characters"
		if len(found.characters) > 0 {
			parts := make([dynamic]string, context.temp_allocator)
			for c in found.characters {
				append(&parts, fmt.tprintf("%s (RL %d)", c.name, c.level))
			}
			who = strings.join(parts[:], ", ", context.temp_allocator)
		}

		selected := found.path == app.settings.save_path
		card := skald.col(
			skald.row(
				skald.text(found.filename, th.color.fg, th.font.size_md),
				skald.badge(ctx, fmt.tprintf("AppID %s", found.app_id), tone = .Neutral),
				spacing     = th.spacing.sm,
				cross_align = .Center,
			),
			skald.text(who, th.color.fg_muted, th.font.size_sm),
			skald.text(found.path, th.color.fg_muted, th.font.size_xs),
			spacing = 2,
			padding = th.spacing.sm,
			bg      = selected ? th.color.selection : skald.Color{},
			radius  = th.radius.sm,
		)
		append(&rows, skald.clickable(ctx, card, Msg(Scan_Result_Picked(i))))
	}

	return skald.list_frame(ctx, rows[0], ..rows[1:])
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
		skald.checkbox(ctx, app.settings.hide_completed, "Hide cleared regions", on_hide_completed),
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
	append(&rows, skald.text(
		"The original route, and the best-looking one: OBS renders the overlay page directly.",
		th.color.fg_muted, th.font.size_sm,
	))

	append(&rows, skald.row(
		skald.toggle(ctx, app.settings.server_enabled, "Run the web server", on_server_set),
		skald.flex(1, skald.spacer(0)),
		skald.text("Port", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.port_draft, on_port_draft, width = 90),
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
			),
			label_width = 120,
		))

		if app.settings.overlay_mode == "next" {
			append(&rows, skald.form_row(ctx,
				fmt.tprintf("Show %d bosses", app.settings.overlay_next_count),
				skald.slider(
					ctx, f32(app.settings.overlay_next_count), on_overlay_count,
					min_value = 1, max_value = 25, step = 1, width = 220,
				),
				label_width = 120,
			))
		}

		append(&rows, skald.form_row(ctx, "Background",
			skald.segmented(
				ctx, {"Transparent", "Green", "Magenta"},
				overlay_bg_index(app.settings.overlay_bg), on_overlay_bg,
			),
			label_width = 120,
		))
		append(&rows, skald.text(
			"Transparent works with a Browser Source. Use a chroma key colour only if you're capturing a window instead.",
			th.color.fg_muted, th.font.size_xs,
		))

		overlay_url := overlay_url_string(context.temp_allocator)
		append(&rows, view_copy_row(ctx, "Overlay URL", overlay_url))
		append(&rows, view_copy_row(ctx, "Mobile view", mobile_url_string(context.temp_allocator)))
	}

	// -- Text files ---------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "Text files"))
	append(&rows, skald.text(
		"Writes plain text files you point OBS \"Text (GDI+/FreeType)\" sources at with \"Read from file\". No browser source, no CPU cost, works on any OBS version.",
		th.color.fg_muted, th.font.size_sm,
	))
	append(&rows, skald.toggle(
		ctx, app.settings.obs_text_enabled, "Write text files", on_obs_text_set,
	))
	append(&rows, skald.row(
		skald.flex(1, skald.text_input(
			ctx, s.obs_text_dir_draft, on_obs_text_dir,
			placeholder = obs_text_default_dir(context.temp_allocator),
		), min_main = 240),
		skald.button(ctx, "Browse…", Msg(Obs_Text_Dir_Browse{})),
		skald.button(ctx, "Apply", Msg(Obs_Text_Dir_Committed{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))
	if app.settings.obs_text_enabled {
		names := make([dynamic]skald.View, context.temp_allocator)
		for f in OBS_TEXT_FILES {
			append(&names, skald.text(
				fmt.tprintf("%s — %s", f.name, f.description), th.color.fg_muted, th.font.size_xs,
			))
		}
		append(&rows, skald.col(..names[:], spacing = 2, cross_align = .Stretch))
	}

	// -- obs-websocket ------------------------------------------------------
	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.section_header(ctx, "obs-websocket"))
	append(&rows, skald.text(
		"The way most OBS integrations work. Connects to OBS directly and pushes progress into text sources — enable the WebSocket server in OBS under Tools → WebSocket Server Settings.",
		th.color.fg_muted, th.font.size_sm,
	))
	append(&rows, skald.toggle(ctx, app.settings.obsws_enabled, "Connect to OBS", on_obsws_set))
	append(&rows, skald.row(
		skald.text("Host", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_host_draft, on_obsws_host, width = 160),
		skald.text("Port", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_port_draft, on_obsws_port, width = 90),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))
	append(&rows, skald.row(
		skald.text("Password", th.color.fg_muted, th.font.size_sm),
		skald.text_input(ctx, s.obsws_pass_draft, on_obsws_pass, width = 220, password = true),
		skald.button(ctx, "Connect", Msg(Obsws_Connect_Requested{})),
		spacing     = th.spacing.sm,
		cross_align = .Center,
	))
	append(&rows, skald.checkbox(
		ctx, app.settings.obsws_remember_password,
		"Remember the password (stored in plain text in settings.json)",
		on_obsws_remember,
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
		// Required by the CC-BY-4.0 licence on the emoji font Skald embeds.
		skald.text(
			"Twemoji by Twitter, Inc. and contributors — CC-BY 4.0",
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

theme_label :: proc(name: string) -> string {
	switch name {
	case "light":  return "Light"
	case "system": return "Follow system"
	case:          return "Dark"
	}
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
	switch label {
	case "Light":         return Theme_Selected("light")
	case "Follow system": return Theme_Selected("system")
	case:                 return Theme_Selected("dark")
	}
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
