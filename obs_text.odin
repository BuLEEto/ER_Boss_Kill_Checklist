package main

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// OBS text-file output
//
// The lowest-common-denominator OBS integration: write plain text files
// and let the user point "Text (GDI+)" / "Text (FreeType 2)" sources at
// them with "Read from file" ticked. OBS re-reads the file whenever it
// changes, so this needs no browser source, no websocket, no plugin, and
// works on every OBS version anyone still runs.
//
// Written from the GUI thread after each poll that changed something.
// ============================================================================

Obs_Text_File :: struct {
	name:        string,
	description: string,
}

OBS_TEXT_FILES :: [?]Obs_Text_File {
	{"progress.txt",     "\"42 / 165 bosses\""},
	{"killed.txt",       "bosses defeated, number only"},
	{"total.txt",        "bosses in the list, number only"},
	{"remaining.txt",    "bosses left, number only"},
	{"percent.txt",      "\"25%\""},
	{"deaths.txt",       "death count, number only"},
	{"attempts.txt",     "deaths since your last boss kill, number only"},
	{"session.txt",      "\"2 bosses · 31 deaths\" for this sitting"},
	{"character.txt",    "\"Tarnished — RL 150\""},
	{"next_boss.txt",    "the next boss still standing"},
	{"next_bosses.txt",  "the next few bosses, one per line"},
	{"region.txt",       "the focused region and its count"},
	{"region_bosses.txt","what's left in that region, one per line"},
	{"regions.txt",      "every region and its count, one per line"},
}

// Where files go when the user hasn't chosen a folder: an `obs` folder
// next to settings.json, which is guaranteed writable.
obs_text_default_dir :: proc(allocator := context.allocator) -> string {
	dir, err := settings_dir(context.temp_allocator)
	if err != nil do return ""
	return path_join({dir, "obs"}, allocator)
}

obs_text_dir :: proc(allocator := context.allocator) -> string {
	if len(app.settings.obs_text_dir) > 0 {
		return strings.clone(app.settings.obs_text_dir, allocator)
	}
	return obs_text_default_dir(allocator)
}

// Write every file. Cheap — ten short files — so there's no point being
// clever about which ones actually changed.
obs_text_write_all :: proc() -> os.Error {
	dir := obs_text_dir(context.temp_allocator)
	if len(dir) == 0 do return .Invalid_Path

	if mk := os.make_directory_all(dir); mk != nil && !os.is_directory(dir) {
		return mk
	}

	f := widget_facts(app.settings.text_region, app.settings.overlay_next_count)

	character := "No character"
	if f.has_character {
		character = widget_text(.Character, TPL_CHARACTER, f)
	}

	attempts_text := "—"
	if f.attempts_known {
		attempts_text = widget_text(.Attempts, TPL_ATTEMPTS, f)
	}

	next_one := "All bosses defeated"
	if f.has_next {
		next_one = widget_text(.Next, TPL_NEXT, f)
	}
	next_many := len(f.next_list) > 0 \
		? obs_join_lines(f.next_list, app.settings.text_roomy_lines) \
		: "All bosses defeated"

	region := "All regions cleared"
	region_bosses := "All regions cleared"
	if f.has_region {
		region = widget_text(.Region, TPL_REGION, f)
		region_bosses = obs_join_lines(f.region_bosses, app.settings.text_roomy_lines)
	}

	// Every region, in order, the way the overlay's summary mode lists
	// them — so a text source can show the same breakdown.
	all_regions := obs_join_lines(f.all_regions, app.settings.text_roomy_lines)

	contents := [?]string {
		widget_text(.Progress, TPL_PROGRESS, f),
		widget_text(.Killed, TPL_KILLED, f),
		widget_text(.Total, TPL_TOTAL, f),
		widget_text(.Remaining, TPL_REMAINING, f),
		widget_text(.Percent, TPL_PERCENT, f),
		widget_text(.Deaths, TPL_DEATHS, f),
		attempts_text,
		widget_text(.Session, TPL_SESSION, f),
		character,
		next_one,
		next_many,
		region,
		region_bosses,
		all_regions,
	}

	files := OBS_TEXT_FILES
	#assert(len(OBS_TEXT_FILES) == len(contents))

	first_err: os.Error
	for f, i in files {
		path := path_join({dir, f.name}, context.temp_allocator)
		// Not atomic on purpose: OBS polls these files, and a rename
		// under it reads as a delete + create on some platforms. A short
		// truncate-and-write window is the lesser evil for ~20 bytes.
		if err := os.write_entire_file(path, transmute([]u8)contents[i]); err != nil {
			if first_err == nil do first_err = err
		}
	}
	return first_err
}
