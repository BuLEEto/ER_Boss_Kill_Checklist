package main

import "core:mem"
import "core:testing"

// ============================================================================
// BND4 header validation
//
// The entry count at offset 0x0C is four bytes of someone else's file, and it
// sizes the entry-table allocation. A save truncated mid-write or corrupted by
// the game can put anything there — 0xFFFFFFFF asks for a 103 GB table, and the
// loop that fills it then indexes a slice the allocator refused to hand over.
//
// These build the smallest header that gets as far as the check, so a
// regression fails here rather than on a player's machine with a bad save.
// Without the guard this test traps with Illegal_Instruction, which is what
// the app did too.
// ============================================================================

@(private = "file")
header :: proc(count: u32, trailing_entries: int, allocator := context.allocator) -> []u8 {
	size := BND4_HEADER_SIZE + trailing_entries * ENTRY_HEADER_SIZE
	raw := make([]u8, size, allocator)
	magic := BND4_MAGIC
	copy(raw[0:4], magic[:])
	for i in 0 ..< 4 {
		raw[0x0C + i] = u8(count >> uint(8 * i))
	}
	return raw
}

@(test)
an_absurd_entry_count_is_refused :: proc(t: ^testing.T) {
	raw := header(0xFFFF_FFFF, 12)
	defer delete(raw)

	// An arena capped well below the ask, so a regression comes back as a
	// refused allocation rather than the test runner trying to commit
	// 103 GB on behalf of a header nobody checked.
	buf := make([]u8, 64 * 1024)
	defer delete(buf)
	arena: mem.Arena
	mem.arena_init(&arena, buf)

	save, ok := parse_save_bytes("bogus.sl2", raw, mem.arena_allocator(&arena))
	testing.expect(t, !ok, "a count of 0xFFFFFFFF should be refused")
	testing.expect_value(t, len(save.entries), 0)
}

@(test)
an_entry_table_past_the_end_is_refused :: proc(t: ^testing.T) {
	// Claims 12 entries in a file with room for two.
	raw := header(12, 2)
	defer delete(raw)

	_, ok := parse_save_bytes("short.sl2", raw)
	testing.expect(t, !ok, "entries running past the end should be refused")
}

@(test)
an_empty_entry_table_is_refused :: proc(t: ^testing.T) {
	raw := header(0, 0)
	defer delete(raw)

	_, ok := parse_save_bytes("empty.sl2", raw)
	testing.expect(t, !ok, "a count of zero should be refused")
}

@(test)
a_plausible_header_is_accepted :: proc(t: ^testing.T) {
	raw := header(12, 12)
	defer delete(raw)

	save, ok := parse_save_bytes("ER0000.sl2", raw)
	defer delete(save.entries)

	testing.expect(t, ok, "twelve entries that fit should parse")
	testing.expect_value(t, len(save.entries), 12)
}

// ----------------------------------------------------------------------------
// Entry ranges
//
// entry_size is a u64 off disk. Casting a huge one to int gives a negative,
// which sails through a `start + size > len(raw)` test and then slices
// [start:end] with end < start — a bounds panic instead of the "unreadable
// save" the caller is equipped to report.
// ----------------------------------------------------------------------------

@(test)
an_entry_size_that_overflows_an_int_reads_as_unreadable :: proc(t: ^testing.T) {
	raw := header(12, 12)
	defer delete(raw)

	save, ok := parse_save_bytes("ER0000.sl2", raw)
	defer delete(save.entries)
	testing.expect(t, ok, "header should parse before the entries are examined")

	save.entries[0] = BND4_Entry{data_offset = 0x40, entry_size = 0xFFFF_FFFF_FFFF_FFFF}

	testing.expect_value(t, get_death_count(&save, 0, 0x100), 0)

	bst: BST_Map
	flags, off := get_slot_event_flags(&save, 0, bst)
	testing.expect(t, flags == nil, "no flags from an entry that isn't in the file")
	testing.expect_value(t, off, -1)
}

@(test)
an_entry_reaching_past_the_file_reads_as_unreadable :: proc(t: ^testing.T) {
	raw := header(12, 12)
	defer delete(raw)

	save, ok := parse_save_bytes("ER0000.sl2", raw)
	defer delete(save.entries)
	testing.expect(t, ok, "header should parse before the entries are examined")

	// Starts inside the file, ends well past it.
	save.entries[1] = BND4_Entry{data_offset = 0x40, entry_size = u64(len(raw) * 4)}

	testing.expect_value(t, get_death_count(&save, 1, 0x100), 0)
}
