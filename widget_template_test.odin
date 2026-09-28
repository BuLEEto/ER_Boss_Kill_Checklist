package main

import "core:strings"
import "core:testing"

// ============================================================================
// Template expansion
//
// The input here is whatever a user typed into a text box, so most of these
// are about what happens when it isn't valid rather than when it is.
// ============================================================================

@(private = "file")
facts :: proc() -> Widget_Facts {
	return Widget_Facts {
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
}

@(test)
defaults_reproduce_the_original_wording :: proc(t: ^testing.T) {
	f := facts()

	// These are the strings the app shipped before templates existed. If a
	// default is ever "improved", it changes what is already on someone's
	// stream — so they are pinned.
	testing.expect_value(t, widget_expand(TPL_PROGRESS, f), "12 / 207 bosses")
	testing.expect_value(t, widget_expand(TPL_PERCENT, f), "5%")
	testing.expect_value(t, widget_expand(TPL_CHARACTER, f), "Nebu Moo — RL 140")
	testing.expect_value(t, widget_expand(TPL_NEXT, f), "Soldier of Godrick — Stranded Graveyard")
	testing.expect_value(t, widget_expand(TPL_REGION, f), "Caelid (3/15)")
	testing.expect_value(t, widget_expand(TPL_WS_DEATHS, f), "Deaths: 24")
	testing.expect_value(t, widget_expand(TPL_WS_ATTEMPTS, f), "Attempt 7")
}

@(test)
a_user_template_substitutes :: proc(t: ^testing.T) {
	f := facts()

	testing.expect_value(
		t, widget_expand("I have rekt {killed} of {total} bosses!", f),
		"I have rekt 12 of 207 bosses!",
	)
}

@(test)
emoji_and_punctuation_survive :: proc(t: ^testing.T) {
	f := facts()

	// Byte-copied, not reformatted — the whole reason expansion is plain
	// string replacement rather than fmt.
	testing.expect_value(
		t, widget_expand("💀 {killed}/{total} — 100% done? no", f),
		"💀 12/207 — 100% done? no",
	)
}

@(test)
a_percent_sign_is_not_a_format_verb :: proc(t: ^testing.T) {
	f := facts()

	// Handing a user string to fmt as its format would make these eat the
	// arguments after them, or crash. They are ordinary characters here.
	testing.expect_value(t, widget_expand("100%% sure", f), "100%% sure")
	testing.expect_value(t, widget_expand("%d %s %v", f), "%d %s %v")
}

@(test)
unknown_placeholders_stay_visible :: proc(t: ^testing.T) {
	f := facts()

	// Left as typed rather than blanked. Blanking makes text vanish on
	// stream with nothing to indicate why; this is self-evidently a typo the
	// moment the preview renders it.
	testing.expect_value(t, widget_expand("{kils} of {total}", f), "{kils} of 207")
	testing.expect_value(t, widget_expand("{}", f), "{}")
	testing.expect_value(t, widget_expand("{KILLED}", f), "{KILLED}")
}

@(test)
malformed_braces_do_not_eat_text :: proc(t: ^testing.T) {
	f := facts()

	// An unclosed brace is the state of every template halfway through being
	// typed, so it must not swallow what follows.
	testing.expect_value(t, widget_expand("{killed", f), "{killed")
	testing.expect_value(t, widget_expand("{killed} and {", f), "12 and {")
	testing.expect_value(t, widget_expand("}{", f), "}{")
	testing.expect_value(t, widget_expand("", f), "")
}

@(test)
empty_template_and_no_placeholders :: proc(t: ^testing.T) {
	f := facts()

	testing.expect_value(t, widget_expand("just words", f), "just words")
	testing.expect_value(t, widget_expand("{killed}", f), "12")
}

@(test)
absent_values_expand_to_something_harmless :: proc(t: ^testing.T) {
	f: Widget_Facts // nothing loaded

	// Call sites branch on has_character / has_next before using these, so a
	// template is never asked for them in the empty case. If one ever is, it
	// should degrade to a blank rather than to a crash.
	out := widget_expand("{character}|{boss}|{region}|{killed}", f)
	testing.expect_value(t, out, "|||0")
}

@(test)
every_documented_placeholder_resolves :: proc(t: ^testing.T) {
	f := facts()

	// WIDGET_PLACEHOLDERS is what the UI will offer as clickable chips. A
	// name listed there but not handled would be offered to the user and
	// then render as a literal, which is the one way a typo can be ours.
	for name in WIDGET_PLACEHOLDERS {
		_, known := widget_placeholder(name, f)
		testing.expectf(t, known, "placeholder {%s} is offered but does not resolve", name)

		out := widget_expand(strings.concatenate({"{", name, "}"}, context.temp_allocator), f)
		testing.expectf(
			t, !strings.contains(out, "{"),
			"{%s} expanded to %q, which still looks like a placeholder", name, out,
		)
	}
}
