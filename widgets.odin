package main

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

// Shown under the name in the list, so someone can tell Region from
// Region bosses without adding both to OBS to find out.
widget_example :: proc(k: Widget_Kind) -> string {
	switch k {
	case .Progress:      return "113 / 207 bosses"
	case .Next_Boss:     return "the next boss standing, with its location"
	case .Deaths:        return "the character's total deaths"
	case .Attempts:      return "deaths since your last boss kill"
	case .Session:       return "2 bosses · 31 deaths, this sitting"
	case .Character:     return "Tarnished — RL 150"
	case .Region:        return "Caelid (12/15)"
	case .Region_Bosses: return "what's left in that area, one per line"
	}
	return ""
}

widget_kind_from_slug :: proc(slug: string) -> (Widget_Kind, bool) {
	for k in Widget_Kind {
		if widget_slug(k) == slug do return k, true
	}
	return .Progress, false
}
