package main

import "core:fmt"
import "gui:skald"

// ============================================================================
// Help sheets
//
// The OBS tab offers three integrations and assumes you know OBS. Two of
// them are only obvious if you already do — nobody looks at "write text
// files" and knows that means adding a Text (GDI+) source with "Read from
// file" ticked.
//
// Each sheet is a modal: numbered steps, the exact source type to add, and
// the exact path or setting to paste. Kept in the app rather than linked
// out so it works with no connection and without leaving the window.
// ============================================================================

Help_Topic :: enum {
	None,
	Browser_Source,
	Text_Files,
	Obs_Websocket,
}

Help_Step :: struct {
	title: string,
	body:  string,
}

help_title :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Browser_Source: return "Using the browser source"
	case .Text_Files:     return "Using the text files"
	case .Obs_Websocket:  return "Using obs-websocket"
	case .None:           return ""
	}
	return ""
}

help_intro :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Browser_Source:
		return "The best-looking option: OBS renders the overlay page itself, styled and laid out for you. It updates live — there's no refresh interval to set."
	case .Text_Files:
		return "The most compatible option. The app keeps a folder of small text files up to date, and OBS text sources read straight from them. No browser source, no extra CPU, and it works on every version of OBS."
	case .Obs_Websocket:
		return "How most OBS tools integrate. The app connects to OBS's own WebSocket server and updates text sources directly, so there's no file or web page in between."
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
				"Paste the URL",
				"Put it in the URL field. Set Width and Height to roughly the space you want it to occupy — 500 × 800 suits the summary and next-up modes.",
			},
			Help_Step{
				"Leave the background transparent",
				"The page has no background of its own, so it composites straight over your gameplay. The green and magenta options are only for capturing the page as a window, where you need a chroma key.",
			},
			Help_Step{
				"Position it",
				"Drag it where you want. It refreshes itself whenever a boss dies — you don't need to tick \"Refresh browser when scene becomes active\".",
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
				"Repeat for anything else you want",
				"One source per file. Most people show progress.txt and deaths.txt, and add next_boss.txt if they want a \"coming up\" line.",
			},
		)

	case .Obs_Websocket:
		append(&steps,
			Help_Step{
				"Turn on the WebSocket server in OBS",
				"OBS → Tools → WebSocket Server Settings → tick Enable WebSocket server. Note the port (4455 by default).",
			},
			Help_Step{
				"Get the password",
				"In that same dialog, Show Connect Info reveals the password. Leave the password disabled in OBS and you can skip this.",
			},
			Help_Step{
				"Fill it in here and press Connect",
				"Host stays 127.0.0.1 if OBS is on this machine. Tick Remember the password to skip re-typing it next time — it's encrypted before it's written to disk.",
			},
			Help_Step{
				"Six sources appear in your current scene",
				"ER Progress, ER Next Boss, ER Deaths, ER Character, ER Region and ER Region Bosses. They're created with a bold white font and a dark outline, stacked down the left, so they're readable and not piled on top of each other.",
			},
			Help_Step{
				"Delete any you don't want",
				"ER Region shows the first unfinished area and its count (\"Caelid (12/15)\"); ER Region Bosses lists what's left in it, one per line — the same breakdown the overlay's Region mode gives you.",
			},
			Help_Step{
				"Style and place them however you like",
				"They're ordinary OBS text sources. Change the font, colour, size, position — the app only ever updates their text. A source that already exists is never created, moved or restyled, so anything you've set up stays put.",
			},
		)

	case .None:
	}

	return steps[:]
}

help_footer :: proc(topic: Help_Topic) -> string {
	switch topic {
	case .Text_Files:
		return "All three integrations can run at once — text files and a browser source don't conflict."
	case .Obs_Websocket:
		return "If Connect fails, check that the WebSocket server is enabled in OBS and that the port matches."
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
