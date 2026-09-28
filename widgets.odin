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

// ============================================================================
// Facts
//
// Every value the OBS surfaces can show, gathered once.
//
// The three of them — the served /widget pages, the text files, and the
// obs-websocket text sources — each used to build these independently. Three
// copies of "%d / %d bosses" kept in step by hand, and they had already
// drifted: the websocket sources label themselves ("Deaths: 57") because an
// OBS text source has no caption of its own to sit under.
//
// Facts here; presentation stays at the call site, because that difference is
// real and deliberate rather than an accident to be normalised away.
//
// `region` and `next_count` are parameters rather than reads of app.settings,
// because each surface genuinely has its own: ws_region, text_region and
// obsws_region are three separate controls, and a change to one is not meant
// to move the others.
//
// Read-only over app state, so callers hold whatever lock they already held.
// ============================================================================

Widget_Facts :: struct {
	killed, total, remaining, percent: int,

	deaths: u32,

	// Absent until the first kill of the session gives it a bookmark.
	attempts:       int,
	attempts_known: bool,

	character_name:  string,
	character_level: u32,
	has_character:   bool,

	session: string,

	// The next boss still standing, then the next few.
	next_boss:  string,
	next_place: string,
	has_next:   bool,
	next_list:  []string, // "Boss — Place", up to next_count of them

	// The focused region for this surface, and what is left in it.
	region_name:   string,
	region_killed: int,
	region_total:  int,
	has_region:    bool,
	region_bosses: []string, // boss names, not yet killed

	// Every region in list order, as "Name k/t".
	all_regions: []string,
}

widget_facts :: proc(
	region: Region_Choice,
	next_count: int,
	allocator := context.temp_allocator,
) -> (f: Widget_Facts) {
	f.total, f.killed = count_bosses(app.regions)
	f.remaining = f.total - f.killed
	f.percent = f.total > 0 ? f.killed * 100 / f.total : 0

	f.deaths = app.death_count
	f.attempts, f.attempts_known = app_attempts()
	f.session = session_summary()

	name, level := app_active_character()
	f.character_name = name
	f.character_level = level
	f.has_character = len(name) > 0

	next := app_next_bosses(next_count, allocator)
	if len(next) > 0 {
		f.next_boss = next[0].boss
		f.next_place = next[0].place
		f.has_next = true
	}
	list := make([dynamic]string, allocator)
	for b in next do append(&list, fmt.tprintf("%s — %s", b.boss, b.place))
	f.next_list = list[:]

	if idx := app_focus_region(region); idx >= 0 {
		r := &app.regions[idx]
		f.region_name = r.region_name
		f.region_total, f.region_killed = count_region_bosses(r)
		f.has_region = true

		left := make([dynamic]string, allocator)
		for &b in r.bosses {
			if !b.killed do append(&left, b.boss)
		}
		f.region_bosses = left[:]
	}

	regions := make([dynamic]string, allocator)
	for &r in app.regions {
		r_total, r_killed := count_region_bosses(&r)
		append(&regions, fmt.tprintf("%s %d/%d", r.region_name, r_killed, r_total))
	}
	f.all_regions = regions[:]

	return f
}
