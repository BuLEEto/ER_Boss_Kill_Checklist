package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// Boss Data Types
// ============================================================================

Boss_Entry :: struct {
	boss:       string,
	place:      string,
	flag_id:    u32,
	difficulty: int,    // parsed from [N] prefix in hardlock.json
	killed:     bool,   // runtime state, not from JSON
}

Region :: struct {
	region_name: string,
	regions:     []u32,
	bosses:      []Boss_Entry,
}

// JSON-compatible structs for unmarshalling
Json_Boss :: struct {
	boss:          string,
	place:         string,
	flag_id:       u32,
	rememberance:  int,    // >0 if this is a remembrance boss
	great_rune:    int,    // >0 if this boss drops a great rune
	main_story:    int,    // >0 if required to complete the game
}

Json_Region :: struct {
	region_name: string,
	regions:     []u32,
	bosses:      []Json_Boss,
	dlc:         int,    // 1 if DLC region
}

Boss_List_Type :: enum {
	Standard,
	Hardlock,
	Remembrance,
	Remembrance_DLC,
	Great_Runes,
	Main_Story,
	DLC_Only,
}

// ============================================================================
// Loading
// ============================================================================

boss_matches_filter :: proc(jb: ^Json_Boss, list_type: Boss_List_Type) -> bool {
	switch list_type {
	case .Remembrance, .Remembrance_DLC: return jb.rememberance > 0
	case .Great_Runes:                   return jb.great_rune > 0
	case .Main_Story:                    return jb.main_story > 0
	case .DLC_Only:                      return true // region-level filter handles DLC
	case .Standard, .Hardlock:           return true
	}
	return true
}

load_boss_data :: proc(list_type: Boss_List_Type, allocator := context.allocator) -> ([]Region, bool) {
	path := list_type == .Hardlock ? "hardlock.json" : "bosses.json"

	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read", path)
		return nil, false
	}

	json_regions: []Json_Region
	err := json.unmarshal(raw, &json_regions, allocator = context.temp_allocator)
	if err != nil {
		fmt.eprintln("Failed to parse", path, ":", err)
		return nil, false
	}

	is_filtered := list_type != .Standard && list_type != .Hardlock
	// DLC_Only: only DLC regions. Remembrance/Great_Runes/Main_Story: base game only
	dlc_only := list_type == .DLC_Only
	exclude_dlc := list_type == .Remembrance || list_type == .Great_Runes || list_type == .Main_Story

	region_buf := make([dynamic]Region, 0, len(json_regions), allocator)

	for &jr in json_regions {
		if dlc_only && jr.dlc != 1 do continue
		if exclude_dlc && jr.dlc == 1 do continue

		// Count bosses for this region
		boss_count := 0
		if is_filtered {
			for &jb in jr.bosses {
				if boss_matches_filter(&jb, list_type) do boss_count += 1
			}
			if boss_count == 0 do continue
		} else {
			boss_count = len(jr.bosses)
		}

		region: Region
		region.region_name = strings.clone(jr.region_name, allocator)
		region.regions = make([]u32, len(jr.regions), allocator)
		copy(region.regions, jr.regions)
		region.bosses = make([]Boss_Entry, boss_count, allocator)

		boss_idx := 0
		for &jb in jr.bosses {
			if is_filtered && !boss_matches_filter(&jb, list_type) do continue

			be := &region.bosses[boss_idx]
			boss_idx += 1
			be.flag_id = jb.flag_id
			be.place = strings.clone(jb.place, allocator)
			be.killed = false
			be.difficulty = 0

			// Parse [N] prefix from hardlock boss names
			name := jb.boss
			if list_type == .Hardlock && len(name) >= 3 && name[0] == '[' {
				end := strings.index_byte(name, ']')
				if end > 0 && end < len(name) - 1 {
					diff_str := name[1:end]
					diff_val := 0
					for c in diff_str {
						if c >= '0' && c <= '9' {
							diff_val = diff_val * 10 + int(c - '0')
						}
					}
					be.difficulty = diff_val
					rest := name[end + 1:]
					if len(rest) > 0 && rest[0] == ' ' {
						rest = rest[1:]
					}
					be.boss = strings.clone(rest, allocator)
				} else {
					be.boss = strings.clone(name, allocator)
				}
			} else {
				be.boss = strings.clone(name, allocator)
			}
		}

		append(&region_buf, region)
	}

	return region_buf[:], true
}

count_bosses :: proc(regions: []Region) -> (total: int, killed: int) {
	for &r in regions {
		for &b in r.bosses {
			total += 1
			if b.killed do killed += 1
		}
	}
	return
}

count_region_bosses :: proc(region: ^Region) -> (total: int, killed: int) {
	for &b in region.bosses {
		total += 1
		if b.killed do killed += 1
	}
	return
}
