package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf16"

// ============================================================================
// Constants
// ============================================================================

BND4_MAGIC       :: [4]u8{'B', 'N', 'D', '4'}
BND4_HEADER_SIZE :: 0x40
ENTRY_HEADER_SIZE :: 0x20
SLOT_COUNT       :: 10
SLOT_SIZE_PC     :: 0x280000  // 2,621,440 bytes per slot (data only, no checksum)
CHECKSUM_SIZE    :: 0x10
EVENT_FLAGS_SIZE :: 0x1BF99F
FLAG_DIVISOR     :: 1000
BLOCK_SIZE       :: 125

// ProfileSummary location within USER_DATA_10
PROFILE_SUMMARY_OFFSET :: 0x1964
PROFILE_ENTRY_SIZE     :: 0x24C

// Inventory capacities (items per category, 12 bytes per item)
HELD_COMMON_CAP   :: 0xA80   // 2688
HELD_KEY_CAP      :: 0x180   // 384
STORAGE_COMMON_CAP :: 0x780  // 1920
STORAGE_KEY_CAP   :: 0x80    // 128

// GaitemGameData: 8 bytes header + 7000 entries x 16 bytes
GAITEM_GAME_DATA_SIZE :: 8 + 7000 * 16  // 112,008

// ============================================================================
// Types
// ============================================================================

BST_Map :: map[u32]u32

BND4_Entry :: struct {
	entry_size:  u64,
	data_offset: u32,
	name_offset: u32,
}

Save_File :: struct {
	path:       string,
	raw_data:   []u8,
	entries:    []BND4_Entry,
	file_count: u32,
}

Character_Slot :: struct {
	index:  int,
	active: bool,
	name:   string,
	level:  u32,
}

// ============================================================================
// BST Map Loading
// ============================================================================

load_bst_map :: proc(path: string, allocator := context.allocator) -> (BST_Map, bool) {
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read BST file:", path)
		return nil, false
	}

	bst := make(BST_Map, 16384, allocator)
	content := string(raw)

	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 do continue

		comma := strings.index_byte(trimmed, ',')
		if comma < 0 do continue

		block_str := trimmed[:comma]
		offset_str := trimmed[comma + 1:]

		block_num, bok := strconv.parse_uint(block_str, 10)
		block_off, ook := strconv.parse_uint(offset_str, 10)
		if !bok || !ook do continue

		bst[u32(block_num)] = u32(block_off)
	}

	fmt.println("Loaded BST map:", len(bst), "entries")
	return bst, true
}

// ============================================================================
// Save File Parsing
// ============================================================================

open_save_file :: proc(path: string, allocator := context.allocator) -> (Save_File, bool) {
	save: Save_File
	save.path = path

	raw, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read save file:", path)
		return save, false
	}
	save.raw_data = raw

	if len(raw) < BND4_HEADER_SIZE {
		fmt.eprintln("File too small for BND4 header")
		return save, false
	}

	// Verify magic
	magic := (^[4]u8)(&raw[0])^
	if magic != BND4_MAGIC {
		fmt.eprintln("Not a BND4 file (bad magic)")
		return save, false
	}

	// Read file count from header offset 0x0C
	save.file_count = read_u32_le(raw, 0x0C)

	// Parse entry headers (start at 0x40, 32 bytes each)
	save.entries = make([]BND4_Entry, save.file_count, allocator)
	for i in 0 ..< save.file_count {
		off := BND4_HEADER_SIZE + int(i) * ENTRY_HEADER_SIZE
		save.entries[i] = BND4_Entry {
			entry_size  = read_u64_le(raw, off + 0x08),
			data_offset = read_u32_le(raw, off + 0x10),
			name_offset = read_u32_le(raw, off + 0x14),
		}
	}

	return save, true
}

close_save_file :: proc(save: ^Save_File, allocator := context.allocator) {
	if save.raw_data != nil {
		delete(save.raw_data, allocator)
		save.raw_data = nil
	}
	if save.entries != nil {
		delete(save.entries, allocator)
		save.entries = nil
	}
}

// ============================================================================
// Character Slot Reading (from USER_DATA_10 ProfileSummary)
// ============================================================================

get_character_slots :: proc(save: ^Save_File, allocator := context.allocator) -> []Character_Slot {
	if int(save.file_count) < 11 {
		fmt.eprintln("Save file has fewer than 11 entries")
		return nil
	}

	// USER_DATA_10 is entry index 10
	ud10_entry := save.entries[10]
	ud10_start := int(ud10_entry.data_offset)
	ud10_size := int(ud10_entry.entry_size)

	if ud10_start + ud10_size > len(save.raw_data) {
		fmt.eprintln("USER_DATA_10 out of bounds")
		return nil
	}

	ud10 := save.raw_data[ud10_start:]

	// ProfileSummary at offset 0x1964 (after 16-byte checksum)
	ps_off := PROFILE_SUMMARY_OFFSET

	if ps_off + 10 + SLOT_COUNT * PROFILE_ENTRY_SIZE > ud10_size {
		fmt.eprintln("ProfileSummary out of bounds")
		return nil
	}

	slots := make([]Character_Slot, SLOT_COUNT, allocator)

	// First 10 bytes: active_profiles
	for i in 0 ..< SLOT_COUNT {
		slots[i].index = i
		slots[i].active = ud10[ps_off + i] != 0
	}

	// Profile entries follow (10 x 0x24C bytes)
	for i in 0 ..< SLOT_COUNT {
		if !slots[i].active do continue

		entry_off := ps_off + 10 + i * PROFILE_ENTRY_SIZE

		// Name: UTF-16LE at offset 0x00, 16 chars max (32 bytes)
		slots[i].name = read_utf16le_name(ud10[entry_off:entry_off + 32], allocator)

		// Level: u32 at offset 0x22
		slots[i].level = read_u32_le(ud10, entry_off + 0x22)
	}

	return slots
}

// ============================================================================
// Sequential Slot Parser — finds event flags by parsing every section in order
// ============================================================================

// Parse a character slot sequentially to find the exact event flags offset.
// This mirrors the exact read order from er-save-manager/ER-Save-Lib.
// Returns offset within slot_data where event flags begin, or -1 on error.
find_event_flags_offset :: proc(slot_data: []u8, bst: BST_Map) -> int {
	if len(slot_data) < 36 do return -1

	pos := 0

	// === Section 1-4: Header (32 bytes) ===
	// version(4) + map_id(4) + unk0x8(8) + unk0x10(16)
	version := read_u32_le(slot_data, 0)
	if version == 0 do return -1  // Empty slot
	pos = 32

	// === Section 5: Gaitem map (VARIABLE) ===
	gaitem_count: int = 0x1400  // 5120 for version > 81
	if version <= 81 do gaitem_count = 0x13FE

	for _ in 0 ..< gaitem_count {
		if pos + 8 > len(slot_data) do return -1

		gaitem_handle := read_u32_le(slot_data, pos)
		pos += 8  // handle(4) + item_id(4)

		handle_type := gaitem_handle & 0xF0000000
		if gaitem_handle != 0 && handle_type != 0xC0000000 {
			pos += 8  // unk0x10(4) + unk0x14(4)
			if handle_type == 0x80000000 {
				pos += 5  // gem_gaitem_handle(4) + unk0x1c(1)
			}
		}
	}

	// === Section 6: PlayerGameData (0x1B0 = 432 bytes) ===
	pos += 0x1B0

	// === Section 7: SPEffects (13 entries x 16 bytes = 208 bytes) ===
	pos += 13 * 16

	// === Section 8: EquippedItemsEquipIndex (88 bytes) ===
	pos += 88

	// === Section 9: ActiveWeaponSlotsAndArmStyle (28 bytes) ===
	pos += 28

	// === Section 10: EquippedItemsItemIds (88 bytes) ===
	pos += 88

	// === Section 11: EquippedItemsGaitemHandles (88 bytes) ===
	pos += 88

	// === Section 12: Inventory held ===
	// common_count(4) + HELD_COMMON_CAP items(12 each) + key_count(4) + HELD_KEY_CAP items(12 each) + equip_idx(4) + acq_idx(4)
	pos += 4 + HELD_COMMON_CAP * 12 + 4 + HELD_KEY_CAP * 12 + 4 + 4

	// === Section 13: EquippedSpells (116 bytes) ===
	// 14 spells x 8 bytes + active_index(4)
	pos += 14 * 8 + 4

	// === Section 14: EquippedItems (140 bytes) ===
	// 10 quick items x 8 bytes + active_index(4) + 6 pouch items x 8 bytes + 2 unk u32s
	pos += 10 * 8 + 4 + 6 * 8 + 4 + 4

	// === Section 15: EquippedGestures (24 bytes) ===
	pos += 6 * 4

	// === Section 16: AcquiredProjectiles (VARIABLE) ===
	if pos + 4 > len(slot_data) do return -1
	projectile_count := int(read_u32_le(slot_data, pos))
	pos += 4
	// Sanity check
	if projectile_count < 0 || projectile_count > 10000 do return -1
	pos += projectile_count * 8  // 8 bytes per projectile

	// === Section 17: EquippedArmamentsAndItems (156 bytes) ===
	pos += 39 * 4

	// === Section 18: EquippedPhysics (12 bytes) ===
	pos += 3 * 4

	// === Section 19: FaceData (303 bytes, in_profile_summary=false) ===
	pos += 0x12F

	// === Section 20: Inventory storage box ===
	// common_count(4) + STORAGE_COMMON_CAP items(12 each) + key_count(4) + STORAGE_KEY_CAP items(12 each) + equip_idx(4) + acq_idx(4)
	pos += 4 + STORAGE_COMMON_CAP * 12 + 4 + STORAGE_KEY_CAP * 12 + 4 + 4

	// === Section 21: Gestures (256 bytes) ===
	pos += 64 * 4

	// === Section 22: Unlocked Regions (VARIABLE) ===
	if pos + 4 > len(slot_data) do return -1
	region_count := int(read_u32_le(slot_data, pos))
	pos += 4
	if region_count < 0 || region_count > 10000 do return -1
	pos += region_count * 4

	// === Section 23: RideGameData / Horse (40 bytes) ===
	// coords(12) + map_id(4) + angle(16) + hp(4) + state(4)
	pos += 40

	// === Section 24: control_byte_maybe (1 byte) ===
	pos += 1

	// === Section 25: BloodStain (68 bytes = 0x44) ===
	// coords(12) + angle(16) + 6 u32s(24) + runes(4) + map_id(4) + 2 u32s(8)
	pos += 0x44

	// === Section 26: unk_gamedataman fields (8 bytes) ===
	pos += 4 + 4

	// === Section 27: MenuProfileSaveLoad (VARIABLE) ===
	// header: unk0x0(2) + unk0x2(2) + size(4) = 8 bytes, then 'size' bytes of data
	if pos + 8 > len(slot_data) do return -1
	menu_size := int(read_u32_le(slot_data, pos + 4))
	pos += 8
	if menu_size < 0 || menu_size > 0x10000 do menu_size = 0x1000
	pos += menu_size

	// === Section 28: TrophyEquipData (52 bytes = 0x34) ===
	pos += 0x34

	// === Section 29: GaitemGameData (112,008 bytes) ===
	// count(8) + 7000 entries x 16 bytes
	pos += GAITEM_GAME_DATA_SIZE

	// === Section 30: TutorialData (VARIABLE) ===
	// header: unk0x0(2) + unk0x2(2) + size(4) = 8 bytes, then 'size' bytes of data
	if pos + 8 > len(slot_data) do return -1
	tutorial_size := int(read_u32_le(slot_data, pos + 4))
	pos += 8
	if tutorial_size < 0 || tutorial_size > 0x10000 do tutorial_size = 0x400
	pos += tutorial_size

	// === Section 31: gameman bytes (3 bytes) ===
	pos += 3

	// === Section 32: total_deaths_count (4 bytes) — at pos right now ===
	// (We don't read it here, but this is where it is)
	pos += 4

	// === Sections 33-39: character_type(4) + in_online_session_flag(1) +
	//     character_type_online(4) + last_rested_grace(4) + not_alone_flag(1) +
	//     in_game_countdown_timer(4) + unk(4) = 22 bytes ===
	pos += 22

	// === Section 40: EVENT FLAGS START ===
	if pos + EVENT_FLAGS_SIZE > len(slot_data) {
		fmt.eprintfln("Event flags would exceed slot size (pos=%d, need=%d, have=%d)", pos, pos + EVENT_FLAGS_SIZE, len(slot_data))
		return -1
	}

	return pos
}

// ============================================================================
// Event Flag Reading
// ============================================================================

// Check if a specific event flag is set
check_event_flag :: proc(event_flags: []u8, flag_id: u32, bst: BST_Map) -> bool {
	block := flag_id / FLAG_DIVISOR
	index := flag_id % FLAG_DIVISOR

	block_offset, found := bst[block]
	if !found do return false

	byte_offset := int(block_offset) * BLOCK_SIZE + int(index / 8)
	bit_index := 7 - (index % 8)

	if byte_offset >= len(event_flags) do return false

	return ((event_flags[byte_offset] >> bit_index) & 1) == 1
}

// Get the event flags slice for a character slot
get_slot_event_flags :: proc(save: ^Save_File, slot_index: int, bst: BST_Map) -> (event_flags: []u8, ef_offset: int) {
	if slot_index < 0 || slot_index >= SLOT_COUNT do return nil, -1
	if int(save.file_count) <= slot_index do return nil, -1

	entry := save.entries[slot_index]
	start := int(entry.data_offset) + CHECKSUM_SIZE  // skip MD5 checksum
	end := int(entry.data_offset) + int(entry.entry_size)

	if end > len(save.raw_data) do return nil, -1

	slot_data := save.raw_data[start:end]
	ef_off := find_event_flags_offset(slot_data, bst)

	if ef_off < 0 do return nil, -1
	if ef_off + EVENT_FLAGS_SIZE > len(slot_data) do return nil, -1

	return slot_data[ef_off:ef_off + EVENT_FLAGS_SIZE], ef_off
}

// Read death count from slot data (stored 26 bytes before event flags)
// Layout before EF: gameman(3) + deaths(4) + char_type(4) + online_flag(1) +
//                   char_type_online(4) + last_grace(4) + not_alone(1) +
//                   countdown(4) + unk(4) = 29 bytes total
// So deaths starts at ef_offset - 26
get_death_count :: proc(save: ^Save_File, slot_index: int, ef_offset: int) -> u32 {
	if slot_index < 0 || slot_index >= SLOT_COUNT do return 0
	if ef_offset < 30 do return 0

	entry := save.entries[slot_index]
	start := int(entry.data_offset) + CHECKSUM_SIZE
	end := int(entry.data_offset) + int(entry.entry_size)

	if end > len(save.raw_data) do return 0

	slot_data := save.raw_data[start:end]

	// Death count is 26 bytes before event flags
	death_off := ef_offset - 26
	if death_off < 0 || death_off + 4 > len(slot_data) do return 0
	return read_u32_le(slot_data, death_off)
}

// ============================================================================
// Binary Helpers
// ============================================================================

read_u32_le :: proc(data: []u8, offset: int) -> u32 {
	if offset + 4 > len(data) do return 0
	return u32(data[offset]) |
	       (u32(data[offset + 1]) << 8) |
	       (u32(data[offset + 2]) << 16) |
	       (u32(data[offset + 3]) << 24)
}

read_u64_le :: proc(data: []u8, offset: int) -> u64 {
	if offset + 8 > len(data) do return 0
	return u64(data[offset]) |
	       (u64(data[offset + 1]) << 8) |
	       (u64(data[offset + 2]) << 16) |
	       (u64(data[offset + 3]) << 24) |
	       (u64(data[offset + 4]) << 32) |
	       (u64(data[offset + 5]) << 40) |
	       (u64(data[offset + 6]) << 48) |
	       (u64(data[offset + 7]) << 56)
}

read_utf16le_name :: proc(data: []u8, allocator := context.allocator) -> string {
	if len(data) < 2 do return ""

	// Convert bytes to u16 array
	char_count := len(data) / 2
	chars := make([]u16, char_count, context.temp_allocator)
	for i in 0 ..< char_count {
		chars[i] = u16(data[i * 2]) | (u16(data[i * 2 + 1]) << 8)
		if chars[i] == 0 {
			chars = chars[:i]
			break
		}
	}

	if len(chars) == 0 do return ""

	// Decode UTF-16 to UTF-8 via runes
	runes := make([]rune, len(chars), context.temp_allocator)
	n := utf16.decode(runes, chars)
	if n <= 0 do return ""

	// Convert runes to UTF-8 string
	buf := make([dynamic]u8, 0, n * 4, allocator)
	for r in runes[:n] {
		if r < 0x80 {
			append(&buf, u8(r))
		} else if r < 0x800 {
			append(&buf, u8(0xC0 | (r >> 6)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		} else if r < 0x10000 {
			append(&buf, u8(0xE0 | (r >> 12)))
			append(&buf, u8(0x80 | ((r >> 6) & 0x3F)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		} else {
			append(&buf, u8(0xF0 | (r >> 18)))
			append(&buf, u8(0x80 | ((r >> 12) & 0x3F)))
			append(&buf, u8(0x80 | ((r >> 6) & 0x3F)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		}
	}
	return string(buf[:])
}
