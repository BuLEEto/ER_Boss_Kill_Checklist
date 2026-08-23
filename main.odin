package main

import "core:fmt"
import "core:os"
import "gui:skald"
import http "src/libs/http"

APP_VERSION :: "2.1.1"

// ============================================================================
// Entry point
//
// Order matters here:
//
//   1. chdir to the executable's directory so bosses.json, templates/ and
//      static/ resolve however the app was launched (menu entry, symlink,
//      double-click).
//   2. Load the data files.
//   3. Load settings — from the user's config directory, so they survive
//      a restart even when the app is installed somewhere read-only.
//   4. Start the web server if it's enabled, on its own thread.
//   5. Hand the main thread to Skald.
//
// The old build did 1, 2, 4 and then blocked forever in the HTTP accept
// loop; the browser was the UI. Now the window is the UI and the server
// is a background service for OBS and phones.
// ============================================================================

main :: proc() {
	change_to_exe_dir()

	bst, bst_ok := load_bst_map("eventflag_bst.txt")
	if !bst_ok {
		fatal("Could not load eventflag_bst.txt — is it next to the executable?")
	}
	app.bst_map = bst

	regions, boss_ok := load_boss_data(.Standard)
	if !boss_ok {
		fatal("Could not load bosses.json — is it next to the executable?")
	}
	app.regions = regions
	app.boss_list_type = .Standard

	settings, settings_err := load_settings_file()
	if settings_err != nil {
		fmt.eprintfln("Could not read settings: %v (starting with defaults)", settings_err)
	}
	app_apply_settings(settings)

	// Seed the OBS text files right away when they're enabled, so a
	// restart doesn't leave OBS showing stale numbers until the next
	// boss dies.
	if app.settings.obs_text_enabled {
		if err := obs_text_write_all(); err != nil {
			fmt.eprintfln("Could not write the OBS text files: %v", err)
		}
	}

	if !load_templates() do return

	app.lan_ip = detect_lan_ip()

	if app.settings.server_enabled {
		if !server_start(&app.server, app.settings.server_port) {
			fmt.eprintln(app.server.error)
		}
	}

	print_banner()

	skald.run(skald.App(Gui, Msg){
		title = "Elden Ring Boss Checklist",
		size  = {1100, 760},
		theme = theme_for_name(app.settings.theme, app.settings.ui_scale),
		init  = gui_init,
		update = gui_update,
		view   = gui_view,
		// Read straight from settings rather than from a throwaway
		// gui_init() — building the state twice would leak the first
		// copy's draft strings.
		initial_window_state = saved_window_state(),
		on_window_state_change = on_window_changed,
		on_system_theme_change = on_system_theme_changed,
	})

	// Skald returns once the window closes.
	shutdown()
}

saved_window_state :: proc() -> skald.Window_State {
	return skald.Window_State {
		pos       = {i32(app.settings.window_x), i32(app.settings.window_y)},
		size      = {i32(app.settings.window_w), i32(app.settings.window_h)},
		maximized = app.settings.window_maximized,
	}
}

load_templates :: proc() -> bool {
	overlay, overlay_err := http.template_load("templates/overlay.html")
	if overlay_err != .None {
		fmt.eprintfln("Could not load templates/overlay.html: %v", overlay_err)
		return false
	}
	app.tpl_overlay = overlay

	mobile, mobile_err := http.template_load("templates/mobile.html")
	if mobile_err != .None {
		fmt.eprintfln("Could not load templates/mobile.html: %v", mobile_err)
		return false
	}
	app.tpl_mobile = mobile

	widget, widget_err := http.template_load("templates/widget.html")
	if widget_err != .None {
		fmt.eprintfln("Could not load templates/widget.html: %v", widget_err)
		return false
	}
	app.tpl_widget = widget
	return true
}

print_banner :: proc() {
	fmt.println("===========================================")
	fmt.println("  Elden Ring Boss Checklist", APP_VERSION)
	if server_is_running(&app.server) {
		fmt.printfln("  OBS overlay: http://localhost:%d/overlay", app.server.port)
		host := len(app.lan_ip) > 0 ? app.lan_ip : "localhost"
		fmt.printfln("  Mobile view: http://%s:%d/mobile", host, app.server.port)
	} else {
		fmt.println("  Web server:  off")
	}
	if path, err := settings_path(context.temp_allocator); err == nil {
		fmt.println("  Settings:   ", path)
	}
	fmt.println("===========================================")
}

shutdown :: proc() {
	obsws_disconnect()
	server_stop(&app.server)
	if app.save_loaded do close_save_file(&app.save_file)
	app_save_settings()
}

fatal :: proc(message: string) {
	fmt.eprintln(message)
	show_fatal_dialog(message)
	os.exit(1)
}

// ----------------------------------------------------------------------------
// Working directory
//
// core:os grew get_executable_directory / set_working_directory, so this
// no longer needs the per-platform foreign imports the old build had.
// ----------------------------------------------------------------------------

change_to_exe_dir :: proc() {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return
	os.set_working_directory(dir)
}

// detect_lan_ip stays platform-specific — see platform_linux.odin /
// platform_windows.odin.
