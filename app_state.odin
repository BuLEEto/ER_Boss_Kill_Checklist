package main

import "core:fmt"
import "core:strings"
import "core:sync"
import http "src/libs/http"

// ============================================================================
// Shared application state
//
// Threading contract — this is the whole of it:
//
//   * The GUI thread (Skald's main loop) is the ONLY writer. Every
//     mutation happens inside `update`, under `sync.guard(&app.mu)`.
//   * HTTP worker threads are readers. They hold a shared lock for as
//     long as they are building a response.
//   * The save-file poll runs on a Skald `cmd_thread` worker. That
//     worker touches nothing here — it is handed a path and an mtime by
//     value and returns bytes. Everything it produces is merged back on
//     the GUI thread.
//
// Anything that breaks those three rules is a data race, and Odin will
// not tell you about it.
// ============================================================================

App_State :: struct {
	// Live configuration. Mirrors what gets written to settings.json.
	settings:       Settings,
	boss_list_type: Boss_List_Type,

	// Tracked data
	regions:     []Region,
	bst_map:     BST_Map,
	save_file:   Save_File,
	slots:       []Character_Slot,
	death_count: u32,
	save_loaded: bool,

	// Last thing that went wrong loading a save, for display in the GUI.
	// Empty when all is well.
	save_error: string,

	// Guards everything above. Writers: the GUI thread only.
	mu: sync.RW_Mutex,

	// Server-sent events to the overlay / mobile pages. Has its own lock
	// because the poll path touches it while holding no other lock.
	sse_clients: [dynamic]^http.Response,
	sse_mutex:   sync.Mutex,

	// Templates, loaded once at startup
	tpl_overlay: ^http.Template,
	tpl_mobile:  ^http.Template,

	// Web server
	lan_ip:     string,
	server:     Server_Handle,
}

app: App_State

// ----------------------------------------------------------------------------
// Boss list
// ----------------------------------------------------------------------------

// Swap the active boss list. Frees the previous one — changing lists used
// to leak the whole region tree every time.
app_set_boss_list :: proc(t: Boss_List_Type) -> bool {
	new_regions, ok := load_boss_data(t)
	if !ok do return false

	free_regions(app.regions)
	app.regions = new_regions
	app.boss_list_type = t
	app.settings.boss_list = boss_list_name(t)

	// Kill flags are per-list, so recompute against the loaded save.
	app_update_boss_status()
	return true
}

// Slot names are heap-allocated by the parser, so the slice alone isn't
// enough to free — the old build leaked one set of them per poll.
free_character_slots :: proc(slots: []Character_Slot) {
	for sl in slots {
		if len(sl.name) > 0 do delete(sl.name)
	}
	delete(slots)
}

free_regions :: proc(regions: []Region) {
	for &r in regions {
		for &b in r.bosses {
			delete(b.boss)
			delete(b.place)
		}
		delete(r.bosses)
		delete(r.regions)
		delete(r.region_name)
	}
	delete(regions)
}

// ----------------------------------------------------------------------------
// Save file
// ----------------------------------------------------------------------------

// Open (or re-open) the configured save file and refresh boss status.
// Returns false with app.save_error set when it can't.
app_reload_save :: proc() -> bool {
	app_clear_save_error()

	if len(app.settings.save_path) == 0 {
		app_set_save_error("No save file selected")
		return false
	}

	if app.save_loaded {
		close_save_file(&app.save_file)
		app.save_loaded = false
	}

	save, ok := open_save_file(app.settings.save_path)
	if !ok {
		app_set_save_error(fmt.aprintf("Could not read %s", app.settings.save_path))
		return false
	}

	app.save_file = save
	app.save_loaded = true

	free_character_slots(app.slots)
	app.slots = get_character_slots(&app.save_file)

	app_update_boss_status()
	return true
}

// Recompute every boss's killed flag, plus the death count, from the
// currently loaded save and slot.
app_update_boss_status :: proc() {
	if !app.save_loaded || app.settings.active_slot < 0 do return

	event_flags, ef_offset := get_slot_event_flags(
		&app.save_file,
		app.settings.active_slot,
		app.bst_map,
	)
	if event_flags == nil {
		app_set_save_error(
			fmt.aprintf("No event flags in slot %d", app.settings.active_slot + 1),
		)
		return
	}

	for &r in app.regions {
		for &b in r.bosses {
			b.killed = check_event_flag(event_flags, b.flag_id, app.bst_map)
		}
	}

	app.death_count = get_death_count(&app.save_file, app.settings.active_slot, ef_offset)
}

app_set_save_error :: proc(msg: string) {
	app_clear_save_error()
	app.save_error = msg
}

app_clear_save_error :: proc() {
	if len(app.save_error) > 0 {
		delete(app.save_error)
		app.save_error = ""
	}
}

// ----------------------------------------------------------------------------
// Derived values
// ----------------------------------------------------------------------------

// Name and level of the active character, or empty/0 when nothing is
// loaded. Callers must already hold the lock.
app_active_character :: proc() -> (name: string, level: u32) {
	slot := app.settings.active_slot
	if !app.save_loaded || slot < 0 || slot >= len(app.slots) do return "", 0
	return app.slots[slot].name, app.slots[slot].level
}

// The next `count` bosses still standing, in region order.
app_next_bosses :: proc(count: int, allocator := context.allocator) -> []Boss_Ref {
	out := make([dynamic]Boss_Ref, 0, count, allocator)
	outer: for &r in app.regions {
		for &b in r.bosses {
			if b.killed do continue
			append(&out, Boss_Ref{boss = b.boss, place = b.place, region_name = r.region_name})
			if len(out) >= count do break outer
		}
	}
	return out[:]
}

Boss_Ref :: struct {
	boss:        string,
	place:       string,
	region_name: string,
}

// Index of the first region with anything left to kill, or -1.
app_first_incomplete_region :: proc() -> int {
	for &r, i in app.regions {
		total, killed := count_region_bosses(&r)
		if killed < total do return i
	}
	return -1
}

// The region every integration should be showing: the pinned one if the
// user chose it and it exists in the current boss list, otherwise the
// first unfinished one. Returns -1 when there's nothing to show.
//
// The pin is matched by name, so it survives switching boss lists — and
// falls back to auto rather than pointing somewhere arbitrary when the
// pinned region isn't in the list at all (pin Caelid, switch to DLC
// only).
app_focus_region :: proc() -> int {
	if len(app.settings.overlay_region_name) > 0 {
		for &r, i in app.regions {
			if r.region_name == app.settings.overlay_region_name do return i
		}
	}
	return app_first_incomplete_region()
}

// The pinned region's name if it's still valid, otherwise "" for auto.
// The GUI uses this so a stale pin shows as Auto rather than as a region
// that isn't in the list.
app_focus_region_name :: proc() -> string {
	if len(app.settings.overlay_region_name) == 0 do return ""
	for &r in app.regions {
		if r.region_name == app.settings.overlay_region_name {
			return app.settings.overlay_region_name
		}
	}
	return ""
}

// ----------------------------------------------------------------------------
// Settings <-> state
// ----------------------------------------------------------------------------

// Adopt a settings value wholesale: load its boss list, then its save.
// Used at startup and nowhere else — individual GUI edits go through the
// targeted setters so we don't reload a 25 MB save because someone
// dragged the poll-rate slider.
app_apply_settings :: proc(s: Settings) {
	app.settings = s
	settings_apply_bounds(&app.settings)

	wanted := boss_list_from_name(app.settings.boss_list)
	if wanted != app.boss_list_type {
		if regions, ok := load_boss_data(wanted); ok {
			free_regions(app.regions)
			app.regions = regions
			app.boss_list_type = wanted
		}
	}
	app.settings.boss_list = boss_list_name(app.boss_list_type)

	if len(app.settings.save_path) > 0 {
		app_reload_save()
	}
}

app_set_save_path :: proc(path: string) {
	if len(app.settings.save_path) > 0 do delete(app.settings.save_path)
	app.settings.save_path = strings.clone(path)
	// A new file means the old slot index is meaningless.
	app.settings.active_slot = -1
	app_reload_save()
}

app_set_active_slot :: proc(slot: int) {
	app.settings.active_slot = slot
	app_update_boss_status()
}

// Persist the current settings, reporting failure rather than swallowing
// it the way the old build did.
app_save_settings :: proc() {
	if err := save_settings_file(app.settings); err != nil {
		fmt.eprintfln("Could not write settings: %v", err)
	}
}
