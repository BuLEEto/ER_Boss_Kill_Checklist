package main

import "core:fmt"
import "gui:skald"

// ============================================================================
// Help sheets
//
// The OBS tab assumes you know OBS, and some of it is only obvious if you
// already do — nobody looks at "write text files" and knows that means
// adding a Text (GDI+) source with "Read from file" ticked.
//
// Each sheet is a modal: numbered steps, the exact source type to add, and
// the exact path or setting to paste. Kept in the app rather than linked
// out so it works with no connection and without leaving the window.
// ============================================================================

Help_Topic :: enum {
	None,
	Browser_Source,
	Text_Files,
	Single_Values,
	Obs_Sources,
}

Help_Step :: struct {
	title: string,
	body:  string,
}

help_title :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Browser_Source: return "Using the browser source"
	case .Text_Files:     return "Using the text files"
	case .Single_Values:  return "Using the single-value pages"
	case .Obs_Sources:    return "Driving OBS text sources"
	case .None:           return ""
	}
	return ""
}

help_intro :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Browser_Source:
		return "The main way to get this on stream, and the one every OBS user already knows: paste a URL into a Browser source. OBS renders the page itself, styled and laid out here, updating live — there's no refresh interval to set.\n\nTwo shapes: the overlay card, which is everything in one box, and a page per value for when you want the numbers in different corners of your layout."
	case .Text_Files:
		return "The most compatible option. The app keeps a folder of small text files up to date, and OBS text sources read straight from them. No browser source, no extra CPU, and it works on every version of OBS."
	case .Obs_Sources:
		return "For the OBS builds that have no Browser source at all — Debian and Ubuntu package OBS without CEF, so the browser-source panels are no use on them. This connects to OBS's own WebSocket server and creates real OBS text sources instead, keeping their text current as you play.\n\nWindow-capturing a browser is the other way round it, but that needs a browser window per value, and eight of them while you're playing isn't a workflow."

	case .Single_Values:
		return "One page per value, each added to OBS as its own Browser source. Use these when you want the numbers spread around your layout rather than gathered in one card — a deaths counter in one corner, the boss list in another.\n\nThey're the same technology as the overlay card, so they get the same things an OBS text source can't do: real alignment, a line height you can set, and colours and fonts chosen here rather than per-source in OBS."
	case .None:
		return ""
	}
	return ""
}

help_steps :: proc(topic: Help_Topic, allocator := context.temp_allocator) -> []Help_Step {
	steps := make([dynamic]Help_Step, allocator)

	switch topic {
	case .Browser_Source:
		append(&steps,
			Help_Step{
				"Copy the overlay URL",
				"Pick the mode and background above, then press Copy next to Overlay URL.",
			},
			Help_Step{
				"Add a Browser source in OBS",
				"Sources → + → Browser. Give it a name and click OK.",
			},
			Help_Step{
				"Paste the URL and size the source",
				"Put it in the URL field, then set Width and Height to the size you want the card to be — the card fills the source exactly, so the box you drag in OBS is the card you see. 500 × 800 suits summary mode, less for next-up.",
			},
			Help_Step{
				"Dark panel, or just the text",
				"Card chooses between the two. Dark panel is the rounded box behind the text — easier to read, but it's a visible box on your scene. No panel drops it and puts a heavy outline on the text instead, so all your viewers see is the words.\n\nBackground is a different setting and usually wants leaving on Transparent: the page has no background of its own and composites straight over gameplay. Green and magenta are only for capturing the page as a *window*, where you need a chroma key.",
			},
			Help_Step{
				"Position it",
				"Drag it where you want. It refreshes itself whenever a boss dies — you don't need to tick \"Refresh browser when scene becomes active\".",
			},
			Help_Step{
				"Recolour it, if you like",
				"Properties → Custom CSS. The page's colours are CSS variables, so one rule repaints the lot:\n\n:root { --gold: #ff4444; --text: #ffffff; }\n\nVariables are --gold, --gold-dim, --text, --text-dim, --red and --green. The app never writes to that box, so whatever you put there survives.",
			},
			Help_Step{
				"Attempt counter",
				"\"Attempt 12\" is the deaths you've taken since the last boss you killed, and it resets itself the moment the next one falls. Elden Ring doesn't record deaths per boss, so that's what it is — deaths since your last kill. Die exploring and it still counts. There's a Reset on the Checklist tab for when it's measuring the wrong thing.",
			},
			Help_Step{
				"Boss defeated banner",
				"When a boss dies the overlay announces it by name for a few seconds, then goes back to the numbers. It sits at the bottom of the browser source, so give the source some height below the card — with the source cropped tight to the card there's nowhere for it to go and it will overlap.\n\nIt uses this panel's accent and text colours. Turn it off with \"Announce kills on the overlay\".",
			},
			Help_Step{
				"How quickly it reacts",
				"Everything here comes from the save file, and Elden Ring only writes that every so often. Expect a kill to show up within about ten seconds of the fight ending, not the instant the boss falls — soon enough for the replay, not for the exact moment.",
			},
			Help_Step{
				"Why this and not a text source",
				"OBS text sources have no alignment and no line height, so a multi-line list is stuck left-aligned with whatever spacing the font gives. This is a web page, so Align actually aligns every line, and the styling is yours to change.",
			},
		)

	case .Text_Files:
		append(&steps,
			Help_Step{
				"Turn on Write text files",
				fmt.tprintf(
					"The files are written to:\n%s\nUse Browse… to put them somewhere else.",
					obs_text_dir(context.temp_allocator),
				),
			},
			Help_Step{
				"Add a Text source in OBS",
				"Sources → + → Text (GDI+) on Windows, or Text (FreeType 2) on Linux. Name it after whichever value you want to show.",
			},
			Help_Step{
				"Tick \"Read from file\"",
				"Then Browse to one of the files listed below. OBS re-reads it whenever it changes, so that's the whole wiring done.",
			},
			Help_Step{
				"Style it in OBS",
				"Font, size, colour and outline are all OBS's settings, not ours — the app only ever changes the text. A bold font with a dark outline reads best over gameplay.",
			},
			Help_Step{
				"Multi-line files look cramped?",
				"OBS text sources have no line-height setting, in either the GDI+ or FreeType flavour. The only way to open a list up is to send a blank line between entries — that's the \"Blank line between entries\" tick box under obs-websocket, and it applies to these files too.",
			},
			Help_Step{
				"Repeat for anything else you want",
				"One source per file. Most people show progress.txt and deaths.txt, and add next_boss.txt if they want a \"coming up\" line.",
			},
		)

	case .Obs_Sources:
		append(&steps,
			Help_Step{
				"Turn on the WebSocket server in OBS",
				"OBS → Tools → WebSocket Server Settings → tick Enable WebSocket server. Note the port, 4455 by default.",
			},
			Help_Step{
				"Get the password",
				"Show Connect Info in that same dialog reveals it. Leave the password disabled in OBS and you can skip this.",
			},
			Help_Step{
				"Fill it in here and press Connect",
				"Host stays 127.0.0.1 if OBS is on this machine. Tick Remember the password to skip re-typing it — it's encrypted before it goes to disk, and tied to this machine, so a copied settings file is inert.",
			},
			Help_Step{
				"Choose the scene — nothing happens until you do",
				"Add to scene decides where the sources are created, and it's deliberately not optional. Until you pick one the app connects and creates nothing: dropping eight sources into whichever scene happened to be live is exactly the sort of thing you'd discover mid-stream.",
			},
			Help_Step{
				"Pick which values you want",
				"Only ticked ones are created. They appear as \"ER Progress\", \"ER Deaths\" and so on, stacked down the left in a bold white font with an outline, so they're legible from the moment they show up.",
			},
			Help_Step{
				"Style them from Appearance",
				"Font, size, colour, bold and outline, set once and pushed to all of them. Doing it in OBS means opening eight property dialogs and setting the same thing eight times, and again every time you change your mind.\n\nOnly sent when you change something here, never during play, and only the part you changed: nudging the size doesn't resend the colour. So if you'd rather set one source's colour by hand in OBS, that survives everything except touching Colour on this panel."
			},
			Help_Step{
				"Position them in OBS",
				"That's never touched. New sources are stacked down the left so they don't land on top of each other; move and scale them however you like and the app won't move them again.\n\nUnticking hides a source rather than deleting it, because OBS has no undo for a deleted source.",
			},
			Help_Step{
				"What isn't here, and why",
				"Alignment. text_ft2_source_v2 — the text plugin on Linux — hasn't got any, so a control for it would work on Windows and silently do nothing for you. That gap is the reason the browser-source pages exist, where alignment is one CSS rule.\n\nLine height is the same story, which is why multi-line lists get the \"Blank line between entries\" option instead.",
			},
			Help_Step{
				"If you also have Browser sources",
				"Then you probably don't want this panel: copying a URL from Overlay card or Single values gives you real alignment, line height and colours. This exists for the builds where that isn't on the menu.",
			},
		)

	case .Single_Values:
		append(&steps,
			Help_Step{
				"Copy the one you want",
				"Each row on the Single values panel has a Copy button next to its URL. Copy the values you'll actually show — every one you add is another browser instance for OBS to run.",
			},
			Help_Step{
				"Add a Browser source per value",
				"Sources → + → Browser, paste the URL, then crop the source down to the text. These pages draw flush to the top-left corner, so a tight box is easy to place — a bare number needs very little, while Character or Next boss need the width for a long name and Region bosses needs the height for a list. Leaving the source far bigger than its text is what makes them awkward to position.",
			},
			Help_Step{
				"Leave the background transparent",
				"The pages have no background of their own, so they composite straight over gameplay.",
			},
			Help_Step{
				"Position each one",
				"They're ordinary browser sources — drag and scale them where you like. They update themselves whenever the numbers change; there's no refresh interval to set.",
			},
			Help_Step{
				"The URLs never change",
				"Nothing about how a page looks is carried in its URL — it's all resolved here. So restyling a page reaches OBS on its own, and you never have to re-paste a URL you've already set up.",
			},
			Help_Step{
				"The caption above each value",
				"\"DEATHS\" above the number, and so on — on by default, because a bare \"57\" on a stream tells a viewer nothing. Turn it off with \"Caption above each value\" if you're drawing your own labels in OBS.",
			},
			Help_Step{
				"Styling them",
				"Appearance at the bottom of the panel styles every page at once. To make one different, press Style… on its row and tick \"Style this page on its own\": it starts as a copy of the shared look and then goes its own way. Untick to put it back — what you set is kept, so you can flip between the two.",
			},
			Help_Step{
				"Which area they follow",
				"Region on this panel drives the Region and Region bosses pages. The overlay card and the text files have their own, so they can follow different areas.",
			},
			Help_Step{
				"OBS's Custom CSS still works",
				"Each browser source has its own Custom CSS box in OBS, injected after everything set here — so it's still there for a one-off tweak on a single source.",
			},
		)

	case .None:
	}

	return steps[:]
}

help_footer :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Text_Files:
		return "Text files and browser sources can run at the same time — they don't conflict, and plenty of people use both."
	case .Obs_Sources:
		return "If Connect fails, check the WebSocket server is enabled in OBS and that the port matches."

	case .Single_Values:
		return "If a page is blank, check the web server is running — the status is on the Overlay card panel."
	case .Browser_Source:
		return "If the overlay is blank, check the web server is running — the status is shown above the overlay settings."
	case .None:
		return ""
	}
	return ""
}

// ----------------------------------------------------------------------------
// View
// ----------------------------------------------------------------------------

HELP_DIALOG_WIDTH :: f32(720)

view_help_dialog :: proc(s: Gui, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	topic := s.help_topic

	// Same arithmetic the framework's own confirm_dialog uses: the card's
	// inner area, less the scroll gutter on both sides and the scrollbar.
	text_w := HELP_DIALOG_WIDTH - 2 * th.spacing.lg - 2 * SCROLL_GUTTER - SCROLL_GUTTER

	rows := make([dynamic]skald.View, context.temp_allocator)

	append(&rows, paragraph(ctx, help_intro(topic), th.color.fg_muted, th.font.size_sm, text_w))
	append(&rows, skald.spacer(th.spacing.md))

	for step, i in help_steps(topic) {
		// primary, not on_primary: on_primary is the colour for text
		// sitting *on* a filled accent, which on this theme is near-black
		// and invisible against the dialog.
		append(&rows, skald.row(
			skald.text(fmt.tprintf("%d.", i + 1), th.color.primary, th.font.size_md),
			skald.text(step.title, th.color.fg, th.font.size_md),
			spacing     = th.spacing.sm,
			cross_align = .Center,
		))
		append(&rows, skald.col(
			paragraph(ctx, step.body, th.color.fg_muted, th.font.size_sm, text_w - th.spacing.lg),
			padding     = th.spacing.xs,
			cross_align = .Stretch,
		))
		append(&rows, skald.spacer(th.spacing.sm))
	}

	if topic == .Text_Files {
		append(&rows, skald.section_header(ctx, "The files"))
		files := OBS_TEXT_FILES
		for f in files {
			// Name and description stacked rather than side by side: the
			// descriptions are long enough that a right-aligned column
			// gets clipped at this card width.
			append(&rows, skald.col(
				skald.text(f.name, th.color.fg, th.font.size_sm),
				paragraph(ctx, f.description, th.color.fg_muted, th.font.size_xs, text_w),
				spacing     = 0,
				padding     = 2,
				cross_align = .Stretch,
			))
		}
		append(&rows, skald.spacer(th.spacing.sm))
	}

	if footer := help_footer(topic); len(footer) > 0 {
		append(&rows, paragraph(ctx, footer, th.color.fg_muted, th.font.size_xs, text_w))
	}

	return skald.dialog(
		ctx,
		open = topic != .None,
		on_dismiss = on_help_closed,
		width = HELP_DIALOG_WIDTH,
		max_width = 760,
		content = skald.col(
			skald.text(help_title(topic), th.color.fg, th.font.size_lg),
			skald.spacer(th.spacing.sm),
			skald.scroll(ctx, {0, 420}, skald.col(
				..rows[:],
				spacing     = 0,
				padding     = SCROLL_GUTTER,
				cross_align = .Stretch,
			)),
			skald.spacer(th.spacing.md),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Close", Msg(Help_Closed{}),
					bg = th.color.primary, fg = th.color.on_primary),
				cross_align = .Center,
			),
			spacing     = 0,
			cross_align = .Stretch,
		),
	)
}

HELP_BUTTON_LABEL :: "How do I use this?"

// A section's blurb with its help button on the same line.
//
// The button used to be its own row. Inside the tab body's column — which
// stretches its children so form rows and text inputs fill the width —
// that made a button as wide as the window for a two-word action. Pairing
// it with the text keeps it at its natural size and puts it where the
// question actually occurs to you.
help_row :: proc(ctx: ^skald.Ctx(Msg), blurb: string, topic: Help_Topic) -> skald.View {
	th := ctx.theme

	// Reserve the button's share before wrapping the blurb, otherwise the
	// text claims the full width and shoulders the button off the edge.
	// Estimated from the label rather than hardcoded so it still holds at
	// every Text size setting.
	button_w := f32(len(HELP_BUTTON_LABEL)) * th.font.size_md * 0.55 + th.spacing.lg * 2
	text_w := content_width(ctx) - button_w - th.spacing.md
	if text_w < 160 do text_w = 160

	// A wrapped text view measures to its max_width, not to its longest
	// line, so handing one a width always parks the button at the far
	// right. Ask the renderer whether the blurb fits on one line first:
	// if it does, leave it unwrapped so it measures to its actual width
	// and the button follows the sentence. Only a blurb that genuinely
	// needs to wrap gets a width — and that one fills the row anyway.
	blurb_view: skald.View
	if skald.text_fits(ctx.renderer, blurb, text_w, th.font.size_sm) {
		blurb_view = skald.text(blurb, th.color.fg_muted, th.font.size_sm)
	} else {
		blurb_view = paragraph(ctx, blurb, th.color.fg_muted, th.font.size_sm, text_w)
	}

	return skald.row(
		blurb_view,
		skald.button(ctx, HELP_BUTTON_LABEL, Msg(Help_Opened(topic))),
		spacing     = th.spacing.md,
		cross_align = .End,
	)
}

on_help_closed :: proc() -> Msg { return Help_Closed{} }
