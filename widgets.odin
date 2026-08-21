package main

import "core:fmt"

// ============================================================================
// Single-value pages
//
// Each of these is one number or line, served at /widget?type=<slug> as its
// own tiny page. The point of them is placement: OBS positions a browser
// source, so one value per source is how you get the deaths counter in one
// corner and the boss list in another, instead of everything in one card.
//
// They are pages rather than OBS text sources for the reason that runs
// through this whole app: an OBS text source has no alignment and no line
// height, so a multi-line list is stuck ragged-left with whatever spacing
// the font happens to give. These are HTML, so both are one CSS rule.
//
// Order here is the order they're listed in the app, which is roughly
// most-wanted first rather than alphabetical.
// ============================================================================

Widget_Kind :: enum {
	Progress,
	Next_Boss,
	Deaths,
	Attempts,
	Session,
	Character,
	Region,
	Region_Bosses,
}

// The ?type= value. Also the key a per-page appearance override is stored
// under, so it has to stay stable — renaming one silently drops whatever
// styling someone had set for it.
widget_slug :: proc(k: Widget_Kind) -> string {
	switch k {
	case .Progress:      return "progress"
	case .Next_Boss:     return "next"
	case .Deaths:        return "deaths"
	case .Attempts:      return "attempts"
	case .Session:       return "session"
	case .Character:     return "character"
	case .Region:        return "region"
	case .Region_Bosses: return "region_bosses"
	}
	return "progress"
}

widget_label :: proc(k: Widget_Kind) -> string {
	switch k {
	case .Progress:      return "Progress"
	case .Next_Boss:     return "Next boss"
	case .Deaths:        return "Deaths"
	case .Attempts:      return "Attempts"
	case .Session:       return "Session"
	case .Character:     return "Character"
	case .Region:        return "Region"
	case .Region_Bosses: return "Region bosses"
	}
	return ""
}

// What the page is, in words. Deliberately never a sample value: the list
// shows the live one right next to this, and two things that look like
// values but disagree reads as a bug rather than as an example.
widget_example :: proc(k: Widget_Kind) -> string {
	switch k {
	case .Progress:      return "bosses defeated out of the list total"
	case .Next_Boss:     return "the next boss standing, with its location"
	case .Deaths:        return "the character's total deaths"
	case .Attempts:      return "deaths since your last boss kill"
	case .Session:       return "bosses and deaths this sitting"
	case .Character:     return "character name and rune level"
	case .Region:        return "the focused area and its count"
	case .Region_Bosses: return "what's left in that area, one per line"
	}
	return ""
}

// What this page is showing right now, for the list in the app.
//
// The real value rather than a canned example. An example that doesn't
// match what's on screen isn't a hint, it's a contradiction — "Caelid
// (12/15)" sat next to a Region setting following Siofra River and read as
// a stale value rather than as illustration. Showing the live value makes
// the list a preview of all eight pages and can't disagree with itself.
//
// Runs on the GUI thread during view building, like every other read of
// app state in the view.
widget_preview :: proc(k: Widget_Kind) -> string {
	label, value, lines := widget_content(widget_slug(k))
	_ = label

	if len(lines) > 0 {
		if len(lines) == 1 do return lines[0]
		return fmt.tprintf("%s  (+%d more)", lines[0], len(lines) - 1)
	}
	if len(value) == 0 do return "—"
	return value
}

// ----------------------------------------------------------------------------
// As OBS text sources
//
// The same eight values, pushed into OBS text sources over obs-websocket
// instead of being served as pages. That exists because a good many Linux
// OBS builds — Debian's and Ubuntu's among them — are packaged without
// CEF and so have no Browser source at all. On those, a page is not an
// option: window-capturing one browser is awkward and eight is absurd, so
// text sources driven directly are the only workable route.
// ----------------------------------------------------------------------------

// The name the source gets in OBS. The "ER " prefix keeps them together in
// the source list and out of the way of the user's own names.
obs_source_name :: proc(k: Widget_Kind) -> string {
	switch k {
	case .Progress:      return "ER Progress"
	case .Next_Boss:     return "ER Next Boss"
	case .Deaths:        return "ER Deaths"
	case .Attempts:      return "ER Attempts"
	case .Session:       return "ER Session"
	case .Character:     return "ER Character"
	case .Region:        return "ER Region"
	case .Region_Bosses: return "ER Region Bosses"
	}
	return ""
}

// Whether this value is one of the sources to create and keep updated.
obsws_sends :: proc(k: Widget_Kind) -> bool {
	return app.settings.obsws_send[int(k)]
}

widget_kind_from_slug :: proc(slug: string) -> (Widget_Kind, bool) {
	for k in Widget_Kind {
		if widget_slug(k) == slug do return k, true
	}
	return .Progress, false
}
