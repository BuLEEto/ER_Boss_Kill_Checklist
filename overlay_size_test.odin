package main

import "core:testing"

// ============================================================================
// Fitting the overlay browser source
//
// The overlay card is width:100% and its height follows its content, so
// nothing about its size is visible from OBS — which is what leaves a source
// box with dead space in it. overlay.js measures the card and posts the
// numbers to /overlay-size; app_overlay_fit_size turns them into the size a
// browser source should be.
//
// The only real arithmetic in that is making room for the boss-defeated
// banner, which is anchored KILL_BANNER_BOTTOM of the way up from the bottom
// of the source and would otherwise land on top of the card.
// ============================================================================

@(private = "file")
CARD_W :: 308
@(private = "file")
CARD_H :: 664
@(private = "file")
BANNER_H :: 75

@(private = "file")
card :: proc(banner: int) -> Overlay_Size {
	return Overlay_Size{width = CARD_W, height = CARD_H, banner = banner, known = true}
}

@(test)
fit_reports_nothing_until_the_page_has_measured :: proc(t: ^testing.T) {
	_, _, ok := overlay_fit_size(Overlay_Size{}, true)
	testing.expect(t, !ok, "an unmeasured card should report no size at all")
}

@(test)
fit_without_the_banner_is_the_card :: proc(t: ^testing.T) {
	w, h, ok := overlay_fit_size(card(BANNER_H), false)
	testing.expect(t, ok)
	testing.expect_value(t, w, CARD_W)
	// Exactly the card: with no banner to place, any extra height is the
	// dead space this whole feature exists to remove.
	testing.expect_value(t, h, CARD_H)
}

@(test)
fit_with_the_banner_leaves_it_room :: proc(t: ^testing.T) {
	w, h, ok := overlay_fit_size(card(BANNER_H), true)
	testing.expect(t, ok)
	testing.expect_value(t, w, CARD_W)
	testing.expectf(t, h > CARD_H, "fitted height %d should exceed the card's %d", h, CARD_H)

	// The invariant the number exists for: the banner's top edge has to
	// clear the bottom of the card, with KILL_BANNER_GAP to spare.
	banner_top := f32(h) - f32(h) * KILL_BANNER_BOTTOM - BANNER_H
	testing.expectf(
		t, banner_top-CARD_H >= f32(KILL_BANNER_GAP),
		"banner clears the card by %.2fpx, want at least %d",
		banner_top - CARD_H, KILL_BANNER_GAP,
	)
}

@(test)
fit_ignores_a_banner_it_has_no_measurement_for :: proc(t: ^testing.T) {
	// An older overlay.js posts width and height but no banner_height. Room
	// for a banner of unknown size can't be reserved, and guessing one would
	// put a gap under every card for a banner that may never play.
	_, h, ok := overlay_fit_size(card(0), true)
	testing.expect(t, ok)
	testing.expect_value(t, h, CARD_H)
}

@(test)
fit_records_only_real_changes :: proc(t: ^testing.T) {
	app.overlay_size = {}

	testing.expect(t, app_set_overlay_size(CARD_W, CARD_H, BANNER_H), "first measurement is a change")
	testing.expect(
		t, !app_set_overlay_size(CARD_W, CARD_H, BANNER_H),
		"re-posting the same size must not be reported as a change — every overlay reload posts, and each one otherwise costs an OBS round trip",
	)
	testing.expect(t, app_set_overlay_size(CARD_W, CARD_H+1, BANNER_H), "a different height is a change")
}
