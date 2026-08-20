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

Gui :: struct {
	// Set false until the first frame has asked for the poll loop to
	// start. Skald has no startup-command hook, so `view` kicks this off
	// once and `update` latches it.
	started: bool,

	tab: Tab,
	win: skald.Window_State,

	// Setup tab
	scanning:     bool,
	scan_results: []Found_Save,
	scan_ran:     bool,

	// Checklist tab
	expanded: [dynamic]bool, // per region index; shared by reference

	// Draft text fields. Committed on blur/Enter rather than per
	// keystroke, so typing "3100" doesn't try to bind port 3, then 31…
	port_draft:         string,
	obs_text_dir_draft: string,
	obsws_host_draft:   string,
	obsws_port_draft:   string,
	obsws_pass_draft:   string,

	// Save-file polling
	last_mtime: i64,
	poll_busy:  bool,

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
Tick :: struct {}

Poll_Done :: struct {
	ok:        bool,
	unchanged: bool,
	data:      []u8, // heap; owned by update
	mtime:     i64,
	err:       string, // heap; owned by update
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
Hide_Completed_Set :: distinct bool
Theme_Selected :: distinct string

Region_Toggled :: distinct int
Expand_All :: distinct bool

Server_Set :: distinct bool
Port_Draft_Changed :: distinct string
Port_Committed :: struct {}

Overlay_Mode_Selected :: distinct string
Overlay_Bg_Selected :: distinct string
Overlay_Count_Changed :: distinct int
Copy_Requested :: distinct string

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

Toast_Dismissed :: struct {}
Window_Changed :: distinct skald.Window_State

Msg :: union {
	Startup,
	Tab_Selected,
	Tick,
	Poll_Done,
	Scan_Requested,
	Scan_Done,
	Scan_Result_Picked,
	Browse_Requested,
	Save_Path_Picked,
	Slot_Selected,
	Boss_List_Selected,
	Poll_Rate_Changed,
	Show_Deaths_Set,
	Hide_Completed_Set,
	Theme_Selected,
	Region_Toggled,
	Expand_All,
	Server_Set,
	Port_Draft_Changed,
	Port_Committed,
	Overlay_Mode_Selected,
	Overlay_Bg_Selected,
	Overlay_Count_Changed,
	Copy_Requested,
	Obs_Text_Set,
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

	case Scan_Requested:
		if out.scanning do return out, {}
		out.scanning = true
		return out, skald.cmd_thread_simple(Msg, scan_worker)

	case Scan_Done:
		out.scanning = false
		out.scan_ran = true
		free_found_saves(out.scan_results)
		out.scan_results = v.saves
		if len(v.saves) == 0 {
			out = gui_toast(out, "No Elden Ring saves found — use Browse to pick one", .Warning)
		}

	case Scan_Result_Picked:
		idx := int(v)
		if idx < 0 || idx >= len(out.scan_results) do return out, {}
		out = gui_set_save_path(out, out.scan_results[idx].path)

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
		out = gui_set_save_path(out, v.path)

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
		app.settings.poll_seconds = clamp(int(v), 1, 60)
		app_save_settings()

	case Show_Deaths_Set:
		sync.guard(&app.mu)
		app.settings.show_deaths = bool(v)
		app_save_settings()

	case Hide_Completed_Set:
		sync.guard(&app.mu)
		app.settings.hide_completed = bool(v)
		app_save_settings()

	case Theme_Selected:
		sync.guard(&app.mu)
		delete(app.settings.theme)
		app.settings.theme = strings.clone(string(v))
		app_save_settings()
		return out, skald.cmd_set_theme(Msg, theme_for_name(app.settings.theme))

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
		delete(app.settings.overlay_mode)
		app.settings.overlay_mode = strings.clone(string(v))
		app_save_settings()

	case Overlay_Bg_Selected:
		sync.guard(&app.mu)
		delete(app.settings.overlay_bg)
		app.settings.overlay_bg = strings.clone(string(v))
		app_save_settings()

	case Overlay_Count_Changed:
		sync.guard(&app.mu)
		app.settings.overlay_next_count = clamp(int(v), 1, 50)
		app_save_settings()

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
		delete(app.settings.obs_text_dir)
		app.settings.obs_text_dir = strings.clone(strings.trim_space(out.obs_text_dir_draft))
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
		delete(app.settings.obsws_host)
		app.settings.obsws_host = strings.clone(strings.trim_space(out.obsws_host_draft))
		app.settings.obsws_port = port
		delete(app.settings.obsws_password)
		app.settings.obsws_password = strings.clone(out.obsws_pass_draft)
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

gui_set_save_path :: proc(s: Gui, path: string) -> Gui {
	out := s
	sync.guard(&app.mu)
	app_set_save_path(path)
	app_save_settings()

	out.last_mtime = 0 // force the next poll to actually read
	out = gui_sync_expanded(out)

	if len(app.save_error) > 0 {
		return gui_toast(out, app.save_error, .Danger)
	}

	// A save with exactly one character can pick itself.
	active := 0
	only := -1
	for sl in app.slots {
		if !sl.active do continue
		active += 1
		only = sl.index
	}
	if active == 1 {
		app_set_active_slot(only)
		app_save_settings()
		out = gui_after_data_change(out)
		out.tab = .Checklist
		return gui_toast(out, fmt.tprintf("Tracking %s", app.slots[only].name), .Success)
	}

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
	for &reg in app.regions {
		for &b in reg.bosses {
			was, seen := old_killed[b.flag_id]
			if seen && was != b.killed {
				changed = true
				if b.killed do newly_killed += 1
			}
		}
	}

	if !changed do return out

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

theme_for_name :: proc(name: string) -> skald.Theme {
	switch name {
	case "light":
		return skald.theme_light()
	case "system":
		return skald.system_theme() == .Light ? skald.theme_light() : skald.theme_dark()
	case:
		return skald.theme_dark()
	}
}

on_system_theme_changed :: proc(t: skald.System_Theme) -> Msg {
	return Theme_Selected("system")
}
