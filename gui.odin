package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "gui:skald"

// ============================================================================
// Desktop GUI — state, messages, update
//
// The view lives in gui_view.odin. Skald's Elm loop owns the main thread;
// this file is the only place that mutates `app`, and every mutation goes
// through `sync.guard(&app.mu)` because HTTP worker threads read the same
// data. See app_state.odin for the contract.
// ============================================================================

Tab :: enum {
	Setup,
	Checklist,
	OBS,
	About,
}

TAB_LABELS :: [?]string{"Setup", "Checklist", "OBS", "About"}

// The OBS tab covers three separate integrations, each with its own setup
// in OBS itself. Stacking all three down one page meant no way to tell
// which controls belonged to which — so they get a panel each.
Obs_Tab :: enum {
	Browser,
	Text,
	Websocket,
}

OBS_TAB_LABELS :: [?]string{"Browser source", "Text files", "obs-websocket"}

Gui :: struct {
	// Set false until the first frame has asked for the poll loop to
	// start. Skald has no startup-command hook, so `view` kicks this off
	// once and `update` latches it.
	started: bool,

	tab:     Tab,
	obs_tab: Obs_Tab,
	win:     skald.Window_State,

	// Save picker (modal)
	save_dialog_open: bool,
	scanning:         bool,
	scan_results:     []Found_Save,
	scan_ran:         bool,

	// Checklist tab
	expanded: [dynamic]bool, // per region index; shared by reference

	// Draft text fields. Committed on blur/Enter rather than per
	// keystroke, so typing "3100" doesn't try to bind port 3, then 31…
	port_draft:         string,
	obs_text_dir_draft: string,
	obsws_host_draft:   string,
	obsws_port_draft:   string,
	obsws_pass_draft:   string,
	font_family_draft:  [Look_Target]string,
	custom_css_draft:   [Look_Target]string,

	// Save-file polling
	last_mtime: i64,
	poll_busy:  bool,

	// Help sheet currently open, or .None
	help_topic: Help_Topic,

	// Transient feedback
	toast_msg:  string,
	toast_kind: skald.Toast_Kind,
	toast_on:   bool,
}

// ----------------------------------------------------------------------------
// Messages
// ----------------------------------------------------------------------------

Startup :: struct {}
Tab_Selected :: distinct int
Obs_Tab_Selected :: distinct int
Tick :: struct {}

Poll_Done :: struct {
	ok:        bool,
	unchanged: bool,
	data:      []u8, // heap; owned by update
	mtime:     i64,
	err:       string, // heap; owned by update
}

Save_Dialog_Opened :: struct {}
Save_Dialog_Closed :: struct {}

// One click picks the file and the character together — the scan already
// knows which characters each save holds, so making the user choose a
// file and then hunt for the slot in a dropdown is a step for nothing.
Save_Character_Picked :: struct {
	save: int,
	slot: int,
}

Scan_Requested :: struct {}
Scan_Done :: struct {
	saves: []Found_Save, // heap; owned by update
}
Scan_Result_Picked :: distinct int

Browse_Requested :: struct {}
Save_Path_Picked :: struct {
	path: string, // frame arena — clone before keeping
}

Slot_Selected :: distinct int
Boss_List_Selected :: distinct string
Poll_Rate_Changed :: distinct int
Show_Deaths_Set :: distinct bool
Show_Attempts_Set :: distinct bool
Show_Session_Set :: distinct bool
Kill_Banner_Set :: distinct bool
Kill_Banner_Secs :: distinct int
Attempts_Reset :: struct {}
Session_Reset :: struct {}
Obsws_Scene_Selected :: distinct string
Hide_Completed_Set :: distinct bool
Theme_Selected :: distinct string
Ui_Scale_Selected :: distinct f32

Region_Toggled :: distinct int
Expand_All :: distinct bool

Server_Set :: distinct bool
Port_Draft_Changed :: distinct string
Port_Committed :: struct {}

Overlay_Mode_Selected :: distinct string
Overlay_Bg_Selected :: distinct string
Obs_Source_Style_Selected :: distinct string

Region_Selected :: struct {
	target: Region_Target,
	choice: string,
}

// Appearance edits all carry which panel they came from, so one set of
// handlers serves the overlay and the widget pages without either
// reaching into the other's settings.
Look_Accent_Set :: struct { target: Look_Target, hex: string }
Look_Text_Set :: struct { target: Look_Target, hex: string }
Look_Size_Set :: struct { target: Look_Target, size: int }
Look_Outline_Set :: struct { target: Look_Target, on: bool }
Look_Align_Set :: struct { target: Look_Target, align: string }
Look_Font_Draft :: struct { target: Look_Target, text: string }
Look_Font_Committed :: struct { target: Look_Target }
Look_Css_Draft :: struct { target: Look_Target, text: string }
Look_Css_Committed :: struct { target: Look_Target }
Look_Reset :: struct { target: Look_Target }

Roomy_Lines_Set :: struct { websocket: bool, on: bool }

Overlay_Count_Changed :: distinct int
Copy_Requested :: distinct string

Obs_Source_Toggled :: struct {
	kind: Obs_Source,
	on:   bool,
}

Obs_Text_Set :: distinct bool
Obs_Text_Dir_Draft :: distinct string
Obs_Text_Dir_Committed :: struct {}
Obs_Text_Dir_Browse :: struct {}

Obsws_Set :: distinct bool
Obsws_Host_Draft :: distinct string
Obsws_Port_Draft :: distinct string
Obsws_Pass_Draft :: distinct string
Obsws_Remember_Set :: distinct bool
Obsws_Connect_Requested :: struct {}
Obsws_Status_Changed :: struct {
	connected: bool,
	message:   string, // heap; owned by update
}

Help_Opened :: distinct Help_Topic
Help_Closed :: struct {}

Toast_Dismissed :: struct {}
Window_Changed :: distinct skald.Window_State

Msg :: union {
	Startup,
	Tab_Selected,
	Obs_Tab_Selected,
	Tick,
	Poll_Done,
	Save_Dialog_Opened,
	Save_Dialog_Closed,
	Save_Character_Picked,
	Scan_Requested,
	Scan_Done,
	Scan_Result_Picked,
	Browse_Requested,
	Save_Path_Picked,
	Slot_Selected,
	Boss_List_Selected,
	Poll_Rate_Changed,
	Show_Deaths_Set,
	Show_Attempts_Set,
	Show_Session_Set,
	Kill_Banner_Set,
	Kill_Banner_Secs,
	Attempts_Reset,
	Session_Reset,
	Obsws_Scene_Selected,
	Hide_Completed_Set,
	Theme_Selected,
	Ui_Scale_Selected,
	Region_Toggled,
	Expand_All,
	Server_Set,
	Port_Draft_Changed,
	Port_Committed,
	Overlay_Mode_Selected,
	Overlay_Bg_Selected,
	Overlay_Count_Changed,
	Obs_Source_Style_Selected,
	Region_Selected,
	Look_Accent_Set,
	Look_Text_Set,
	Look_Size_Set,
	Look_Outline_Set,
	Look_Align_Set,
	Look_Font_Draft,
	Look_Font_Committed,
	Look_Css_Draft,
	Look_Css_Committed,
	Look_Reset,
	Obs_Source_Toggled,
	Copy_Requested,
	Obs_Text_Set,
	Roomy_Lines_Set,
	Obs_Text_Dir_Draft,
	Obs_Text_Dir_Committed,
	Obs_Text_Dir_Browse,
	Obsws_Set,
	Obsws_Host_Draft,
	Obsws_Port_Draft,
	Obsws_Pass_Draft,
	Obsws_Remember_Set,
	Obsws_Connect_Requested,
	Obsws_Status_Changed,
	Help_Opened,
	Help_Closed,
	Toast_Dismissed,
	Window_Changed,
}

// ----------------------------------------------------------------------------
// init
// ----------------------------------------------------------------------------

gui_init :: proc() -> Gui {
	g: Gui
	g.tab = app.settings.save_path == "" ? .Setup : .Checklist
	g.win = saved_window_state()

	g.port_draft         = fmt.aprintf("%d", app.settings.server_port)
	g.obsws_port_draft   = fmt.aprintf("%d", app.settings.obsws_port)
	g.obsws_host_draft   = strings.clone(app.settings.obsws_host)
	g.obsws_pass_draft   = strings.clone(app.settings.obsws_password)
	g.obs_text_dir_draft = strings.clone(app.settings.obs_text_dir)
	for t in Look_Target {
		look := settings_look(t)^
		g.font_family_draft[t] = strings.clone(look.font_family)
		g.custom_css_draft[t] = strings.clone(look.custom_css)
	}

	g.expanded = make([dynamic]bool, len(app.regions))
	// Regions with something left to kill start open; finished ones
	// stay folded away.
	for &r, i in app.regions {
		total, killed := count_region_bosses(&r)
		g.expanded[i] = killed < total
	}

	return g
}

// ----------------------------------------------------------------------------
// update
// ----------------------------------------------------------------------------

gui_update :: proc(s: Gui, msg: Msg) -> (Gui, skald.Command(Msg)) {
	out := s

	switch v in msg {

	case Startup:
		if out.started do return out, {}
		out.started = true

		// Reconnect to OBS if that's how the app was left. Doing it here
		// rather than in main() keeps the socket work on a worker.
		if app.settings.obsws_enabled {
			return out, skald.cmd_batch(
				skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker),
				skald.cmd_delay(f32(app.settings.poll_seconds), Msg(Tick{})),
			)
		}
		return out, skald.cmd_delay(f32(app.settings.poll_seconds), Msg(Tick{}))

	case Tab_Selected:
		out.tab = Tab(int(v))

	case Obs_Tab_Selected:
		out.obs_tab = Obs_Tab(int(v))

	case Tick:
		// Nothing to poll, or a poll is already in flight — just come
		// back later.
		if out.poll_busy || len(app.settings.save_path) == 0 || app.settings.active_slot < 0 {
			return out, skald.cmd_delay(f32(app.settings.poll_seconds), Msg(Tick{}))
		}
		out.poll_busy = true
		return out, skald.cmd_thread(Msg, Poll_Params{
			path       = strings.clone(app.settings.save_path),
			last_mtime = out.last_mtime,
		}, poll_worker)

	case Poll_Done:
		out.poll_busy = false
		out = apply_poll_result(out, v)
		return out, skald.cmd_delay(f32(app.settings.poll_seconds), Msg(Tick{}))

	case Save_Dialog_Opened:
		out.save_dialog_open = true
		// Rescan on open so a character made since the last look shows up.
		// It's ~100 ms and it runs on a worker, so there's no reason to
		// serve a stale list.
		if out.scanning do return out, {}
		out.scanning = true
		return out, skald.cmd_thread_simple(Msg, scan_worker)

	case Save_Dialog_Closed:
		out.save_dialog_open = false

	case Save_Character_Picked:
		if v.save < 0 || v.save >= len(out.scan_results) do return out, {}
		out = gui_apply_save(out, out.scan_results[v.save].path, v.slot)

	case Scan_Requested:
		if out.scanning do return out, {}
		out.scanning = true
		return out, skald.cmd_thread_simple(Msg, scan_worker)

	case Scan_Done:
		out.scanning = false
		out.scan_ran = true
		free_found_saves(out.scan_results)
		out.scan_results = v.saves

	case Scan_Result_Picked:
		idx := int(v)
		if idx < 0 || idx >= len(out.scan_results) do return out, {}
		out = gui_apply_save(out, out.scan_results[idx].path, -1)

	case Browse_Requested:
		// Filters are deliberately nil: SDL3's filtered-file-dialog path
		// is unreliable on some Linux desktops (see Skald's gotchas).
		// We validate the extension ourselves in Save_Path_Picked.
		return out, skald.cmd_open_file_dialog(
			nil,
			on_save_file_picked,
			default_location = default_browse_location(),
		)

	case Save_Path_Picked:
		if !is_save_filename(v.path) {
			out = gui_toast(
				out,
				"That isn't an Elden Ring save (.sl2, .co2 or .rd2)",
				.Danger,
			)
			return out, {}
		}
		out = gui_apply_save(out, v.path, -1)

	case Slot_Selected:
		sync.guard(&app.mu)
		app_set_active_slot(int(v))
		app_save_settings()
		out = gui_sync_expanded(out)
		out = gui_after_data_change(out)

	case Boss_List_Selected:
		sync.guard(&app.mu)
		if app_set_boss_list(boss_list_from_name(string(v))) {
			app_save_settings()
			out = gui_sync_expanded(out)
			out = gui_after_data_change(out)
		} else {
			out = gui_toast(out, "Could not load that boss list", .Danger)
		}

	case Poll_Rate_Changed:
		sync.guard(&app.mu)
		app.settings.poll_seconds = clamp(int(v), POLL_SECONDS_MIN, POLL_SECONDS_MAX)
		app_save_settings()

	case Show_Deaths_Set:
		sync.guard(&app.mu)
		app.settings.show_deaths = bool(v)
		app_save_settings()
		out = gui_after_data_change(out)

	case Show_Attempts_Set:
		sync.guard(&app.mu)
		app.settings.show_attempts = bool(v)
		app_save_settings()
		out = gui_after_data_change(out)

	case Show_Session_Set:
		sync.guard(&app.mu)
		app.settings.show_session = bool(v)
		app_save_settings()
		out = gui_after_data_change(out)

	case Kill_Banner_Set:
		sync.guard(&app.mu)
		app.settings.kill_banner_enabled = bool(v)
		app_save_settings()

	case Kill_Banner_Secs:
		sync.guard(&app.mu)
		app.settings.kill_banner_seconds = clamp(
			int(v), KILL_BANNER_SECONDS_MIN, KILL_BANNER_SECONDS_MAX,
		)
		app_save_settings()

	case Attempts_Reset:
		sync.guard(&app.mu)
		app_reset_attempts()
		app_save_settings()
		out = gui_after_data_change(out)
		out = gui_toast(out, "Attempt counter reset", .Success)

	case Session_Reset:
		sync.guard(&app.mu)
		app_reset_session()
		out = gui_after_data_change(out)
		out = gui_toast(out, "Session counters reset", .Success)

	case Obsws_Scene_Selected:
		sync.guard(&app.mu)
		scene := string(v)
		// The sentinel is a label, not a scene name. Store it as empty so
		// "follow whatever's live" keeps meaning that even if OBS gains a
		// scene actually called that.
		if scene == OBSWS_SCENE_CURRENT_LABEL do scene = ""
		if scene == app.settings.obsws_scene do return out, {}

		settings_set_string(&app.settings.obsws_scene, scene)
		app_save_settings()
		if !app.settings.obsws_enabled do return out, {}

		// Moving sources needs request/response traffic, and once we're
		// connected the reader thread owns the socket — two threads in
		// ws.receive on one connection is a race. Reconnecting gets a
		// clean run at it through the path that already does this, and
		// picking a scene is a once-in-a-setup action.
		return out, skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker)

	case Hide_Completed_Set:
		sync.guard(&app.mu)
		app.settings.hide_completed = bool(v)
		app_save_settings()

	case Theme_Selected:
		sync.guard(&app.mu)
		settings_set_string(&app.settings.theme, string(v))
		app_save_settings()
		return out, skald.cmd_set_theme(
			Msg, theme_for_name(app.settings.theme, app.settings.ui_scale),
		)

	case Ui_Scale_Selected:
		sync.guard(&app.mu)
		app.settings.ui_scale = clamp(f32(v), UI_SCALE_MIN, UI_SCALE_MAX)
		app_save_settings()
		return out, skald.cmd_set_theme(
			Msg, theme_for_name(app.settings.theme, app.settings.ui_scale),
		)

	case Region_Toggled:
		i := int(v)
		if i >= 0 && i < len(out.expanded) {
			out.expanded[i] = !out.expanded[i]
		}

	case Expand_All:
		for i in 0 ..< len(out.expanded) {
			out.expanded[i] = bool(v)
		}

	case Server_Set:
		sync.guard(&app.mu)
		app.settings.server_enabled = bool(v)
		app_save_settings()
		if bool(v) {
			if !server_start(&app.server, app.settings.server_port) {
				out = gui_toast(out, server_error_text(&app.server), .Danger)
			}
		} else {
			server_stop(&app.server)
		}

	case Port_Draft_Changed:
		delete(out.port_draft)
		out.port_draft = strings.clone(string(v))

	case Port_Committed:
		port, ok := strconv.parse_int(strings.trim_space(out.port_draft))
		if !ok || port < 1 || port > 65535 {
			out = gui_toast(out, "Port must be between 1 and 65535", .Danger)
			delete(out.port_draft)
			out.port_draft = fmt.aprintf("%d", app.settings.server_port)
			return out, {}
		}
		if port == app.settings.server_port do return out, {}

		sync.guard(&app.mu)
		app.settings.server_port = port
		app_save_settings()
		if server_is_running(&app.server) {
			server_stop(&app.server)
			if !server_start(&app.server, port) {
				out = gui_toast(out, server_error_text(&app.server), .Danger)
			} else {
				out = gui_toast(out, fmt.tprintf("Server restarted on port %d", port), .Success)
			}
		}

	case Overlay_Mode_Selected:
		sync.guard(&app.mu)
		settings_set_string(&app.settings.overlay_mode, string(v))
		app_save_settings()

	case Overlay_Bg_Selected:
		sync.guard(&app.mu)
		settings_set_string(&app.settings.overlay_bg, string(v))
		app_save_settings()

	case Look_Align_Set:
		sync.guard(&app.mu)
		settings_set_string(&settings_look(v.target).align, v.align)
		app_save_settings()
		out = gui_theme_changed(out)

	case Region_Selected:
		sync.guard(&app.mu)
		r := settings_region(v.target)
		if v.choice == "first" || v.choice == "last_kill" {
			settings_set_string(&r.mode, v.choice)
		} else {
			settings_set_string(&r.mode, "pinned")
			settings_set_string(&r.name, v.choice)
		}
		app_save_settings()
		out = gui_after_data_change(out)

	case Overlay_Count_Changed:
		sync.guard(&app.mu)
		app.settings.overlay_next_count = clamp(int(v), 1, 50)
		app_save_settings()

	case Look_Accent_Set:
		sync.guard(&app.mu)
		settings_set_string(&settings_look(v.target).accent, v.hex)
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Text_Set:
		sync.guard(&app.mu)
		settings_set_string(&settings_look(v.target).text_color, v.hex)
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Size_Set:
		sync.guard(&app.mu)
		settings_look(v.target).font_size = clamp(v.size, 12, 96)
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Outline_Set:
		sync.guard(&app.mu)
		settings_look(v.target).outline = v.on
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Font_Draft:
		delete(out.font_family_draft[v.target])
		out.font_family_draft[v.target] = strings.clone(v.text)

	case Look_Font_Committed:
		sync.guard(&app.mu)
		settings_set_string(
			&settings_look(v.target).font_family,
			strings.trim_space(out.font_family_draft[v.target]),
		)
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Css_Draft:
		delete(out.custom_css_draft[v.target])
		out.custom_css_draft[v.target] = strings.clone(v.text)

	case Look_Css_Committed:
		sync.guard(&app.mu)
		settings_set_string(
			&settings_look(v.target).custom_css, out.custom_css_draft[v.target],
		)
		app_save_settings()
		out = gui_theme_changed(out)

	case Look_Reset:
		sync.guard(&app.mu)
		defaults := default_appearance()
		look := settings_look(v.target)
		settings_set_string(&look.accent, defaults.accent)
		settings_set_string(&look.text_color, defaults.text_color)
		settings_set_string(&look.font_family, "")
		settings_set_string(&look.custom_css, "")
		settings_set_string(&look.align, defaults.align)
		look.font_size = defaults.font_size
		look.outline = defaults.outline
		app_save_settings()

		delete(out.font_family_draft[v.target])
		out.font_family_draft[v.target] = strings.clone("")
		delete(out.custom_css_draft[v.target])
		out.custom_css_draft[v.target] = strings.clone("")
		out = gui_theme_changed(out)

	case Obs_Source_Style_Selected:
		sync.guard(&app.mu)
		settings_set_string(&app.settings.obsws_source_style, string(v))
		app_save_settings()
		// The sources are a different OBS input kind either way, so the
		// existing ones can't be converted — reconnecting creates the new
		// shape and hides whatever the old style left behind.
		if app.settings.obsws_enabled {
			return out, skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker)
		}

	case Obs_Source_Toggled:
		sync.guard(&app.mu)
		switch v.kind {
		case .Progress:      app.settings.obsws_send_progress = v.on
		case .Next_Boss:     app.settings.obsws_send_next_boss = v.on
		case .Deaths:        app.settings.obsws_send_deaths = v.on
		case .Character:     app.settings.obsws_send_character = v.on
		case .Region:        app.settings.obsws_send_region = v.on
		case .Region_Bosses: app.settings.obsws_send_region_bosses = v.on
		case .Attempts:      app.settings.obsws_send_attempts = v.on
		case .Session:       app.settings.obsws_send_session = v.on
		case .Overlay:       app.settings.obsws_send_overlay = v.on
		}
		app_save_settings()

		// Reconnect rather than patching the one source. Creating,
		// showing and hiding all need a round trip for the scene item id,
		// and the socket's replies belong to the reader thread once it's
		// running — the setup pass is the one place round trips are safe,
		// because it runs before the reader starts. On loopback a
		// reconnect is imperceptible, and it reconciles every source at
		// once rather than drifting one at a time.
		if app.settings.obsws_enabled {
			return out, skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker)
		}

	case Copy_Requested:
		skald.clipboard_set(string(v))
		out = gui_toast(out, "Copied to clipboard", .Success)

	case Obs_Text_Set:
		sync.guard(&app.mu)
		app.settings.obs_text_enabled = bool(v)
		app_save_settings()
		if bool(v) {
			if err := obs_text_write_all(); err != nil {
				out = gui_toast(out, fmt.tprintf("Could not write text files: %v", err), .Danger)
			} else {
				out = gui_toast(out, "Text files written", .Success)
			}
		}

	case Roomy_Lines_Set:
		sync.guard(&app.mu)
		if v.websocket {
			app.settings.ws_roomy_lines = v.on
		} else {
			app.settings.text_roomy_lines = v.on
		}
		app_save_settings()
		out = gui_after_data_change(out)

	case Obs_Text_Dir_Draft:
		delete(out.obs_text_dir_draft)
		out.obs_text_dir_draft = strings.clone(string(v))

	case Obs_Text_Dir_Browse:
		// Folder dialogs are the reliable half of SDL3's picker on Linux
		// (the filtered-file path is the flaky one), so this needs no
		// fallback.
		return out, skald.cmd_open_folder_dialog(
			on_obs_folder_picked,
			default_location = obs_text_dir(context.temp_allocator),
		)

	case Obs_Text_Dir_Committed:
		sync.guard(&app.mu)
		settings_set_string(
			&app.settings.obs_text_dir, strings.trim_space(out.obs_text_dir_draft),
		)
		app_save_settings()
		if app.settings.obs_text_enabled {
			if err := obs_text_write_all(); err != nil {
				out = gui_toast(out, fmt.tprintf("Could not write text files: %v", err), .Danger)
			}
		}

	case Obsws_Set:
		sync.guard(&app.mu)
		app.settings.obsws_enabled = bool(v)
		app_save_settings()
		if !bool(v) {
			obsws_disconnect()
			return out, {}
		}
		// Connecting talks to a socket, so it goes to a worker — OBS
		// being slow or absent must not freeze the window.
		return out, skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker)

	case Obsws_Host_Draft:
		delete(out.obsws_host_draft)
		out.obsws_host_draft = strings.clone(string(v))

	case Obsws_Port_Draft:
		delete(out.obsws_port_draft)
		out.obsws_port_draft = strings.clone(string(v))

	case Obsws_Pass_Draft:
		delete(out.obsws_pass_draft)
		out.obsws_pass_draft = strings.clone(string(v))

	case Obsws_Remember_Set:
		sync.guard(&app.mu)
		app.settings.obsws_remember_password = bool(v)
		app_save_settings()

	case Obsws_Connect_Requested:
		port, ok := strconv.parse_int(strings.trim_space(out.obsws_port_draft))
		if !ok || port < 1 || port > 65535 {
			out = gui_toast(out, "obs-websocket port must be between 1 and 65535", .Danger)
			return out, {}
		}
		sync.guard(&app.mu)
		settings_set_string(
			&app.settings.obsws_host, strings.trim_space(out.obsws_host_draft),
		)
		app.settings.obsws_port = port
		settings_set_string(&app.settings.obsws_password, out.obsws_pass_draft)
		app.settings.obsws_enabled = true
		app_save_settings()
		return out, skald.cmd_thread(Msg, obsws_connect_command(), obsws_connect_worker)

	case Obsws_Status_Changed:
		if len(v.message) > 0 {
			out = gui_toast(out, v.message, v.connected ? .Success : .Danger)
			delete(v.message)
		}
		// Seed the sources from here rather than from the connect worker:
		// pushing reads the boss list, and only the GUI thread may do that.
		if v.connected do obsws_push_update()

	case Help_Opened:
		out.help_topic = Help_Topic(v)

	case Help_Closed:
		out.help_topic = .None

	case Toast_Dismissed:
		out.toast_on = false

	case Window_Changed:
		out.win = skald.Window_State(v)
		sync.guard(&app.mu)
		app.settings.window_x         = int(out.win.pos.x)
		app.settings.window_y         = int(out.win.pos.y)
		app.settings.window_w         = int(out.win.size.x)
		app.settings.window_h         = int(out.win.size.y)
		app.settings.window_maximized = out.win.maximized
		app_save_settings()
	}

	return out, {}
}

// ----------------------------------------------------------------------------
// Helpers used by update
// ----------------------------------------------------------------------------

// Load `path` and select `slot` in it. Pass slot = -1 for "work it out":
// a save with exactly one character picks itself, otherwise the user is
// left on Setup to choose.
gui_apply_save :: proc(s: Gui, path: string, slot: int) -> Gui {
	out := s
	sync.guard(&app.mu)

	// Captured before anything changes: "was the app unconfigured when
	// the user started this?" decides whether finishing counts as
	// completing first-run setup.
	was_unconfigured := !app.save_loaded || app.settings.active_slot < 0

	// Re-picking the file you're already on shouldn't cost you your
	// character. app_set_save_path clears the slot because a slot index
	// is only meaningful within one file — so carry it over when the
	// file hasn't actually changed.
	slot := slot
	if slot < 0 && path == app.settings.save_path {
		slot = app.settings.active_slot
	}

	app_set_save_path(path)
	app_save_settings()

	out.last_mtime = 0 // force the next poll to actually read
	out = gui_sync_expanded(out)

	if len(app.save_error) > 0 {
		// Leave the picker open — the user needs to choose something else.
		return gui_toast(out, app.save_error, .Danger)
	}

	chosen := slot
	if chosen < 0 {
		active := 0
		for sl in app.slots {
			if !sl.active do continue
			active += 1
			chosen = sl.index
		}
		if active != 1 do chosen = -1
	}

	if chosen >= 0 && chosen < len(app.slots) && app.slots[chosen].active {
		app_set_active_slot(chosen)
		app_save_settings()
		out = gui_after_data_change(out)
		out.save_dialog_open = false

		// Only sweep the user to the checklist when they had nothing set
		// up — that's the first-run flow finishing. Someone who went to
		// Setup deliberately to change character or boss list expects to
		// still be on Setup afterwards, not to be thrown somewhere else
		// mid-task.
		if was_unconfigured {
			out.tab = .Checklist
		}
		return gui_toast(out, fmt.tprintf("Tracking %s", app.slots[chosen].name), .Success)
	}

	out.save_dialog_open = false
	return gui_toast(out, "Save loaded — now pick a character", .Info)
}

// Rebuild the per-region expanded flags after the region list changed
// shape. Keeps the "open what isn't finished" default.
gui_sync_expanded :: proc(s: Gui) -> Gui {
	out := s
	resize(&out.expanded, len(app.regions))
	for &r, i in app.regions {
		total, killed := count_region_bosses(&r)
		out.expanded[i] = killed < total
	}
	return out
}

// Everything that has to happen after boss kill state changes: push to
// the web clients and refresh the OBS outputs.
gui_after_data_change :: proc(s: Gui) -> Gui {
	total, killed := count_bosses(app.regions)
	sse_broadcast_update(killed, total, app.death_count)

	if app.settings.obs_text_enabled {
		if err := obs_text_write_all(); err != nil {
			fmt.eprintfln("OBS text output failed: %v", err)
		}
	}
	if app.settings.obsws_enabled {
		obsws_push_update()
	}
	return s
}

// The pages render the theme server-side, so the browser sources only
// need telling to reload. Nudging the SSE clients does exactly that, and
// costs nothing when nobody's connected.
gui_theme_changed :: proc(s: Gui) -> Gui {
	total, killed := count_bosses(app.regions)
	sse_broadcast_update(killed, total, app.death_count)
	return s
}

gui_toast :: proc(s: Gui, message: string, kind: skald.Toast_Kind) -> Gui {
	out := s
	if len(out.toast_msg) > 0 do delete(out.toast_msg)
	out.toast_msg = strings.clone(message)
	out.toast_kind = kind
	out.toast_on = true
	return out
}

// ----------------------------------------------------------------------------
// Background workers
//
// These run on their own OS thread. They must not read or write `app`,
// `Gui`, or anything Skald owns — everything they need arrives by value
// and everything they return is heap-allocated. See Skald's
// docs/gotchas.md, "cmd_thread workers must not touch Skald state".
// ----------------------------------------------------------------------------

Poll_Params :: struct {
	path:       string,
	last_mtime: i64,
}

poll_worker :: proc(p: Poll_Params) -> Msg {
	defer delete(p.path)

	fi, stat_err := os.stat(p.path, context.temp_allocator)
	if stat_err != nil {
		return Poll_Done{err = strings.clone("Save file is no longer readable")}
	}

	mtime := fi.modification_time._nsec
	if mtime == p.last_mtime {
		// Untouched since last look — skip the 25 MB read.
		return Poll_Done{ok = true, unchanged = true, mtime = mtime}
	}

	data, read_err := os.read_entire_file(p.path, context.allocator)
	if read_err != nil {
		return Poll_Done{err = strings.clone("Could not read the save file")}
	}
	return Poll_Done{ok = true, data = data, mtime = mtime}
}

scan_worker :: proc() -> Msg {
	// Intermediate junk goes in the worker's own temp arena; only the
	// results are cloned onto the heap for the main thread.
	found := scan_saves(context.temp_allocator)

	out := make([]Found_Save, len(found))
	for f, i in found {
		chars := make([]Found_Character, len(f.characters))
		for c, j in f.characters {
			chars[j] = Found_Character{
				index = c.index,
				name  = strings.clone(c.name),
				level = c.level,
			}
		}
		out[i] = Found_Save {
			path       = strings.clone(f.path),
			filename   = strings.clone(f.filename),
			app_id     = strings.clone(f.app_id),
			characters = chars,
		}
	}
	return Scan_Done{saves = out}
}

free_found_saves :: proc(saves: []Found_Save) {
	for s in saves {
		for c in s.characters do delete(c.name)
		delete(s.characters)
		delete(s.path)
		delete(s.filename)
		delete(s.app_id)
	}
	delete(saves)
}

// Merge a completed poll back into shared state.
apply_poll_result :: proc(s: Gui, r: Poll_Done) -> Gui {
	out := s

	if !r.ok {
		if len(r.err) > 0 {
			out = gui_toast(out, r.err, .Danger)
			delete(r.err)
		}
		return out
	}

	out.last_mtime = r.mtime
	if r.unchanged do return out

	sync.guard(&app.mu)

	old_deaths := app.death_count
	old_killed := make(map[u32]bool, 512, context.temp_allocator)
	for &reg in app.regions {
		for &b in reg.bosses do old_killed[b.flag_id] = b.killed
	}

	new_save, ok := parse_save_bytes(app.settings.save_path, r.data)
	if !ok {
		delete(r.data)
		return gui_toast(out, "Save file changed but could not be parsed", .Danger)
	}

	if app.save_loaded do close_save_file(&app.save_file)
	app.save_file = new_save
	app.save_loaded = true

	free_character_slots(app.slots)
	app.slots = get_character_slots(&app.save_file)
	app_update_boss_status()

	changed := app.death_count != old_deaths
	newly_killed := 0

	// What fell this poll, for the overlay banner. Usually one name; a
	// save that changed while the app was closed can bring in several.
	//
	// The diff below is only ever this poll's doing: every path that
	// changes the character, the save file or the boss list recomputes the
	// kill flags before it returns, so the snapshot taken above already
	// reflects them. Nothing else can look like a kill.
	killed_names := make([dynamic]string, context.temp_allocator)

	// Which area saw the most new kills this poll. Usually one boss in
	// one area, but a save that changed while the app was closed can
	// bring in several at once — the busiest area is the better guess at
	// where the player actually is.
	best_region := ""
	best_count := 0

	for &reg in app.regions {
		region_kills := 0
		for &b in reg.bosses {
			was, seen := old_killed[b.flag_id]
			if seen && was != b.killed {
				changed = true
				if b.killed {
					newly_killed += 1
					region_kills += 1
					append(&killed_names, b.boss)
				}
			}
		}
		if region_kills > best_count {
			best_count = region_kills
			best_region = reg.region_name
		}
	}

	// Session counters, from this poll's diff only — so a character switch
	// between polls can't leak into them.
	if app.death_count > old_deaths {
		app.session_deaths += int(app.death_count - old_deaths)
	}
	app.session_bosses += newly_killed

	settings_dirty := best_count > 0 && app_note_kill_region(best_region)

	// A kill is what the attempts counter measures from. Rebase before the
	// write below so the region note and the new bookmark land together.
	if newly_killed > 0 {
		app_reset_attempts()
		settings_dirty = true
	}
	if settings_dirty do app_save_settings()

	if !changed do return out

	// Banner before data. The overlay holds its reload until the banner
	// has played, which it can only do if it hears about the kill first.
	if newly_killed > 0 && app.settings.kill_banner_enabled {
		sse_broadcast_kill(killed_names[:])
	}

	out = gui_after_data_change(out)
	if newly_killed > 0 {
		total, killed := count_bosses(app.regions)
		out = gui_toast(
			out,
			fmt.tprintf("Boss defeated — %d/%d", killed, total),
			.Success,
		)
	}
	return out
}

// ----------------------------------------------------------------------------
// Callbacks Skald hands results back through
// ----------------------------------------------------------------------------

on_save_file_picked :: proc(r: skald.File_Dialog_Result) -> Msg {
	if r.cancelled do return Toast_Dismissed{}
	return Save_Path_Picked{path = r.path}
}

on_obs_folder_picked :: proc(r: skald.File_Dialog_Result) -> Msg {
	if r.cancelled do return Toast_Dismissed{}
	return Obs_Text_Dir_Draft(r.path)
}

on_window_changed :: proc(ws: skald.Window_State) -> Msg {
	return Window_Changed(ws)
}

// Start the file dialog somewhere useful: next to the current save if
// there is one, otherwise let the OS decide.
default_browse_location :: proc() -> string {
	if len(app.settings.save_path) == 0 do return ""
	return os.dir(app.settings.save_path)
}

on_system_theme_changed :: proc(t: skald.System_Theme) -> Msg {
	return Theme_Selected("system")
}
