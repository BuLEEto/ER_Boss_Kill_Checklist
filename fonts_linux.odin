#+build linux
package main

import "core:os"
import "core:strings"

// Ask fontconfig, which is what the browser inside OBS asks too — so the
// names it gives back are exactly the ones that will resolve in CSS,
// aliases ("sans-serif" → whatever the system picked) included.
//
// Shelling out rather than linking libfontconfig: it keeps the build free
// of another native dependency, and fc-list is present anywhere a desktop
// is. When it isn't, the caller falls back to a built-in list.
platform_font_families :: proc() -> []string {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = {"fc-list", ":", "family"}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)

	if err != nil || !state.success do return nil

	out := make([dynamic]string, 0, 256)

	// One font per line, each line a comma-separated list of the names
	// that font answers to, primary name first:
	//
	//   DejaVu Sans,DejaVu Sans Condensed
	//   Fira Code,Fira Code Light,Fira Code Medium,Fira Code SemiBold
	//
	// Only the first is taken. The rest are overwhelmingly weight and
	// width variants — style names rather than families — and keeping
	// them turned this machine's list from 283 entries into 2173, which
	// is a worse picker, not a more complete one. Anything left out can
	// still be typed, because the field is free-form.
	//
	// A comma can't appear in a family name, which is exactly why
	// fontconfig uses it as the separator.
	rest := string(stdout) // the iterator advances it, so it must be a local
	for line in strings.split_lines_iterator(&rest) {
		primary := line
		if comma := strings.index_byte(line, ','); comma >= 0 {
			primary = line[:comma]
		}
		name := strings.trim_space(primary)
		if len(name) == 0 do continue
		append(&out, strings.clone(name))
	}

	return font_names_finalize(out)
}
