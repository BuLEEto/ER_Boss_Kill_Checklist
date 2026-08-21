#+build windows
package main

import "base:runtime"
import win "core:sys/windows"

// Enumerate through GDI rather than reading the Fonts registry key.
//
// The registry lists *files* under display names like "Arial Bold
// (TrueType)", so a straight read gives a list full of styles pretending
// to be families, and misses fonts installed for the current user only.
// EnumFontFamiliesExW answers with family names as the system resolves
// them, which is what a CSS font-family has to match.
//
// DEFAULT_CHARSET makes it enumerate once per family per charset, so the
// same name comes back several times — font_names_finalize dedupes, and
// drops the '@' vertical-writing variants GDI also reports.
platform_font_families :: proc() -> []string {
	hdc := win.GetDC(nil)
	if hdc == nil do return nil
	defer win.ReleaseDC(nil, hdc)

	out := make([dynamic]string, 0, 256)

	lf := win.LOGFONTW {
		lfCharSet = win.DEFAULT_CHARSET,
	}

	win.EnumFontFamiliesExW(hdc, &lf, font_enum_proc, win.LPARAM(uintptr(&out)), 0)

	return font_names_finalize(out)
}

// Called by GDI once per family/charset. lParam carries the [dynamic]string
// being filled; returning non-zero asks for the next font.
@(private = "file")
font_enum_proc :: proc "system" (
	lpelf:    ^win.ENUMLOGFONTW,
	lpntm:    ^win.NEWTEXTMETRICW,
	fontType: win.DWORD,
	lParam:   win.LPARAM,
) -> win.INT {
	// GDI gives us no context of our own, and the default one isn't set up
	// on a callback thread — so establish it before allocating.
	context = runtime.default_context()

	if lpelf == nil || lParam == 0 do return 1

	out := (^[dynamic]string)(uintptr(lParam))

	// lfFaceName is a fixed 32-unit buffer, NUL-terminated when shorter.
	face := lpelf.elfLogFont.lfFaceName
	n := 0
	for n < len(face) && face[n] != 0 do n += 1
	if n == 0 do return 1

	name, err := win.wstring_to_utf8(win.wstring(&face[0]), n, context.allocator)
	if err != nil do return 1
	append(out, name)

	return 1
}
