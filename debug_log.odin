package main

import "core:fmt"
import "core:os"
import "core:time"

// ============================================================================
// Opt-in tracing
//
// Set ERBC_DEBUG=1 and every change to the save file, the character slot and
// the poll result is written to stderr with a timestamp. Off by default and
// costs a bool check when off.
//
// It exists because "my character sometimes changes on its own" is the kind
// of report that can't be chased by reading code — the interesting part is
// the order things happened in, across a background poll and a user click,
// which only a log can show.
// ============================================================================

@(private = "file")
debug_on := false

debug_init :: proc() {
	value, found := os.lookup_env("ERBC_DEBUG", context.allocator)
	if found {
		defer delete(value)
		debug_on = value != "" && value != "0"
	}
	if debug_on {
		fmt.eprintfln("[trace] on — save path, character slot and poll results")
	}
}

debug_log :: proc(format: string, args: ..any) {
	if !debug_on do return

	now := time.now()
	h, m, s := time.clock_from_time(now)
	ms := (time.to_unix_nanoseconds(now) / 1_000_000) % 1000

	fmt.eprintf("[trace %02d:%02d:%02d.%03d] ", h, m, s, ms)
	fmt.eprintfln(format, ..args)
}
