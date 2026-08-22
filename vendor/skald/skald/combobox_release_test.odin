package skald

import "core:testing"

// A click is press-then-release. The press opens the popover; the release
// that completes the same click must not close it again — otherwise the
// dropdown is only visible while the button is physically held down, and
// the user has to drag to a row rather than click, release, then click a
// row the way every native combobox works.
//
// `select` is the control: it has the same trigger/popover shape and is
// known to behave, so if it passes while combobox fails the difference is
// in the combobox's own handling rather than in this harness.

CBR_Msg :: distinct int

@(private = "file")
CBR_Fixture :: struct {
	ws:     Widget_Store,
	th:     Theme,
	lb:     Labels,
	input:  Input,
	msgs:   [dynamic]CBR_Msg,
}

@(private = "file")
cbr_trigger :: Rect{x = 10, y = 10, w = 220, h = 28}

// A point inside the trigger.
@(private = "file")
cbr_on_trigger :: [2]f32{50, 20}

@(private = "file")
cbr_begin_frame :: proc(f: ^CBR_Fixture) -> Ctx(CBR_Msg) {
	widget_store_begin_frame(&f.ws, f.input)
	return Ctx(CBR_Msg) {
		theme   = &f.th,
		labels  = &f.lb,
		widgets = &f.ws,
		input   = &f.input,
		msgs    = &f.msgs,
	}
}

// Stand in for the layout pass, which is what records a widget's
// on-screen rect in a real frame.
@(private = "file")
cbr_stamp_rect :: proc(f: ^CBR_Fixture, id: Widget_ID, kind: Widget_Kind, in_modal := false) {
	st := f.ws.states[id]
	st.kind       = kind
	st.last_rect  = cbr_trigger
	st.last_frame = f.ws.frame
	// Widgets drawn inside a dialog carry an overlay stamp. Without it
	// Skald's modal trap treats them as main-tree widgets sitting behind
	// the card and refuses every hit, so a modal test that skips this
	// never even registers the press.
	// The stamp is written while the frame *renders*, so during a builder
	// it still carries last frame's number — which is exactly what the
	// modal trap compares against.
	if in_modal { st.last_overlay_frame = f.ws.frame - 1 }
	f.ws.states[id] = st
}

// One frame of the dialog simply being on screen, so the overlay stamp and
// modal rect the next frame reads are already a frame old — the state a
// real click arrives in.
@(private = "file")
cbr_warm_up_modal :: proc(f: ^CBR_Fixture, id: Widget_ID, modal: Rect, options: []string) {
	f.input = Input{mouse_pos = cbr_on_trigger}
	f.ws.modal_rect = modal
	ctx := cbr_begin_frame(f)
	cbr_stamp_rect(f, id, .Combobox, in_modal = true)
	_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
}

@(test)
combobox_stays_open_after_the_click_releases :: proc(t: ^testing.T) {
	f: CBR_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id      := hash_id("cbr-combobox")
	options := []string{"Alpha", "Beta", "Gamma"}

	// Frame 1 — press on the trigger.
	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	// Frame 2 — the button comes back up, still over the trigger.
	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_released[.Left] = true
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open,
		"releasing the button that opened it must leave the popover open")

	// Frame 3 — nothing happening at all; it should still be up.
	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "the popover should stay open on an idle frame")
}

@(test)
select_stays_open_after_the_click_releases :: proc(t: ^testing.T) {
	f: CBR_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id       := hash_id("cbr-select")
	options  := []string{"Alpha", "Beta", "Gamma"}
	opt_msgs := []CBR_Msg{0, 1, 2}

	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Select)
		_ = _select_impl(&ctx, "Alpha", options, opt_msgs, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "press on the trigger should open the popover")

	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_released[.Left] = true
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Select)
		_ = _select_impl(&ctx, "Alpha", options, opt_msgs, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open,
		"releasing the button that opened it must leave the popover open")
}

// The modal gate. A picker inside a dialog is force-closed unless its
// trigger sits *entirely* inside the dialog's rect. The press branch runs
// later in the same proc than the gate, so a trigger the gate rejects
// still opens on the press frame and shuts on the very next frame — which
// looks to the user like "it only stays open while I hold the button",
// because a still mouse produces no frames to redraw in between.
@(test)
combobox_in_a_modal_closes_when_the_trigger_is_not_fully_inside :: proc(t: ^testing.T) {
	f: CBR_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id      := hash_id("cbr-modal")
	options := []string{"Alpha", "Beta", "Gamma"}

	// A dialog card that clips the trigger's right edge by two pixels.
	modal := Rect{x = 0, y = 0, w = cbr_trigger.x + cbr_trigger.w - 2, h = 400}
	cbr_warm_up_modal(&f, id, modal, options)

	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		f.ws.modal_rect = modal
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox, in_modal = true)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "the press still opens it on the press frame")

	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_released[.Left] = true
		f.ws.modal_rect = modal
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox, in_modal = true)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open,
		"a trigger drawn inside the dialog must not be force-closed for overhanging its rect")
}

// The same widget with a dialog big enough to contain it — the control for
// the test above.
@(test)
combobox_in_a_roomy_modal_stays_open :: proc(t: ^testing.T) {
	f: CBR_Fixture
	widget_store_init(&f.ws)
	defer widget_store_destroy(&f.ws)
	f.th = theme_dark()
	f.lb = labels_en()
	defer delete(f.msgs)

	id      := hash_id("cbr-modal-ok")
	options := []string{"Alpha", "Beta", "Gamma"}
	modal   := Rect{x = 0, y = 0, w = 600, h = 400}
	cbr_warm_up_modal(&f, id, modal, options)

	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_pressed[.Left] = true
		f.input.mouse_buttons[.Left] = true
		f.ws.modal_rect = modal
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox, in_modal = true)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	{
		f.input = Input{mouse_pos = cbr_on_trigger}
		f.input.mouse_released[.Left] = true
		f.ws.modal_rect = modal
		ctx := cbr_begin_frame(&f)
		cbr_stamp_rect(&f, id, .Combobox, in_modal = true)
		_, _, _ = _combobox_impl(&ctx, "Alpha", options, id = id, width = 220)
	}
	testing.expect(t, f.ws.states[id].open, "a contained trigger keeps its popover")
}
