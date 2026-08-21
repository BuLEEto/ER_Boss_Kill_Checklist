package main

import "core:slice"
import "core:thread"
import "core:strings"
import "core:sync"

// ============================================================================
// System font families
//
// The font name typed here ends up in a CSS `font-family` on a page OBS
// renders, so what matters is what the *browser* can resolve — which is
// the font list of whatever machine OBS is running on. That's normally
// this machine, so listing what's installed here is the right answer, and
// a far better one than asking someone to remember how their font is
// spelled.
//
// Not the whole answer, though: OBS may be on another PC, and the font
// might only exist there. So the picker is a combobox rather than a
// dropdown — the list is a convenience, and anything can still be typed.
//
// Enumeration is done once, lazily, on a worker thread (it shells out on
// Linux and walks the GDI font table on Windows, neither of which belongs
// on the frame path). Until it lands, the picker shows the fallback list
// below, which is the set that browsers resolve almost everywhere.
// ============================================================================

// Families a browser will find on essentially any Windows or Linux box —
// either installed outright or aliased by fontconfig. Shown before
// enumeration finishes, and used as-is if enumeration comes back empty.
// The picker's first row. Selecting it clears the setting, which leaves
// the page on its own font stack.
FONT_DEFAULT_LABEL :: "Default (page's own font)"

FALLBACK_FONT_FAMILIES :: [?]string {
	"Arial",
	"Cantarell",
	"Consolas",
	"Courier New",
	"DejaVu Sans",
	"DejaVu Serif",
	"Georgia",
	"Impact",
	"Liberation Sans",
	"Liberation Serif",
	"Noto Sans",
	"Noto Serif",
	"Segoe UI",
	"Tahoma",
	"Times New Roman",
	"Trebuchet MS",
	"Ubuntu",
	"Verdana",
}

@(private = "file")
Font_Cache :: struct {
	mu:      sync.Mutex,
	names:   []string, // owned
	loaded:  bool,
	started: bool,
}

@(private = "file")
g_fonts: Font_Cache

// Kick enumeration off if it hasn't run. Safe to call every frame — it
// starts at most one worker per process.
//
// Deliberately not a Skald command: nothing here touches app or Gui
// state, the result lands in this file's own cache behind its own mutex,
// and the picker simply shows more names on a later frame.
font_families_begin_load :: proc() {
	sync.mutex_lock(&g_fonts.mu)
	already := g_fonts.started
	g_fonts.started = true
	sync.mutex_unlock(&g_fonts.mu)
	if already do return

	// One-shot worker that cleans itself up: it writes the cache once and
	// exits, so there's nothing to join and nothing to free at shutdown.
	thread.create_and_start(font_enumerate_worker, self_cleanup = true)
}

@(private = "file")
font_enumerate_worker :: proc() {
	// This thread's temp arena is its own and nothing else will reclaim
	// it, so release it before the thread goes away.
	defer free_all(context.temp_allocator)

	names := platform_font_families()

	sync.mutex_lock(&g_fonts.mu)
	g_fonts.names = names
	g_fonts.loaded = true
	sync.mutex_unlock(&g_fonts.mu)
}

// The families to offer, cloned for the caller. Returns the fallback list
// until enumeration finishes, and if enumeration found nothing.
//
// Clones because the picker is rebuilt every frame and the cache is
// written by a worker — handing out the backing slice would be handing
// out memory another thread owns.
font_families :: proc(allocator := context.temp_allocator) -> []string {
	sync.mutex_lock(&g_fonts.mu)
	defer sync.mutex_unlock(&g_fonts.mu)

	if !g_fonts.loaded || len(g_fonts.names) == 0 {
		fallback := FALLBACK_FONT_FAMILIES
		out := make([]string, len(fallback), allocator)
		for f, i in fallback do out[i] = strings.clone(f, allocator)
		return out
	}

	out := make([]string, len(g_fonts.names), allocator)
	for n, i in g_fonts.names do out[i] = strings.clone(n, allocator)
	return out
}

// Tidy a raw list from the platform: drop blanks and duplicates, sort
// case-insensitively so the dropdown reads like a font menu rather than
// like a directory listing.
//
// Takes ownership of `raw` and frees it.
@(private)
font_names_finalize :: proc(raw: [dynamic]string) -> []string {
	seen := make(map[string]bool, len(raw), context.temp_allocator)
	out := make([dynamic]string, 0, len(raw))

	for name in raw {
		trimmed := strings.trim_space(name)
		// '@' prefixes GDI's vertical-writing variants, which are the same
		// family rotated and only meaningful for CJK vertical text.
		if len(trimmed) == 0 || trimmed[0] == '@' {
			delete(name)
			continue
		}
		key := strings.to_lower(trimmed, context.temp_allocator)
		if key in seen {
			delete(name)
			continue
		}
		seen[key] = true
		append(&out, strings.clone(trimmed))
		delete(name)
	}
	delete(raw)

	slice.sort_by(out[:], proc(a, b: string) -> bool {
		la := strings.to_lower(a, context.temp_allocator)
		lb := strings.to_lower(b, context.temp_allocator)
		return la < lb
	})
	return out[:]
}
