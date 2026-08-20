package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sb "src/libs/sbcrypto"

// ============================================================================
// Settings
//
// Settings live in the per-user config directory, NOT next to the
// executable:
//
//   Linux    $XDG_CONFIG_HOME/er-boss-checklist/settings.json
//            (~/.config/er-boss-checklist/settings.json)
//   Windows  %APPDATA%\er-boss-checklist\settings.json
//
// The old build wrote settings.json into the executable's own directory.
// That silently failed for anyone running the packaged build, because
// /opt/er-boss-checklist (and Program Files) are not user-writable — and
// the write result was discarded, so nothing ever said so. Hence
// "it forgets my save file every time I start it".
//
// Writes go through a temp file + rename so a crash mid-write can't
// leave a truncated settings.json behind.
// ============================================================================

APP_CONFIG_DIR :: "er-boss-checklist"
SETTINGS_FILE :: "settings.json"

// How often the save file is checked. The floor is 5s because Elden Ring
// writes its save on its own schedule — polling faster can't surface a
// kill any sooner, it just offers precision the game doesn't provide.
// Each poll is an mtime check; the 25 MB read only happens when that
// changed.
POLL_SECONDS_MIN :: 5
POLL_SECONDS_MAX :: 60
POLL_SECONDS_DEFAULT :: 5

// Bumped when a field changes meaning and needs migrating. Unknown-but-
// newer versions are still loaded; fields we don't recognise are ignored
// by the JSON decoder, and fields we expect but are absent keep the
// defaults set up in default_settings().
//
//   1  first version written to the config directory
//   2  "elden" replaced "dark" as the default theme
//   3  obsws password encrypted at rest, under a new key name
//   4  region pinned by name rather than index; per-source obsws toggles
//   5  region selection grew a mode, so "pinned" is distinct from "auto"
SETTINGS_VERSION :: 5

Settings :: struct {
	version: int `json:"version"`,

	// Save file + tracking
	save_path:    string `json:"save_path"`,
	active_slot:  int    `json:"active_slot"`,
	boss_list:    string `json:"boss_list"`,
	show_deaths:  bool   `json:"show_deaths"`,
	poll_seconds: int    `json:"poll_seconds"`,

	// Web server — serves the OBS overlay and the mobile companion page
	server_enabled: bool `json:"server_enabled"`,
	server_port:    int  `json:"server_port"`,

	// Overlay defaults, mirrored into the URL the OBS tab hands out
	overlay_mode:       string `json:"overlay_mode"`,       // summary | next | region
	overlay_next_count: int    `json:"overlay_next_count"`,
	overlay_bg:         string `json:"overlay_bg"`,         // none | green | magenta
	overlay_align:      string `json:"overlay_align"`,      // left | center | right

	// Which region the Region overlay mode, ER Region and region.txt all
	// follow:
	//
	//   "first"      the first area with anything left, in list order
	//   "last_kill"  the area the most recent kill happened in
	//   "pinned"     overlay_region_name, chosen by the user
	//
	// The pin is stored by name rather than index because an index only
	// means anything within one boss list — switching from All bosses to
	// DLC only would otherwise silently repoint it at a different area.
	//
	// (v3 and earlier wrote an unused "overlay_region" integer here. The
	// decoder ignores the leftover key.)
	overlay_region_mode: string `json:"overlay_region_mode"`,
	overlay_region_name: string `json:"overlay_region_name"`,

	// The area the last kill we actually witnessed happened in. Written
	// by the poller, persisted so "where I last killed" survives a
	// restart — the save file records that a boss is dead, never when or
	// in what order, so this is the only way to know.
	last_kill_region: string `json:"last_kill_region"`,

	// OBS text-file output, for "Text (GDI+/FreeType)" sources set to
	// read from file
	obs_text_enabled: bool   `json:"obs_text_enabled"`,
	obs_text_dir:     string `json:"obs_text_dir"`,

	// obs-websocket v5
	obsws_enabled:           bool   `json:"obsws_enabled"`,
	obsws_host:              string `json:"obsws_host"`,
	obsws_port:              int    `json:"obsws_port"`,
	obsws_remember_password: bool   `json:"obsws_remember_password"`,

	// Which of the six text sources the app creates and updates in OBS.
	// Named individually rather than packed into a bitmask so the file
	// stays legible — this is a config someone might open and edit.
	obsws_send_progress:      bool `json:"obsws_send_progress"`,
	obsws_send_next_boss:     bool `json:"obsws_send_next_boss"`,
	obsws_send_deaths:        bool `json:"obsws_send_deaths"`,
	obsws_send_character:     bool `json:"obsws_send_character"`,
	obsws_send_region:        bool `json:"obsws_send_region"`,
	obsws_send_region_bosses: bool `json:"obsws_send_region_bosses"`,

	// The overlay page itself, as a browser source. Off by default: it
	// overlaps what the individual sources show, so having both appear
	// uninvited would be a mess.
	obsws_send_overlay: bool `json:"obsws_send_overlay"`,

	// What the individual sources are made of:
	//
	//   "text"  OBS text sources. Cheap — no browser instance — but OBS
	//           gives them no alignment and no line height.
	//   "web"   One small browser source each, pointed at /widget. Real
	//           CSS: alignment, line height, restyling via Custom CSS.
	//           Costs a Chromium instance per source.
	obsws_source_style: string `json:"obsws_source_style"`,

	// Blank line between entries in the multi-line outputs. OBS text
	// sources have no line-height setting — it's been a feature request
	// for years — so the only way to loosen them up is to send the extra
	// line ourselves.
	obs_roomy_lines: bool `json:"obs_roomy_lines"`,
	// Encrypted at rest — see obsws_password_enc below and
	// src/libs/sbcrypto. Held in memory decrypted.
	obsws_password:          string `json:"obsws_password_enc"`,

	// GUI
	window_x:         int    `json:"window_x"`,
	window_y:         int    `json:"window_y"`,
	window_w:         int    `json:"window_w"`,
	window_h:         int    `json:"window_h"`,
	window_maximized: bool   `json:"window_maximized"`,
	theme:            string `json:"theme"`,           // elden | dark | light | system
	ui_scale:         f32    `json:"ui_scale"`,        // text + spacing multiplier
	hide_completed:   bool   `json:"hide_completed"`,
}

default_settings :: proc() -> Settings {
	return Settings {
		version = SETTINGS_VERSION,

		active_slot  = -1,
		boss_list    = "standard",
		show_deaths  = false,
		poll_seconds = POLL_SECONDS_DEFAULT,

		server_enabled = true,
		server_port    = 3000,

		overlay_mode        = "summary",
		overlay_next_count  = 8,
		overlay_bg          = "none",
		overlay_align       = "left",
		overlay_region_mode = "first",
		overlay_region_name = "",
		last_kill_region    = "",

		obs_text_enabled = false,

		obsws_enabled = false,
		obsws_host    = "127.0.0.1",
		obsws_port    = 4455,

		obsws_send_progress      = true,
		obsws_send_next_boss     = true,
		obsws_send_deaths        = true,
		obsws_send_character     = true,
		obsws_send_region        = true,
		obsws_send_region_bosses = true,
		obsws_send_overlay       = false,
		obsws_source_style       = "text",

		obs_roomy_lines = true,

		theme    = "elden",
		ui_scale = 1.15, // Skald's stock 14px body text is small on a big display
	}
}

// ----------------------------------------------------------------------------
// Paths
// ----------------------------------------------------------------------------

// filepath.join returns an allocator error we have nothing useful to do
// with — an OOM here means the process is already finished. Fold it away
// so the path-building code below stays readable.
path_join :: proc(parts: []string, allocator := context.allocator) -> string {
	joined, _ := filepath.join(parts, allocator)
	return joined
}

// Directory holding settings.json and any other per-user state. Created
// on demand. Falls back to the working directory if the platform can't
// tell us where the config root is — better a settings file in an odd
// place than no persistence at all.
settings_dir :: proc(allocator := context.allocator) -> (dir: string, err: os.Error) {
	root := os.user_config_dir(allocator, roaming = true) or_return
	defer delete(root, allocator)

	dir = path_join({root, APP_CONFIG_DIR}, allocator)
	// "already there" is success. make_directory_all reports that as a
	// platform errno rather than a portable value, so ask the filesystem
	// instead of trying to match error codes per-OS.
	if mk_err := os.make_directory_all(dir); mk_err != nil && !os.is_directory(dir) {
		delete(dir, allocator)
		return "", mk_err
	}
	return dir, nil
}

settings_path :: proc(allocator := context.allocator) -> (path: string, err: os.Error) {
	dir := settings_dir(allocator) or_return
	defer delete(dir, allocator)
	return path_join({dir, SETTINGS_FILE}, allocator), nil
}

// ----------------------------------------------------------------------------
// Migration from the old exe-relative location
// ----------------------------------------------------------------------------

// Older versions kept settings.json beside the executable. If one is
// there and we don't have a config-dir copy yet, adopt it so upgrading
// users keep their save path and slot. The original is left in place —
// it may sit in a read-only install directory, and deleting it buys us
// nothing.
migrate_legacy_settings :: proc(dest: string) {
	if os.exists(dest) do return

	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil do return

	legacy := path_join({exe_dir, SETTINGS_FILE}, context.temp_allocator)
	if !os.exists(legacy) do return

	raw, read_err := os.read_entire_file(legacy, context.temp_allocator)
	if read_err != nil do return

	if write_err := write_file_atomic(dest, raw); write_err != nil {
		fmt.eprintfln("Could not migrate settings from %s: %v", legacy, write_err)
		return
	}
	fmt.printfln("Migrated settings from %s to %s", legacy, dest)
}

// ----------------------------------------------------------------------------
// Load / save
// ----------------------------------------------------------------------------

// Reads settings from disk. Missing file is not an error — it just means
// first run, and the caller gets defaults. A malformed file IS reported,
// so a hand-edited settings.json that won't parse says so instead of
// quietly resetting everything.
load_settings_file :: proc(allocator := context.allocator) -> (s: Settings, err: os.Error) {
	s = default_settings()

	path, path_err := settings_path(context.temp_allocator)
	if path_err != nil {
		settings_own_strings(&s, allocator)
		return s, path_err
	}
	migrate_legacy_settings(path)

	// First run: no file, no complaint. Checking existence up front keeps
	// this portable — a missing file surfaces as a platform errno, not as
	// a value we can match on.
	if os.exists(path) {
		raw, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			settings_own_strings(&s, allocator)
			return s, read_err
		}

		// Decode into a fresh value so absent keys keep their defaults.
		decoded := default_settings()
		if jerr := json.unmarshal(raw, &decoded, allocator = context.temp_allocator); jerr != nil {
			fmt.eprintfln("settings.json could not be parsed (%v) — using defaults", jerr)
			settings_own_strings(&s, allocator)
			return s, nil
		}

		// A password that won't open is one this machine didn't write:
		// another machine's config, a corrupted file, or a plaintext
		// password from a version before this field was encrypted. In
		// every case the right move is to drop it and let the user
		// re-enter it once.
		if plain, ok := sb.decrypt_string(decoded.obsws_password, context.temp_allocator); ok {
			decoded.obsws_password = plain
		} else {
			decoded.obsws_password = ""
		}

		s = decoded
	}

	migrate_settings(&s)
	settings_apply_bounds(&s)

	// Last, and on every path out of here: see settings_own_strings.
	settings_own_strings(&s, allocator)
	return s, nil
}

// Make every string in `s` heap-owned by `allocator`.
//
// This has to be the last thing load does, and it has to happen on every
// return path, because the app frees these strings when the user changes
// a setting. Anything still pointing at a string literal — and there are
// three sources of those: default_settings, migrate_settings, and
// settings_apply_bounds clamping a bad value — would have free() called
// on a pointer into read-only memory.
//
// That is not a leak-shaped bug, it's an abort. It bit "where I last
// killed" hardest because last_kill_region defaults to a literal "" and
// the first kill of the session frees it, but the same landmine sat
// under theme, overlay mode, overlay background, obs-websocket host and
// the text-file directory.
//
// Strings coming out of json.unmarshal live in the temp arena, so they
// need copying here regardless.
settings_own_strings :: proc(s: ^Settings, allocator := context.allocator) {
	fields := [?]^string {
		&s.save_path,
		&s.boss_list,
		&s.overlay_mode,
		&s.overlay_bg,
		&s.overlay_align,
		&s.obsws_source_style,
		&s.overlay_region_mode,
		&s.overlay_region_name,
		&s.last_kill_region,
		&s.obs_text_dir,
		&s.obsws_host,
		&s.obsws_password,
		&s.theme,
	}
	for f in fields {
		f^ = strings.clone(f^, allocator)
	}
}

// Replace a settings string, freeing what was there.
//
// Every string in the live settings is heap-owned (settings_own_strings
// guarantees it at load), so the delete is always safe — and routing
// changes through here keeps it that way rather than relying on each
// call site to remember the delete/clone pair.
settings_set_string :: proc(dst: ^string, value: string) {
	if dst^ == value do return
	delete(dst^)
	dst^ = strings.clone(value)
}


// Bring an older settings file forward. Runs against the decoded value
// before it's cloned, so it's free to swap string fields around.
migrate_settings :: proc(s: ^Settings) {
	// v1 wrote theme "dark" as its default, which nobody chose — it was
	// simply what the field started as. v2's default is the Elden Ring
	// palette, so move those files over. Anyone who picked light or
	// follow-system asked for it and is left alone.
	if s.version < 2 && s.theme == "dark" {
		s.theme = "elden"
	}

	// v4 had no mode: a non-empty region name was the only way to say
	// "pinned", so that's what one means.
	if s.version < 5 && len(s.overlay_region_mode) == 0 {
		s.overlay_region_mode = len(s.overlay_region_name) > 0 ? "pinned" : "first"
	}
	s.version = SETTINGS_VERSION
}

save_settings_file :: proc(s: Settings) -> os.Error {
	out := s
	out.version = SETTINGS_VERSION

	// The password is the one field that never goes to disk as typed.
	// encrypt_string returns "" if this machine can't produce a key, in
	// which case we store nothing rather than falling back to plaintext.
	if out.obsws_remember_password {
		out.obsws_password = sb.encrypt_string(out.obsws_password, context.temp_allocator)
	} else {
		out.obsws_password = ""
	}

	data, jerr := json.marshal(out, {pretty = true}, context.temp_allocator)
	if jerr != nil {
		return .Invalid_File // marshal failure is a programming error, not an IO one
	}

	path := settings_path(context.temp_allocator) or_return
	return write_file_atomic(path, data)
}

// Write via <path>.tmp + rename so readers never see a half-written file.
write_file_atomic :: proc(path: string, data: []byte) -> os.Error {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	os.write_entire_file(tmp, data) or_return

	if err := os.rename(tmp, path); err != nil {
		// Windows rename onto an existing file fails; clear and retry.
		os.remove(path)
		os.rename(tmp, path) or_return
	}
	return nil
}

// Clamp anything a hand-edited file could put out of range, so bad input
// degrades to a working app rather than a broken one.
settings_apply_bounds :: proc(s: ^Settings) {
	if s.poll_seconds < POLL_SECONDS_MIN || s.poll_seconds > POLL_SECONDS_MAX {
		s.poll_seconds = POLL_SECONDS_DEFAULT
	}
	if s.server_port < 1 || s.server_port > 65535 do s.server_port = 3000
	if s.obsws_port < 1 || s.obsws_port > 65535 do s.obsws_port = 4455
	if s.overlay_next_count < 1 || s.overlay_next_count > 50 do s.overlay_next_count = 8

	switch s.overlay_mode {
	case "summary", "next", "region": // fine
	case:                             s.overlay_mode = "summary"
	}
	switch s.overlay_bg {
	case "none", "green", "magenta": // fine
	case:                            s.overlay_bg = "none"
	}
	switch s.overlay_align {
	case "left", "center", "right": // fine
	case:                           s.overlay_align = "left"
	}
	switch s.obsws_source_style {
	case "text", "web": // fine
	case:               s.obsws_source_style = "text"
	}
	switch s.theme {
	case "elden", "dark", "light", "system": // fine
	case:                                    s.theme = "elden"
	}
	if len(s.obsws_host) == 0 do s.obsws_host = "127.0.0.1"

	// Absent in files written before the setting existed, where the JSON
	// decoder leaves the default in place — this only catches a hand-edit
	// that put it out of range.
	if s.ui_scale < UI_SCALE_MIN || s.ui_scale > UI_SCALE_MAX do s.ui_scale = 1.15

	switch s.overlay_region_mode {
	case "first", "last_kill", "pinned": // fine
	case:                                s.overlay_region_mode = "first"
	}
	// A pin with nothing pinned is just auto.
	if s.overlay_region_mode == "pinned" && len(s.overlay_region_name) == 0 {
		s.overlay_region_mode = "first"
	}
}

// ----------------------------------------------------------------------------
// Boss list name <-> enum
// ----------------------------------------------------------------------------

boss_list_from_name :: proc(name: string) -> Boss_List_Type {
	switch name {
	case "hardlock":        return .Hardlock
	case "remembrance":     return .Remembrance
	case "remembrance_dlc": return .Remembrance_DLC
	case "great_runes":     return .Great_Runes
	case "main_story":      return .Main_Story
	case "dlc_only":        return .DLC_Only
	case:                   return .Standard
	}
}

boss_list_name :: proc(t: Boss_List_Type) -> string {
	switch t {
	case .Hardlock:        return "hardlock"
	case .Remembrance:     return "remembrance"
	case .Remembrance_DLC: return "remembrance_dlc"
	case .Great_Runes:     return "great_runes"
	case .Main_Story:      return "main_story"
	case .DLC_Only:        return "dlc_only"
	case .Standard:        return "standard"
	}
	return "standard"
}

boss_list_label :: proc(t: Boss_List_Type) -> string {
	switch t {
	case .Hardlock:        return "Hardlock (ranked by difficulty)"
	case .Remembrance:     return "Remembrance bosses"
	case .Remembrance_DLC: return "Remembrance bosses + DLC"
	case .Great_Runes:     return "Great Rune bearers"
	case .Main_Story:      return "Main story only"
	case .DLC_Only:        return "DLC only"
	case .Standard:        return "All bosses"
	}
	return "All bosses"
}
