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
	{"character.txt",    "\"Tarnished — RL 150\""},
	{"next_boss.txt",    "the next boss still standing"},
	{"next_bosses.txt",  "the next few bosses, one per line"},
	{"region.txt",       "first unfinished region and its count"},
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

	total, killed := count_bosses(app.regions)
	remaining := total - killed
	percent := total > 0 ? killed * 100 / total : 0
	name, level := app_active_character()

	character := "No character"
	if len(name) > 0 {
		character = fmt.tprintf("%s — RL %d", name, level)
	}

	next := app_next_bosses(app.settings.overlay_next_count, context.temp_allocator)

	next_one := "All bosses defeated"
	if len(next) > 0 {
		next_one = fmt.tprintf("%s — %s", next[0].boss, next[0].place)
	}

	next_lines := make([dynamic]string, context.temp_allocator)
	for b in next {
		append(&next_lines, fmt.tprintf("%s — %s", b.boss, b.place))
	}
	next_many := len(next) > 0 ? obs_join_lines(next_lines[:]) : "All bosses defeated"

	region := "All regions cleared"
	region_bosses := "All regions cleared"
	if idx := app_focus_region(); idx >= 0 {
		r := &app.regions[idx]
		r_total, r_killed := count_region_bosses(r)
		region = fmt.tprintf("%s (%d/%d)", r.region_name, r_killed, r_total)

		rb := make([dynamic]string, context.temp_allocator)
		for &boss in r.bosses {
			if boss.killed do continue
			append(&rb, boss.boss)
		}
		region_bosses = obs_join_lines(rb[:])
	}

	// Every region, in order, the way the overlay's summary mode lists
	// them — so a text source can show the same breakdown.
	region_lines := make([dynamic]string, context.temp_allocator)
	for &r in app.regions {
		r_total, r_killed := count_region_bosses(&r)
		append(&region_lines, fmt.tprintf("%s %d/%d", r.region_name, r_killed, r_total))
	}
	all_regions := obs_join_lines(region_lines[:])

	contents := [?]string {
		fmt.tprintf("%d / %d bosses", killed, total),
		fmt.tprintf("%d", killed),
		fmt.tprintf("%d", total),
		fmt.tprintf("%d", remaining),
		fmt.tprintf("%d%%", percent),
		fmt.tprintf("%d", app.death_count),
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
