package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"


// Escape a string for embedding in JSON. Handles raw bytes safely: valid
// UTF-8 passes through, anything else becomes \uXXXX rather than
// producing a document no parser will accept. Character names come
// straight out of a save file, so "probably valid UTF-8" isn't good
// enough.
json_escape_string :: proc(builder: ^strings.Builder, s: string) {
	for i := 0; i < len(s); {
		b := s[i]
		switch b {
		case '"':  strings.write_string(builder, `\"`); i += 1
		case '\\': strings.write_string(builder, `\\`); i += 1
		case '\n': strings.write_string(builder, `\n`); i += 1
		case '\r': strings.write_string(builder, `\r`); i += 1
		case '\t': strings.write_string(builder, `\t`); i += 1
		case 0x00 ..= 0x1F:
			fmt.sbprintf(builder, "\\u%04x", int(b))
			i += 1
		case 0x20 ..= 0x7E:
			strings.write_byte(builder, b)
			i += 1
		case:
			width := 1
			if b & 0xE0 == 0xC0 && i + 1 < len(s) && s[i + 1] & 0xC0 == 0x80 {
				width = 2
			} else if b & 0xF0 == 0xE0 && i + 2 < len(s) &&
			          s[i + 1] & 0xC0 == 0x80 && s[i + 2] & 0xC0 == 0x80 {
				width = 3
			} else if b & 0xF8 == 0xF0 && i + 3 < len(s) &&
			          s[i + 1] & 0xC0 == 0x80 && s[i + 2] & 0xC0 == 0x80 &&
			          s[i + 3] & 0xC0 == 0x80 {
				width = 4
			}

			if width > 1 {
				for j in 0 ..< width {
					strings.write_byte(builder, s[i + j])
				}
			} else {
				fmt.sbprintf(builder, "\\u%04x", int(b))
			}
			i += width
		}
	}
}

// Join lines for an OBS text source.
//
// OBS's text sources — GDI+ and FreeType alike — have no line-height or
// leading control, so a multi-line value renders with whatever the font
// metrics give you, which is tight. The only lever we have is what we
// send, so "roomy" puts a blank line between entries.
obs_join_lines :: proc(
	lines: []string,
	roomy: bool,
	allocator := context.temp_allocator,
) -> string {
	return strings.join(lines, roomy ? "\n\n" : "\n", allocator)
}


// ----------------------------------------------------------------------------
// Tiny JSON readers
//
// Just enough to pick values out of a parsed document without unmarshalling
// into a struct. Settings migration needs this: a migration reads keys that
// are no longer fields, so there is nothing to unmarshal into.
// ----------------------------------------------------------------------------

json_object :: proc(v: json.Value, key: string) -> json.Value {
	obj, ok := v.(json.Object)
	if !ok do return nil
	child, has := obj[key]
	if !has do return nil
	return child
}

json_object_opt :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	obj, ok := v.(json.Object)
	if !ok do return nil, false
	child, has := obj[key]
	if !has do return nil, false
	// An explicit null means "not present" as far as callers care.
	if _, is_null := child.(json.Null); is_null do return nil, false
	return child, true
}

json_string :: proc(v: json.Value, key: string) -> string {
	child := json_object(v, key)
	s, ok := child.(json.String)
	if !ok do return ""
	return string(s)
}

json_int :: proc(v: json.Value, key: string) -> i64 {
	child := json_object(v, key)
	#partial switch n in child {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

json_bool :: proc(v: json.Value, key: string, fallback: bool) -> bool {
	child := json_object(v, key)
	b, ok := child.(json.Boolean)
	if !ok do return fallback
	return bool(b)
}
