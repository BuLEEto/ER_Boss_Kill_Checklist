package main

import "core:testing"

// ============================================================================
// The obs-websocket source text
//
// The one surface that can't be diffed against a running build, because it
// needs a live OBS on the other end of a socket. So it gets pinned here
// instead: these strings are exactly what the pre-unification code produced,
// transcribed from it rather than from the new implementation.
//
// They matter because the websocket sources are the only ones that label
// themselves — "Deaths: 57" rather than "57" — and that difference is easy to
// erase by accident when tidying three formatters into one.
// ============================================================================

// File scope so slicing it is safe to return — a slice of a local array
// would point at a dead stack frame, which Odin rejects outright.
@(private = "file")
SAMPLE_REGION_BOSSES := [?]string{"Nox Swordstress", "Commander O'Neil"}

@(private = "file")
sample :: proc() -> Widget_Facts {
	f := Widget_Facts {
		killed = 12,
		total = 207,
		remaining = 195,
		percent = 5,
		deaths = 24,
		attempts = 7,
		attempts_known = true,
		character_name = "Nebu Moo",
		character_level = 140,
		has_character = true,
		session = "0 bosses · 0 deaths",
		next_boss = "Soldier of Godrick",
		next_place = "Stranded Graveyard",
		has_next = true,
		region_name = "Caelid",
		region_killed = 3,
		region_total = 15,
		has_region = true,
	}
	f.region_bosses = SAMPLE_REGION_BOSSES[:]
	return f
}

@(test)
obsws_text_labels_itself :: proc(t: ^testing.T) {
	f := sample()

	testing.expect_value(t, obsws_source_text(.Progress, f, false), "12 / 207 bosses")
	testing.expect_value(t, obsws_source_text(.Deaths, f, false), "Deaths: 24")
	testing.expect_value(t, obsws_source_text(.Attempts, f, false), "Attempt 7")
	testing.expect_value(t, obsws_source_text(.Session, f, false), "0 bosses · 0 deaths")
	testing.expect_value(t, obsws_source_text(.Character, f, false), "Nebu Moo — RL 140")
	testing.expect_value(
		t, obsws_source_text(.Next_Boss, f, false),
		"Soldier of Godrick — Stranded Graveyard",
	)
	testing.expect_value(t, obsws_source_text(.Region, f, false), "Caelid (3/15)")
}

@(test)
obsws_text_empty_states :: proc(t: ^testing.T) {
	f: Widget_Facts // everything absent

	// Each of these used to be a separate literal in obs_ws.odin. They are
	// what goes on screen when a character hasn't been picked yet or the
	// save has nothing left in it, so they're worth holding still.
	testing.expect_value(t, obsws_source_text(.Next_Boss, f, false), "All bosses defeated")
	testing.expect_value(t, obsws_source_text(.Character, f, false), "No character")
	testing.expect_value(t, obsws_source_text(.Region, f, false), "All regions cleared")
	testing.expect_value(t, obsws_source_text(.Region_Bosses, f, false), "All regions cleared")
	testing.expect_value(t, obsws_source_text(.Attempts, f, false), "Attempt —")
	testing.expect_value(t, obsws_source_text(.Progress, f, false), "0 / 0 bosses")
}

@(test)
obsws_region_list_honours_roomy_lines :: proc(t: ^testing.T) {
	f := sample()

	tight := obsws_source_text(.Region_Bosses, f, false)
	roomy := obsws_source_text(.Region_Bosses, f, true)

	testing.expect_value(t, tight, "Nox Swordstress\nCommander O'Neil")
	testing.expectf(
		t, len(roomy) > len(tight),
		"roomy spacing should add the blank line OBS text sources can't do themselves",
	)
}

@(test)
obsws_cleared_region_is_not_the_no_region_message :: proc(t: ^testing.T) {
	// A region that exists but has nothing left is not the same as having no
	// region at all, and the old code distinguished them: an empty list joins
	// to an empty string rather than falling back to "All regions cleared".
	f := sample()
	f.region_bosses = {}

	testing.expect_value(t, obsws_source_text(.Region_Bosses, f, false), "")
}
