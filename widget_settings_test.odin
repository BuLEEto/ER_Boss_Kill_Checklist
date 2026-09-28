package main

import "core:testing"

// ============================================================================
// Stored templates
//
// settings_normalise_widget_templates puts each stored entry in the slot its
// value owns, matching on slug so that reordering Widget_Value later can't
// move someone's wording onto a different value.
// ============================================================================

@(private = "file")
stored :: proc(s: ^Settings, slug, text: string, slot: int) {
	s.widget_templates[slot] = Widget_Template{slug = slug, text = text}
}

@(test)
templates_land_in_the_slot_their_slug_names :: proc(t: ^testing.T) {
	s: Settings
	// Deliberately out of enum order: the file's order is whatever it was
	// written in, and must not be what decides placement.
	stored(&s, "region", "R {region}", 0)
	stored(&s, "progress", "P {killed}", 1)

	settings_normalise_widget_templates(&s)

	testing.expect_value(t, s.widget_templates[int(Widget_Value.Progress)].text, "P {killed}")
	testing.expect_value(t, s.widget_templates[int(Widget_Value.Region)].text, "R {region}")
	testing.expect_value(t, s.widget_templates[int(Widget_Value.Deaths)].text, "")
}

@(test)
normalising_twice_keeps_the_templates :: proc(t: ^testing.T) {
	// The proc runs more than once per launch: at load, and again through
	// settings_apply_bounds by way of app_apply_settings. An earlier version
	// cleared the slug after matching, so the second pass had nothing to
	// match on and silently dropped every custom template — the app read a
	// settings file with custom text and wrote it back empty.
	s: Settings
	stored(&s, "progress", "P {killed}", 0)

	settings_normalise_widget_templates(&s)
	settings_normalise_widget_templates(&s)
	settings_normalise_widget_templates(&s)

	testing.expect_value(t, s.widget_templates[int(Widget_Value.Progress)].text, "P {killed}")
}

@(test)
an_unknown_slug_is_dropped_not_misplaced :: proc(t: ^testing.T) {
	// A value that existed in an older build. Better to lose its wording than
	// to land it on whichever value happens to sit at that index now.
	s: Settings
	stored(&s, "no_such_value", "orphaned", 0)
	stored(&s, "deaths", "D {deaths}", 1)

	settings_normalise_widget_templates(&s)

	testing.expect_value(t, s.widget_templates[int(Widget_Value.Deaths)].text, "D {deaths}")
	for w in s.widget_templates {
		testing.expectf(t, w.text != "orphaned", "an unknown slug's text was kept")
	}
}

@(test)
every_value_has_a_unique_slug_and_a_label :: proc(t: ^testing.T) {
	// Slugs are the storage key, so a duplicate would make two values share
	// one template and a blank would make one unstorable.
	seen: map[string]bool
	defer delete(seen)

	for v in Widget_Value {
		slug := widget_value_slug(v)
		testing.expectf(t, len(slug) > 0, "%v has no slug", v)
		testing.expectf(t, !seen[slug], "slug %q is used by more than one value", slug)
		seen[slug] = true

		testing.expectf(t, len(widget_value_label(v)) > 0, "%v has no label for the UI", v)
	}
}
