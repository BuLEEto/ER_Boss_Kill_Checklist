package main

import "core:strings"
import "core:testing"

// ============================================================================
// Stale poll results
//
// A save poll runs on a worker and can still be reading when the user picks a
// different save. Before Poll_Done carried its path, that result was applied
// regardless: the old file's characters replaced app.slots while active_slot
// still pointed at the slot chosen in the new file, and the app quietly showed
// a different character than the one selected.
//
// The race is impractical to provoke on demand, so the guard is tested
// directly instead.
// ============================================================================

// settings.save_path is heap-owned — settings_set_string deletes it before
// replacing it. Assigning a literal would arm a free() of .rodata for any
// later test that reached app_set_save_path, so these clone it too.
@(private = "file")
set_current_save :: proc(path: string) {
	delete(app.settings.save_path)
	app.settings.save_path = strings.clone(path)
}

@(private = "file")
done :: proc(path: string, mtime: i64) -> Poll_Done {
	// Heap-allocated: apply_poll_result owns and frees these.
	return Poll_Done{ok = true, mtime = mtime, path = strings.clone(path)}
}

@(test)
a_poll_for_another_save_is_discarded :: proc(t: ^testing.T) {
	set_current_save("/saves/B.sl2")

	s: Gui
	s.last_mtime = 999

	out := apply_poll_result(s, done("/saves/A.sl2", 12345))

	// Untouched: a result from the file we are no longer on must not be
	// allowed to move the clock forward either, or the next poll of the
	// real file could be skipped as "unchanged".
	testing.expect_value(t, out.last_mtime, i64(999))
}

@(test)
a_poll_for_the_current_save_is_accepted :: proc(t: ^testing.T) {
	set_current_save("/saves/B.sl2")

	s: Gui
	s.last_mtime = 999

	// unchanged = true stops it before anything needs a real save file.
	r := done("/saves/B.sl2", 12345)
	r.unchanged = true
	out := apply_poll_result(s, r)

	testing.expect_value(t, out.last_mtime, i64(12345))
}

@(test)
a_result_with_no_path_is_still_accepted :: proc(t: ^testing.T) {
	// Defensive: nothing should produce one now, but an empty path must
	// mean "unknown, let it through" rather than silently dropping every
	// poll if a future return path forgets to stamp it.
	set_current_save("/saves/B.sl2")

	s: Gui
	s.last_mtime = 999

	out := apply_poll_result(s, Poll_Done{ok = true, unchanged = true, mtime = 777})

	testing.expect_value(t, out.last_mtime, i64(777))
}
