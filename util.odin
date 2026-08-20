package main

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
