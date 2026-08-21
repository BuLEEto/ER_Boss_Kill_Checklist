package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
KILL_BANNER_SECONDS_MIN     :: 2
KILL_BANNER_SECONDS_MAX     :: 30
KILL_BANNER_SECONDS_DEFAULT :: 6

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
//   6  region and appearance are per-integration rather than shared
//   7  attempts bookmark, kill banner, and the overlay card's own text size
//   8  obs-websocket removed; the single-value pages get per-page looks
SETTINGS_VERSION :: 8

// Which region an integration follows. One of these per integration
// rather than one shared between them: the OBS tab has a panel per
// integration, and a setting that lives on one panel but silently drives
// the other two is the thing people trip over. Independent also matches
// how they get used — someone running two integrations at once is
// usually showing different things in each, not the same thing twice.
//
//   "first"      the first area with anything left, in list order
//   "last_kill"  the area the most recent kill happened in
//   "pinned"     `name`, chosen by the user
//
// Pinned by name rather than index because an index only means something
// within one boss list.
Region_Choice :: struct {
	mode: string `json:"mode"`,
	name: string `json:"name"`,
}

// How one of the served pages looks. The overlay card and the individual
// widgets get one each, so they can differ — which is the usual case when
// both are on screen at once.
Appearance :: struct {
	accent:      string `json:"accent"`,
	text_color:  string `json:"text_color"`,
	font_family: string `json:"font_family"`,
	custom_css:  string `json:"custom_css"`,
	font_size:   int    `json:"font_size"`,
	outline:     bool   `json:"outline"`,
	align:       string `json:"align"`, // left | center | right
}

// The overlay card's natural text size. Everything inside the card is
// sized in em from here, so this is the one number that scales it.
OVERLAY_BASE_FONT_PX :: 13

// A widget source is one value standing alone on the canvas, so it starts
// big. The overlay card is a panel of many lines, so it starts at reading
// size — same control, two sensible defaults.
default_browser_appearance :: proc() -> Appearance {
	a := default_appearance()
	a.font_size = OVERLAY_BASE_FONT_PX
	return a
}

default_appearance :: proc() -> Appearance {
	return Appearance {
		accent     = "#c8a84e", // Erdtree gold, matching the app
		text_color = "#e0dcd0",
		font_size  = 28,
		outline    = true,
		align      = "left",
	}
}

appearance_apply_bounds :: proc(a: ^Appearance) {
	if a.font_size < 8 || a.font_size > 200 do a.font_size = 28
	if !is_hex_colour(a.accent) do a.accent = "#c8a84e"
	if !is_hex_colour(a.text_color) do a.text_color = "#e0dcd0"
	switch a.align {
	case "left", "center", "right": // fine
	case:                           a.align = "left"
	}
}

// A single-value page's own appearance, or the absence of one.
//
// `custom` off means the page follows the shared look and `look` is
// ignored; on means `look` is used whole. Storing the slug rather than
// relying on array position keeps someone's styling attached to the page
// they set it on even if Widget_Kind is reordered later.
Widget_Look :: struct {
	slug:   string     `json:"slug"`,
	custom: bool       `json:"custom"`,
	look:   Appearance `json:"look"`,
}

region_choice_apply_bounds :: proc(r: ^Region_Choice) {
	switch r.mode {
	case "first", "last_kill", "pinned": // fine
	case:                                r.mode = "first"
	}
	// A pin with nothing pinned is just auto.
	if r.mode == "pinned" && len(r.name) == 0 do r.mode = "first"
}

Settings :: struct {
	version: int `json:"version"`,

	// Save file + tracking
	save_path:    string `json:"save_path"`,
	active_slot:  int    `json:"active_slot"`,
	boss_list:    string `json:"boss_list"`,
	show_deaths:   bool  `json:"show_deaths"`,
	show_attempts: bool  `json:"show_attempts"`,
	show_session:  bool  `json:"show_session"`,
	poll_seconds: int    `json:"poll_seconds"`,

	// Web server — serves the OBS overlay and the mobile companion page
	server_enabled: bool `json:"server_enabled"`,
	server_port:    int  `json:"server_port"`,

	// Overlay defaults, mirrored into the URL the OBS tab hands out
	overlay_mode:       string `json:"overlay_mode"`,       // summary | next | region
	overlay_next_count: int    `json:"overlay_next_count"`,
	overlay_bg:         string `json:"overlay_bg"`,         // none | green | magenta

	// Per-integration region and look. Each OBS panel owns its own, so no
	// panel depends on a setting that lives on a different one.
	browser_region: Region_Choice `json:"browser_region"`,
	text_region:    Region_Choice `json:"text_region"`,
	ws_region:      Region_Choice `json:"ws_region"`,

	browser_look: Appearance `json:"browser_look"`,
	ws_look:      Appearance `json:"ws_look"`,

	// The area the last kill we actually witnessed happened in. Written
	// by the poller and shared by all three, because it's an observation
	// rather than a preference — the save records that a boss is dead,
	// never when or in what order, so this is the only way to know.
	last_kill_region: string `json:"last_kill_region"`,

	// OBS text-file output, for "Text (GDI+/FreeType)" sources set to
	// read from file
	obs_text_enabled: bool   `json:"obs_text_enabled"`,
	obs_text_dir:     string `json:"obs_text_dir"`,

	// Blank line between entries in the multi-line text files. OBS text
	// sources have no line-height setting — it's been a feature request
	// for years — so the only way to loosen them up is to write the extra
	// line ourselves. The served pages don't need this; they have CSS.
	text_roomy_lines: bool `json:"text_roomy_lines"`,

	// Per-page appearance overrides for the single-value pages.
	//
	// Whole-struct, not per-field: a page either follows ws_look or has a
	// look entirely of its own, seeded from the shared one when the user
	// first customises it. Per-field inheritance would need every setting
	// to carry a third "not set" state, and "why did that one not change?"
	// is a worse question to have to answer than "this page is customised".
	//
	// Fixed array rather than a slice, so settings stay allocation-free
	// apart from their strings; matched by `slug` on load rather than by
	// position, so reordering Widget_Kind can't shuffle someone's styling
	// onto the wrong page.
	widget_looks: [len(Widget_Kind)]Widget_Look `json:"widget_looks"`,

	// ---- Attempts ------------------------------------------------------
	//
	// Deaths since the last boss we watched fall. The save records the
	// total death count and which bosses are dead; it never records how
	// those two line up, so this bookmark is the only way to turn one into
	// the other. See app_attempts for what that does and doesn't mean.
	//
	// Bookmarked per slot, because a death count belongs to a character —
	// without the slot, switching character would subtract one Tarnished's
	// deaths from another's and print nonsense.
	attempts_slot: int `json:"attempts_slot"`, // -1 when nothing is bookmarked
	attempts_base: int `json:"attempts_base"`, // death count at the last kill

	// Boss-defeated banner on the overlay browser source.
	kill_banner_enabled: bool `json:"kill_banner_enabled"`,
	kill_banner_seconds: int  `json:"kill_banner_seconds"`,

	// GUI
	window_x:         int    `json:"window_x"`,
	window_y:         int    `json:"window_y"`,
	window_w:         int    `json:"window_w"`,
	window_h:         int    `json:"window_h"`,
	window_maximized: bool   `json:"window_maximized"`,
	// Where you were last time. The app already remembers the window, the
	// theme, the save and the boss list; coming back to the Setup tab you
	// were part-way through is the same courtesy. Stored as ints because
	// the tab enums are a GUI concern, and settings shouldn't depend on
	// them — bounds-checked against the real enums on the way in.
	last_tab:     int `json:"last_tab"`,
	last_obs_tab: int `json:"last_obs_tab"`,

	theme:            string `json:"theme"`,           // elden | dark | light | system
	ui_scale:         f32    `json:"ui_scale"`,        // text + spacing multiplier
	hide_completed:   bool   `json:"hide_completed"`,
}

default_settings :: proc() -> Settings {
	return Settings {
		version = SETTINGS_VERSION,

		active_slot  = -1,
		boss_list    = "standard",
		show_deaths   = false,
		show_attempts = true,
		show_session  = false,
		poll_seconds = POLL_SECONDS_DEFAULT,

		server_enabled = true,
		server_port    = 3000,

		overlay_mode        = "summary",
		overlay_next_count  = 8,
		overlay_bg          = "none",
		browser_region   = {mode = "first"},
		text_region      = {mode = "first"},
		ws_region        = {mode = "first"},
		browser_look     = default_browser_appearance(),
		ws_look          = default_appearance(),
		last_kill_region = "",

		obs_text_enabled = false,

		text_roomy_lines = true,

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

		s = decoded
		migrate_v5(&s, raw)
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
		&s.last_kill_region,
		&s.obs_text_dir,
		&s.theme,
		&s.browser_region.mode,
		&s.browser_region.name,
		&s.text_region.mode,
		&s.text_region.name,
		&s.ws_region.mode,
		&s.ws_region.name,
		&s.browser_look.accent,
		&s.browser_look.text_color,
		&s.browser_look.font_family,
		&s.browser_look.custom_css,
		&s.browser_look.align,
		&s.ws_look.accent,
		&s.ws_look.text_color,
		&s.ws_look.font_family,
		&s.ws_look.custom_css,
		&s.ws_look.align,
	}
	for f in fields {
		f^ = strings.clone(f^, allocator)
	}

	// The per-page looks carry strings too, and they're freed the same way
	// when a setting changes — so they have to be heap-owned like the rest.
	for &w in s.widget_looks {
		w.slug = strings.clone(w.slug, allocator)
		w.look.accent = strings.clone(w.look.accent, allocator)
		w.look.text_color = strings.clone(w.look.text_color, allocator)
		w.look.font_family = strings.clone(w.look.font_family, allocator)
		w.look.custom_css = strings.clone(w.look.custom_css, allocator)
		w.look.align = strings.clone(w.look.align, allocator)
	}
}

// One page's stored look. Slot i belongs to Widget_Kind(i), always —
// settings_normalise_widget_looks guarantees that at load, so this is a
// plain index with nothing to search and nothing to allocate.
//
// That matters more than it looks: this is read by the HTTP workers, which
// hold only a shared lock. An accessor that lazily filled in a missing
// slot would be writing under a read lock from several threads at once,
// which is how the array ended up with a page marked as customised that
// nobody had customised.
settings_widget_look :: proc(k: Widget_Kind) -> ^Widget_Look {
	return &app.settings.widget_looks[int(k)]
}

// What a page should actually be drawn with: its own look when it has
// one, otherwise the look shared by all of them.
settings_widget_appearance :: proc(k: Widget_Kind) -> Appearance {
	w := settings_widget_look(k)
	if w.custom do return w.look
	return app.settings.ws_look
}

// Put every stored look in the slot its page owns.
//
// The file records a slug per entry, so a settings file written before a
// Widget_Kind was added, removed or reordered still lands its styling on
// the right page. Anything whose slug isn't a page any more is dropped;
// pages with nothing stored get an empty slot. Runs once, at load, on the
// GUI thread — after which the array is only ever indexed.
settings_normalise_widget_looks :: proc(s: ^Settings) {
	stored := s.widget_looks
	s.widget_looks = {}

	for k in Widget_Kind {
		slug := widget_slug(k)
		for w in stored {
			if w.slug == slug {
				s.widget_looks[int(k)] = w
				break
			}
		}
	}
	// Deliberately not writing the slug back here. Every string in live
	// settings is heap-owned so that changing one can free the old value,
	// and widget_slug returns a literal — storing one would arm a delete
	// on a string literal, which is a segfault rather than a leak.
	// save_settings_file stamps the slugs onto its own copy instead.
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

	// v5 and earlier had one region and one appearance shared by all three
	// integrations. Nobody chose "shared" — it was just how it was built —
	// so every integration inherits what was there and they diverge only
	// when the user changes one.
	// v5 → v6 is handled separately in migrate_v5, which needs the raw
	// JSON: the keys it reads no longer exist on this struct, so by the
	// time the decoder is done they're already gone.
	// v7 adds the attempts bookmark and the kill banner. A decoded v6 file
	// leaves them zeroed, and zero is a real slot index — so these have to
	// be written rather than left to the decoder's defaults.
	if s.version < 7 {
		s.attempts_slot       = -1
		s.attempts_base       = 0
		s.kill_banner_enabled = true
		s.kill_banner_seconds = KILL_BANNER_SECONDS_DEFAULT
		s.show_attempts       = true

		// Until v7 this number only ever styled the widget sources, which
		// the overlay page hasn't got — so whatever is in the file was
		// chosen for something else and has never been seen on the card.
		// Start everyone at the card's natural size rather than suddenly
		// honouring it and blowing the overlay up on first launch.
		s.browser_look.font_size = OVERLAY_BASE_FONT_PX
	}

	s.version = SETTINGS_VERSION
}

// v5 and earlier had one region and one appearance shared by all three
// integrations. v6 gives each its own, and everyone inherits what was
// there — nobody chose "shared", it was just how it was built.
//
// This reads the raw JSON rather than the decoded struct because the keys
// it wants (overlay_region_mode, overlay_accent, and the rest) aren't
// fields any more. The decoder drops unknown keys silently, so anything
// migrating from them has to look at the bytes.
migrate_v5 :: proc(s: ^Settings, raw: []byte) {
	root, err := json.parse(raw, allocator = context.temp_allocator)
	if err != .None do return

	// Nothing to do for a file already at v6 or later.
	if json_int(root, "version") >= 6 do return

	region := Region_Choice {
		mode = json_string(root, "overlay_region_mode"),
		name = json_string(root, "overlay_region_name"),
	}
	if len(region.mode) == 0 {
		// v3 and earlier had no mode at all: a name meant "pinned".
		region.mode = len(region.name) > 0 ? "pinned" : "first"
	}

	look := default_appearance()
	if v := json_string(root, "overlay_accent"); len(v) > 0 do look.accent = v
	if v := json_string(root, "overlay_text_color"); len(v) > 0 do look.text_color = v
	if v := json_string(root, "overlay_font_family"); len(v) > 0 do look.font_family = v
	if v := json_string(root, "overlay_custom_css"); len(v) > 0 do look.custom_css = v
	if v := json_string(root, "overlay_align"); len(v) > 0 do look.align = v
	if v := json_int(root, "overlay_font_size"); v > 0 do look.font_size = int(v)
	look.outline = json_bool(root, "overlay_outline", true)

	roomy := json_bool(root, "obs_roomy_lines", true)

	s.browser_region, s.text_region, s.ws_region = region, region, region
	s.browser_look, s.ws_look = look, look
	s.text_roomy_lines = roomy
}

save_settings_file :: proc(s: Settings) -> os.Error {
	out := s
	out.version = SETTINGS_VERSION

	// Stamp each stored look with the page it belongs to. In memory the
	// slot's position is what identifies it; on disk the slug is, so a
	// later build that reorders or renames Widget_Kind can still put
	// everyone's styling back where it belongs. Safe to assign literals
	// here because `out` is a copy that's marshalled and dropped — nothing
	// ever frees these.
	for k in Widget_Kind {
		out.widget_looks[int(k)].slug = widget_slug(k)
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
	if s.overlay_next_count < 1 || s.overlay_next_count > 50 do s.overlay_next_count = 8

	switch s.overlay_mode {
	case "summary", "next", "region": // fine
	case:                             s.overlay_mode = "summary"
	}
	switch s.overlay_bg {
	case "none", "green", "magenta": // fine
	case:                            s.overlay_bg = "none"
	}
	if s.kill_banner_seconds < KILL_BANNER_SECONDS_MIN ||
	   s.kill_banner_seconds > KILL_BANNER_SECONDS_MAX {
		s.kill_banner_seconds = KILL_BANNER_SECONDS_DEFAULT
	}
	// A bookmark against a slot that isn't there any more is worse than
	// none: it would silently measure against another character.
	if s.attempts_slot < 0 || s.attempts_slot >= SLOT_COUNT {
		s.attempts_slot = -1
		s.attempts_base = 0
	}
	if s.attempts_base < 0 do s.attempts_base = 0
	if s.last_tab < 0 || s.last_tab >= len(Tab) do s.last_tab = 0
	if s.last_obs_tab < 0 || s.last_obs_tab >= len(Obs_Tab) do s.last_obs_tab = 0

	region_choice_apply_bounds(&s.browser_region)
	region_choice_apply_bounds(&s.text_region)
	region_choice_apply_bounds(&s.ws_region)
	appearance_apply_bounds(&s.browser_look)
	appearance_apply_bounds(&s.ws_look)
	settings_normalise_widget_looks(s)
	for &w in s.widget_looks {
		if w.custom do appearance_apply_bounds(&w.look)
	}

	switch s.theme {
	case "elden", "dark", "light", "system": // fine
	case:                                    s.theme = "elden"
	}

	// Absent in files written before the setting existed, where the JSON
	// decoder leaves the default in place — this only catches a hand-edit
	// that put it out of range.
	if s.ui_scale < UI_SCALE_MIN || s.ui_scale > UI_SCALE_MAX do s.ui_scale = 1.15

}

// "#rrggbb", and nothing else. These go straight into a stylesheet, so a
// value that isn't a colour would either break the rule it's in or, if it
// contained a brace, escape into rules of its own.
is_hex_colour :: proc(v: string) -> bool {
	if len(v) != 7 || v[0] != '#' do return false
	for i in 1 ..< 7 {
		c := v[i]
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex do return false
	}
	return true
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
