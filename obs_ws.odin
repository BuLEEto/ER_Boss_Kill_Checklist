package main

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import ws "src/libs/websocket"

// ============================================================================
// obs-websocket v5 client
//
// The integration people expect, because it's how every other OBS tool
// works: connect to OBS's own WebSocket server (Tools → WebSocket Server
// Settings), create a handful of text sources, and keep them updated.
//
// Protocol, briefly (obs-websocket 5.x):
//
//   op 0  Hello        server → us, carries the auth challenge if OBS has
//                      a password set
//   op 1  Identify     us → server, answers the challenge
//   op 2  Identified   server → us, we're in
//   op 6  Request      us → server
//   op 7  RequestResponse
//
// Auth is base64(sha256( base64(sha256(password + salt)) + challenge )).
//
// Threading: connect and every request run on a Skald `cmd_thread`
// worker, never on the GUI thread — OBS being slow must not freeze the
// window. A reader thread drains the socket so server events don't back
// up and so a dropped connection is noticed. `g_obs` is the shared
// handle and everything touching it takes its mutex.
// ============================================================================

OBSWS_SCENE_NONE_LABEL :: "Choose a scene…"

// The Browser source the app creates for the overlay card. Fixed rather
// than derived from anything, because it is also how the source is found
// again on the next connect — rename it in OBS and the app will make a
// new one rather than adopt yours.
OBS_OVERLAY_SOURCE_NAME :: "ER Boss Overlay"

Obsws_State :: enum {
	Disconnected,
	Connecting,
	Connected,
	Failed,
}

Obsws :: struct {
	mu:        sync.Mutex,

	// Held for the whole of a send, and by teardown while it detaches the
	// connection. That pairing is what guarantees a push in flight can't
	// still be writing to a socket the teardown is about to free — the
	// connection pointer is only ever nil'd with this held.
	send_mu:   sync.Mutex,

	conn:      ^ws.Conn,
	state:     Obsws_State,
	status:    string, // owned
	scene:     string,   // owned; scene new sources get added to
	scenes:    []string, // owned; every scene OBS reported, for the picker
	text_kind: string,   // owned; platform's text input kind

	// "browser_source" when this OBS has CEF, empty when it hasn't. The
	// whole overlay-source feature hangs off this being non-empty, so the
	// button never appears for the Debian and Ubuntu builds that ship
	// without a Browser source at all.
	browser_kind: string, // owned

	// Cached for the resize path, which runs on an HTTP worker when the
	// overlay page reports a new size. That thread must not touch
	// app.settings — the GUI thread owns those strings — so everything it
	// needs is copied here while the connect worker still has it.
	overlay_url:     string, // owned
	overlay_managed: bool,
	overlay_banner:  bool,
	reader:    ^thread.Thread,
	next_id:   int,
}

g_obs: Obsws

// ----------------------------------------------------------------------------
// Status, for the OBS tab
// ----------------------------------------------------------------------------

// Whether the connected OBS can host the overlay page. The OBS tab hides
// the option when it can't, rather than offering a switch that silently
// does nothing.
obsws_browser_available :: proc() -> bool {
	sync.mutex_lock(&g_obs.mu)
	defer sync.mutex_unlock(&g_obs.mu)
	return len(g_obs.browser_kind) > 0
}

obsws_status_text :: proc() -> (text: string, kind: Obsws_State) {
	sync.mutex_lock(&g_obs.mu)
	defer sync.mutex_unlock(&g_obs.mu)

	if len(g_obs.status) > 0 {
		return fmt.tprint(g_obs.status), g_obs.state
	}
	switch g_obs.state {
	case .Connected:
		// Connected but idle is a state worth naming: without a scene the
		// app updates sources that already exist and creates nothing.
		if len(g_obs.scene) == 0 {
			return "Connected — choose a scene to add the sources", .Connected
		}
		return fmt.tprintf("Connected to OBS — using scene %s", g_obs.scene), .Connected
	case .Connecting:   return "Connecting…", .Connecting
	case .Failed:       return "Not connected", .Failed
	case .Disconnected: return "Not connected", .Disconnected
	}
	return "Not connected", .Disconnected
}

@(private = "file")
set_status :: proc(state: Obsws_State, msg: string) {
	sync.mutex_lock(&g_obs.mu)
	defer sync.mutex_unlock(&g_obs.mu)
	g_obs.state = state
	if len(g_obs.status) > 0 do delete(g_obs.status)
	g_obs.status = strings.clone(msg)
}

// ----------------------------------------------------------------------------
// Connect / disconnect
// ----------------------------------------------------------------------------

Obsws_Connect_Params :: struct {
	host:     string, // heap; the worker frees them
	port:     int,
	password: string,

	// Captured here rather than read from app.settings on the worker,
	// because the GUI thread owns that string and is free to delete it the
	// moment the user edits a setting. Same reason host and password are
	// cloned — a worker reading live settings is reading memory it doesn't
	// own. Empty means "not chosen", in which case nothing is created.
	scene: string,

	// Same reasoning: font_family and color are heap strings the GUI
	// thread is free to delete the moment the user moves a control, and
	// the worker reads them while building each source's settings. Copied
	// so a font change mid-connect can't pull one out from under it.
	look: Obs_Text_Look,

	// Read on the worker too, and cheap to carry.
	send: [len(Widget_Kind)]bool,

	// The overlay card as a Browser source. `overlay_url` is heap for the
	// same reason host and scene are: it's built from settings the GUI
	// thread can free the moment a control moves.
	send_overlay:   bool,
	overlay_url:    string,
	banner_enabled: bool,
}

// Kick off a connection on a worker thread. Called from `update`, which
// must not block.
obsws_connect_command :: proc() -> Obsws_Connect_Params {
	return Obsws_Connect_Params {
		host           = strings.clone(app.settings.obsws_host),
		port           = app.settings.obsws_port,
		password       = strings.clone(app.settings.obsws_password),
		scene          = strings.clone(app.settings.obsws_scene),
		look           = Obs_Text_Look {
			font_family = strings.clone(app.settings.obsws_look.font_family),
			color       = strings.clone(app.settings.obsws_look.color),
			font_size   = app.settings.obsws_look.font_size,
			bold        = app.settings.obsws_look.bold,
			outline     = app.settings.obsws_look.outline,
		},
		send           = app.settings.obsws_send,
		send_overlay   = app.settings.obsws_send_overlay,
		overlay_url    = overlay_url_string(),
		banner_enabled = app.settings.kill_banner_enabled,
	}
}

obsws_connect_worker :: proc(p: Obsws_Connect_Params) -> Msg {
	defer delete(p.host)
	defer delete(p.password)
	defer delete(p.scene)
	defer delete(p.overlay_url)
	defer delete(p.look.font_family)
	defer delete(p.look.color)

	obsws_teardown()
	set_status(.Connecting, "Connecting…")

	conn, conn_err := ws.connect(p.host, p.port, "/")
	if conn_err != .None {
		msg := fmt.aprintf(
			"Could not reach OBS at %s:%d — is the WebSocket server enabled?",
			p.host, p.port,
		)
		set_status(.Failed, msg)
		return Obsws_Status_Changed{connected = false, message = msg}
	}

	if err_msg, ok := obsws_identify(conn, p.password); !ok {
		ws.destroy(conn)
		set_status(.Failed, err_msg)
		return Obsws_Status_Changed{connected = false, message = err_msg}
	}

	sync.mutex_lock(&g_obs.mu)
	g_obs.conn = conn
	g_obs.state = .Connected
	sync.mutex_unlock(&g_obs.mu)

	// Discover the scene and text-source kind, then make sure our four
	// sources exist. Failure here is not fatal — the connection is still
	// usable, the user just has to create sources by hand.
	obsws_prepare_sources(conn, p)

	// From here the reader parks on a socket that will be silent for
	// minutes at a time, so socket timeouts stop meaning "disconnected".
	// Switched on only now: the handshake and the setup round-trips above
	// all want a timeout to fail rather than hang.
	ws.set_idle_tolerant(conn, true)

	sync.mutex_lock(&g_obs.mu)
	g_obs.reader = thread.create_and_start_with_data(conn, obsws_reader_proc)
	sync.mutex_unlock(&g_obs.mu)

	set_status(.Connected, "Connected to OBS")
	// The first push happens on the GUI thread, in response to this Msg —
	// filling the sources means reading the boss list, and this is a
	// worker thread.
	return Obsws_Status_Changed{
		connected = true,
		message   = strings.clone("Connected to OBS"),
	}
}

obsws_disconnect :: proc() {
	obsws_teardown()
	set_status(.Disconnected, "Not connected")
}

@(private = "file")
obsws_teardown :: proc() {
	// Detach under send_mu so any push already inside obsws_push_update
	// finishes first, and any later one sees a nil connection.
	sync.mutex_lock(&g_obs.send_mu)
	sync.mutex_lock(&g_obs.mu)
	conn := g_obs.conn
	reader := g_obs.reader
	g_obs.conn = nil
	g_obs.reader = nil
	g_obs.state = .Disconnected
	sync.mutex_unlock(&g_obs.mu)
	sync.mutex_unlock(&g_obs.send_mu)

	if conn != nil {
		// Closing the socket is what wakes the reader out of `receive`.
		ws.close(conn)
	}
	if reader != nil {
		thread.join(reader)
		thread.destroy(reader)
	}
	if conn != nil do ws.destroy(conn)
}

// Drains server events so the socket buffer doesn't fill, and notices
// when OBS goes away.
@(private = "file")
obsws_reader_proc :: proc(data: rawptr) {
	conn := cast(^ws.Conn)data
	for {
		msg, err := ws.receive(conn, context.temp_allocator)
		if err != .None {
			// Only report a drop if this is still the live connection —
			// a deliberate teardown already set the status.
			sync.mutex_lock(&g_obs.mu)
			live := g_obs.conn == conn
			sync.mutex_unlock(&g_obs.mu)
			if live {
				set_status(.Failed, "Lost the connection to OBS")
			}
			return
		}
		_ = msg
		free_all(context.temp_allocator)
	}
}

// ----------------------------------------------------------------------------
// Handshake
// ----------------------------------------------------------------------------

@(private = "file")
obsws_identify :: proc(conn: ^ws.Conn, password: string) -> (err_msg: string, ok: bool) {
	hello, hello_err := ws.receive(conn, context.temp_allocator)
	if hello_err != .None {
		return strings.clone("OBS accepted the connection but sent no Hello"), false
	}

	root, parse_err := json.parse(hello.payload, allocator = context.temp_allocator)
	if parse_err != .None {
		return strings.clone("Could not read OBS's Hello message"), false
	}

	d := json_object(root, "d")

	// `authentication` is absent when OBS has no password configured.
	auth_response := ""
	if auth, has_auth := json_object_opt(d, "authentication"); has_auth {
		challenge := json_string(auth, "challenge")
		salt := json_string(auth, "salt")
		if len(password) == 0 {
			return strings.clone(
				"OBS requires a password — enter the one from Tools → WebSocket Server Settings",
			), false
		}
		auth_response = obsws_auth(password, salt, challenge, context.temp_allocator)
	}

	identify := strings.builder_make(context.temp_allocator)
	strings.write_string(&identify, `{"op":1,"d":{"rpcVersion":1`)
	if len(auth_response) > 0 {
		strings.write_string(&identify, `,"authentication":"`)
		json_escape_string(&identify, auth_response)
		strings.write_string(&identify, `"`)
	}
	// eventSubscriptions 0: we only push, we don't listen for events.
	strings.write_string(&identify, `,"eventSubscriptions":0}}`)

	if ws.send_text(conn, strings.to_string(identify)) != .None {
		return strings.clone("Could not send the Identify message to OBS"), false
	}

	reply, reply_err := ws.receive(conn, context.temp_allocator)
	if reply_err != .None {
		return strings.clone("OBS closed the connection during authentication"), false
	}

	reply_root, reply_parse := json.parse(reply.payload, allocator = context.temp_allocator)
	if reply_parse != .None {
		return strings.clone("Could not read OBS's reply"), false
	}

	if json_int(reply_root, "op") != 2 {
		return strings.clone("OBS rejected the connection — check the password"), false
	}
	return "", true
}

// base64(sha256( base64(sha256(password + salt)) + challenge ))
@(private = "file")
obsws_auth :: proc(
	password, salt, challenge: string,
	allocator := context.allocator,
) -> string {
	secret_digest: [sha2.DIGEST_SIZE_256]u8
	{
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, transmute([]u8)password)
		sha2.update(&ctx, transmute([]u8)salt)
		sha2.final(&ctx, secret_digest[:])
	}
	secret, _ := base64.encode(secret_digest[:], allocator = context.temp_allocator)

	auth_digest: [sha2.DIGEST_SIZE_256]u8
	{
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, transmute([]u8)secret)
		sha2.update(&ctx, transmute([]u8)challenge)
		sha2.final(&ctx, auth_digest[:])
	}

	encoded, _ := base64.encode(auth_digest[:], allocator = allocator)
	return encoded
}

// ----------------------------------------------------------------------------
// Requests
// ----------------------------------------------------------------------------

// Fire-and-forget: the reader thread swallows the response. Everything
// we send is idempotent, and a stream overlay is not worth blocking the
// caller for a round trip.
@(private = "file")
obsws_request :: proc(conn: ^ws.Conn, request_type: string, request_data: string) -> (int, bool) {
	if conn == nil do return 0, false

	sync.mutex_lock(&g_obs.mu)
	g_obs.next_id += 1
	id := g_obs.next_id
	sync.mutex_unlock(&g_obs.mu)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"op":6,"d":{{"requestType":"%s","requestId":"%d"`, request_type, id)
	if len(request_data) > 0 {
		fmt.sbprintf(&b, `,"requestData":%s`, request_data)
	}
	strings.write_string(&b, "}}")

	return id, ws.send_text(conn, strings.to_string(b)) == .None
}

// Work out which scene to build in, learn which text plugin this platform
// has, and make sure every ticked source exists there.
//
// Safe to run more than once: it is what a fresh connection calls, and
// also what a change of target scene calls. Everything it does is
// conditional on what OBS already has.
@(private = "file")
obsws_prepare_sources :: proc(conn: ^ws.Conn, p: Obsws_Connect_Params) {
	scenes := obsws_scene_list(conn, context.temp_allocator)

	// Only ever the scene the user picked. No fallback to whatever is on
	// air: creating seven sources in someone's Starting Soon scene because
	// that's what OBS happened to be showing is not a helpful default, and
	// it's the kind of mess you discover mid-stream.
	scene := ""
	for sc in scenes {
		if sc == p.scene { scene = p.scene; break }
	}

	// The OBS plugin id for a text source, e.g. text_ft2_source_v2 — not
	// to be confused with the Widget_Kind values looped over below.
	input_kind := obsws_text_kind(conn)

	// Empty on an OBS without CEF. Everything overlay-source related is
	// conditional on it, including whether the GUI offers the option.
	browser_kind := obsws_browser_kind(conn)

	sync.mutex_lock(&g_obs.mu)
	if len(g_obs.scene) > 0 do delete(g_obs.scene)
	if len(g_obs.text_kind) > 0 do delete(g_obs.text_kind)
	if len(g_obs.browser_kind) > 0 do delete(g_obs.browser_kind)
	if len(g_obs.overlay_url) > 0 do delete(g_obs.overlay_url)
	obsws_free_scenes()
	g_obs.scene = strings.clone(scene)
	g_obs.text_kind = strings.clone(input_kind)
	g_obs.browser_kind = strings.clone(browser_kind)
	g_obs.overlay_url = strings.clone(p.overlay_url)
	g_obs.overlay_managed = p.send_overlay && len(browser_kind) > 0
	g_obs.overlay_banner = p.banner_enabled
	g_obs.scenes = make([]string, len(scenes))
	for n, i in scenes do g_obs.scenes[i] = strings.clone(n)
	sync.mutex_unlock(&g_obs.mu)

	// No scene chosen, or one that has since been renamed or deleted.
	// Connect anyway — sources that already exist keep being updated,
	// because SetInputSettings addresses them by name and doesn't care
	// which scene they're in. Only creation waits for a choice.
	if len(scene) == 0 || len(input_kind) == 0 do return

	// Ask what already exists before creating anything. Relying on
	// CreateInput failing for a duplicate was enough while all we did was
	// create — but now that new sources also get positioned, we have to
	// know which ones are ours to move. A source the user has already
	// placed and styled must be left exactly where it is.
	existing := obsws_input_names(conn)

	// Newly-created sources are stacked down the left rather than all
	// landing on top of each other at the origin, which is what OBS does
	// with four sources created back to back.
	y := f32(48)
	LINE_HEIGHT :: f32(72)

	for kind in Widget_Kind {
		name := obs_source_name(kind)

		// Unticked: hide it rather than delete it. The user may have
		// styled and positioned it, and OBS has no undo for a deleted
		// source — hiding takes it off the canvas, is one click to
		// reverse, and re-ticking here brings it straight back.
		if !p.send[int(kind)] {
			if name in existing do obsws_show_source(conn, scene, name, false)
			continue
		}

		if name in existing {
			// The input exists somewhere in OBS, which is not the same as
			// it being in *this* scene — inputs are global and a scene
			// item is only a reference to one. After a change of target
			// scene the input is there and the reference isn't, so add
			// one rather than leaving the user with a source they can't
			// see and no clue why.
			if _, in_scene := obsws_scene_item_id(conn, scene, name); in_scene {
				obsws_show_source(conn, scene, name, true)
				continue
			}
			if obsws_create_scene_item(conn, scene, name) {
				obsws_place_source(conn, scene, name, 48, y)
				y += LINE_HEIGHT
			}
			continue
		}

		// Always an OBS text source. This integration exists for the OBS
		// builds that have no browser source at all — Debian and Ubuntu
		// package OBS without CEF — so creating browser sources here would
		// be creating the one thing those users can't use. Anyone who does
		// have browser sources is better served by copying a URL from the
		// Overlay card or Single values panel.
		kind_id := input_kind
		settings := obsws_style_settings(input_kind, p.look, OBS_STYLE_ALL, with_text = true)

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"sceneName":"`)
		json_escape_string(&b, scene)
		strings.write_string(&b, `","inputName":"`)
		json_escape_string(&b, name)
		strings.write_string(&b, `","inputKind":"`)
		json_escape_string(&b, kind_id)
		strings.write_string(&b, `","inputSettings":`)
		strings.write_string(&b, settings)
		strings.write_string(&b, `,"sceneItemEnabled":true}`)
		obsws_request(conn, "CreateInput", strings.to_string(b))

		obsws_place_source(conn, scene, name, 48, y)
		y += LINE_HEIGHT
	}

	obsws_prepare_overlay(conn, p, scene, browser_kind, existing, y)
}

// The overlay card as a Browser source.
//
// Kept apart from the text loop above because it is not one of the eight:
// it points at a page we serve rather than carrying text we push, and it
// only exists at all where OBS has CEF.
//
// Unticked is hide-not-delete, the same bargain the text sources strike —
// the user may have positioned it, and OBS has no undo for a deleted
// source.
@(private = "file")
obsws_prepare_overlay :: proc(
	conn: ^ws.Conn,
	p: Obsws_Connect_Params,
	scene, browser_kind: string,
	existing: map[string]bool,
	y: f32,
) {
	if len(browser_kind) == 0 do return

	name := OBS_OVERLAY_SOURCE_NAME

	if !p.send_overlay {
		if name in existing do obsws_show_source(conn, scene, name, false)
		return
	}

	width, height, have_size := app_overlay_fit_size(p.banner_enabled)

	if name in existing {
		// Already somewhere in OBS. Point it at the current URL and, if
		// the page has told us how big the card is, fit it — the settings
		// that shape the URL may well have changed since it was made.
		obsws_set_overlay_settings(conn, p.overlay_url, width, height, have_size)

		if _, in_scene := obsws_scene_item_id(conn, scene, name); in_scene {
			obsws_show_source(conn, scene, name, true)
			return
		}
		if obsws_create_scene_item(conn, scene, name) {
			obsws_place_source(conn, scene, name, 48, y)
		}
		return
	}

	// A first-run source with no measurement yet gets OBS's own defaults
	// rather than a guess of ours; the page reports its size as soon as it
	// loads, and the resize lands moments later.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"sceneName":"`)
	json_escape_string(&b, scene)
	strings.write_string(&b, `","inputName":"`)
	json_escape_string(&b, name)
	strings.write_string(&b, `","inputKind":"`)
	json_escape_string(&b, browser_kind)
	strings.write_string(&b, `","inputSettings":`)
	obsws_overlay_settings_json(&b, p.overlay_url, width, height, have_size)
	strings.write_string(&b, `,"sceneItemEnabled":true}`)
	obsws_request(conn, "CreateInput", strings.to_string(b))

	obsws_place_source(conn, scene, name, 48, y)
}

// The inputSettings body for the overlay Browser source. `with_size` is
// false before the page has ever reported a measurement, in which case we
// send the URL alone and leave the dimensions to OBS.
@(private = "file")
obsws_overlay_settings_json :: proc(
	b: ^strings.Builder,
	url: string,
	width, height: int,
	with_size: bool,
) {
	strings.write_string(b, `{"url":"`)
	json_escape_string(b, url)
	strings.write_string(b, `"`)
	if with_size {
		fmt.sbprintf(b, `,"width":%d,"height":%d`, width, height)
	}
	// The page drives its own updates over SSE, so OBS re-rendering it
	// when the scene becomes active would only throw away a live one.
	strings.write_string(b, `,"reroute_audio":false,"shutdown":false,"restart_when_active":false}`)
}

@(private = "file")
obsws_set_overlay_settings :: proc(
	conn: ^ws.Conn,
	url: string,
	width, height: int,
	with_size: bool,
) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"inputName":"`)
	json_escape_string(&b, OBS_OVERLAY_SOURCE_NAME)
	strings.write_string(&b, `","inputSettings":`)
	obsws_overlay_settings_json(&b, url, width, height, with_size)
	strings.write_string(&b, `,"overlay":true}`)
	obsws_request(conn, "SetInputSettings", strings.to_string(b))
}

// Add an existing input to a scene as a new scene item. Used when the
// target scene changes: the input is already there, it just isn't
// referenced from the scene the user has now picked.
@(private = "file")
obsws_create_scene_item :: proc(conn: ^ws.Conn, scene, name: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"sceneName":"`)
	json_escape_string(&b, scene)
	strings.write_string(&b, `","sourceName":"`)
	json_escape_string(&b, name)
	strings.write_string(&b, `","sceneItemEnabled":true}`)
	_, ok := obsws_request_sync(conn, "CreateSceneItem", strings.to_string(b))
	return ok
}

// Every scene OBS knows about, in the order it reports them.
@(private = "file")
obsws_scene_list :: proc(conn: ^ws.Conn, allocator := context.allocator) -> []string {
	d, ok := obsws_request_sync(conn, "GetSceneList")
	if !ok do return nil

	data := json_object(d, "responseData")
	obj, is_obj := data.(json.Object)
	if !is_obj do return nil

	raw, has := obj["scenes"]
	if !has do return nil
	arr, is_arr := raw.(json.Array)
	if !is_arr do return nil

	out := make([dynamic]string, 0, len(arr), allocator)
	for v in arr {
		if name := json_string(v, "sceneName"); len(name) > 0 {
			append(&out, name)
		}
	}
	return out[:]
}

// Caller must hold g_obs.mu.
@(private = "file")
obsws_free_scenes :: proc() {
	for sc in g_obs.scenes do delete(sc)
	if g_obs.scenes != nil do delete(g_obs.scenes)
	g_obs.scenes = nil
}

// The scene list, cloned for the caller. The GUI calls this every frame
// while the OBS tab is open, so it clones into the frame arena rather
// than handing out pointers into state a reconnect is free to free.
obsws_scene_names :: proc(allocator := context.temp_allocator) -> []string {
	sync.mutex_lock(&g_obs.mu)
	defer sync.mutex_unlock(&g_obs.mu)

	if len(g_obs.scenes) == 0 do return nil
	out := make([]string, len(g_obs.scenes), allocator)
	for sc, i in g_obs.scenes do out[i] = strings.clone(sc, allocator)
	return out
}

// The scene sources are actually being built in, for the OBS tab to show.
obsws_active_scene :: proc(allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&g_obs.mu)
	defer sync.mutex_unlock(&g_obs.mu)
	return strings.clone(g_obs.scene, allocator)
}

// The styling half of a text source's settings, built from obsws_look.
//
// The two plugins don't share a schema — text_gdiplus takes `color` plus
// outline_color/outline_size, text_ft2_source_v2 takes color1/color2 and
// has no outline colour of its own. Send each what it understands: OBS
// ignores keys it doesn't know, but sending the wrong font shape means no
// font is applied at all.
//
// `text` is deliberately absent. Every SetInputSettings here goes with
// "overlay":true, which merges, so pushing style alone leaves the current
// value on screen untouched.
@(private = "file")
// Which parts of the look to send.
//
// A control only overwrites what it governs. Nudging the size used to
// resend colour and outline as well, so a source you'd turned red by hand
// in OBS went back to white because you moved a slider that had nothing to
// do with colour. Font, colour and outline travel separately now.
//
// Font is one unit because OBS replaces a nested object wholesale rather
// than merging into it — face, size and style have to go together or the
// two you didn't send are lost.
Obs_Style_Part :: enum { Font, Colour, Outline }
Obs_Style_Parts :: bit_set[Obs_Style_Part]

OBS_STYLE_ALL :: Obs_Style_Parts{.Font, .Colour, .Outline}

obsws_style_settings :: proc(
	kind:      string,
	look:      Obs_Text_Look,
	parts:     Obs_Style_Parts,
	with_text: bool,
) -> string {
	gdi := strings.has_prefix(kind, "text_gdiplus")

	// Collected as fragments and joined, so an omitted part can't leave a
	// stray comma behind — which would be malformed JSON, and OBS discards
	// those without a word.
	frags := make([dynamic]string, context.temp_allocator)

	if with_text do append(&frags, `"text":""`)

	if .Colour in parts {
		colour := obsws_abgr(look.color)
		if gdi {
			append(&frags, fmt.tprintf(`"color":%d`, colour))
		} else {
			// color1/color2 are the ends of a gradient; the same value in
			// both is a flat fill.
			append(&frags, fmt.tprintf(`"color1":%d,"color2":%d`, colour, colour))
		}
	}

	if .Outline in parts {
		append(&frags, fmt.tprintf(`"outline":%s`, look.outline ? "true" : "false"))
		if gdi {
			// Black outline at 2px. Not exposed: an outline colour and
			// width is two more controls for something that only ever
			// wants to be a dark edge holding the text off the gameplay.
			append(&frags, `"outline_color":4278190080,"outline_size":2`)
		}
	}

	if .Font in parts {
		face := look.font_family
		if len(face) == 0 {
			// Each plugin's own default rather than one shared name that
			// only exists on one platform.
			face = gdi ? "Arial" : "Sans Serif"
		}
		fb := strings.builder_make(context.temp_allocator)
		strings.write_string(&fb, `"font":{"face":"`)
		json_escape_string(&fb, face)
		// Two braces for one literal `}` — sbprintf reads `}}` as an
		// escape. This fragment closes the font object only; the
		// surrounding settings object is added by the tprintf below. It
		// wanted four when this proc built the whole thing, and getting
		// that count wrong in either direction produces JSON that OBS
		// discards without a word.
		fmt.sbprintf(&fb, `","size":%d,"style":"%s","flags":0}}`,
			look.font_size, look.bold ? "Bold" : "Regular")
		append(&frags, strings.to_string(fb))
	}

	return fmt.tprintf("{{%s}}", strings.join(frags[:], ",", context.temp_allocator))
}

// "#rrggbb" to the ABGR integer with full alpha that OBS wants.
@(private = "file")
obsws_abgr :: proc(hex: string) -> u32 {
	if !is_hex_colour(hex) do return 0xFFFFFFFF
	v, ok := strconv.parse_u64_of_base(hex[1:], 16)
	if !ok do return 0xFFFFFFFF
	r := u32(v >> 16) & 0xFF
	g := u32(v >> 8) & 0xFF
	b := u32(v) & 0xFF
	return 0xFF000000 | (b << 16) | (g << 8) | r
}

// Push the styling to every source we own.
//
// Only called when the user changes something on the panel — never on a
// data update. That keeps the promise that the app only touches their
// text as they play, while still letting the panel be the place styling
// is set. Restyle a source in OBS and it stays that way until you change
// a control here.
obsws_push_style :: proc(parts: Obs_Style_Parts) {
	sync.mutex_lock(&g_obs.send_mu)
	defer sync.mutex_unlock(&g_obs.send_mu)

	sync.mutex_lock(&g_obs.mu)
	conn := g_obs.conn
	connected := g_obs.state == .Connected
	kind := strings.clone(g_obs.text_kind, context.temp_allocator)
	sync.mutex_unlock(&g_obs.mu)

	if !connected || conn == nil || len(kind) == 0 do return

	for k in Widget_Kind {
		if !obsws_sends(k) do continue
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"inputName":"`)
		json_escape_string(&b, obs_source_name(k))
		strings.write_string(&b, `","inputSettings":`)
		strings.write_string(&b, obsws_style_settings(kind, app.settings.obsws_look, parts, with_text = false))
		strings.write_string(&b, `,"overlay":true}`)
		obsws_request(conn, "SetInputSettings", strings.to_string(b))
	}
}

// Names of every input OBS currently knows about.
@(private = "file")
obsws_input_names :: proc(conn: ^ws.Conn) -> map[string]bool {
	names := make(map[string]bool, 16, context.temp_allocator)

	d, ok := obsws_request_sync(conn, "GetInputList")
	if !ok do return names

	data := json_object(d, "responseData")
	obj, is_obj := data.(json.Object)
	if !is_obj do return names

	list, has := obj["inputs"]
	if !has do return names
	arr, is_arr := list.(json.Array)
	if !is_arr do return names

	for entry in arr {
		if n := json_string(entry, "inputName"); len(n) > 0 {
			names[n] = true
		}
	}
	return names
}

// Show or hide a scene item without deleting it.
@(private = "file")
obsws_show_source :: proc(conn: ^ws.Conn, scene, name: string, visible: bool) {
	item_id, ok := obsws_scene_item_id(conn, scene, name)
	if !ok do return

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"sceneName":"`)
	json_escape_string(&b, scene)
	fmt.sbprintf(
		&b,
		`","sceneItemId":%d,"sceneItemEnabled":%s}}`,
		item_id, visible ? "true" : "false",
	)
	obsws_request(conn, "SetSceneItemEnabled", strings.to_string(b))
}

// A scene item's id, which is per scene rather than per source, so it
// takes a round trip to look up.
@(private = "file")
obsws_scene_item_id :: proc(conn: ^ws.Conn, scene, name: string) -> (i64, bool) {
	q := strings.builder_make(context.temp_allocator)
	strings.write_string(&q, `{"sceneName":"`)
	json_escape_string(&q, scene)
	strings.write_string(&q, `","sourceName":"`)
	json_escape_string(&q, name)
	strings.write_string(&q, `"}`)

	d, ok := obsws_request_sync(conn, "GetSceneItemId", strings.to_string(q))
	if !ok do return 0, false

	id := json_int(json_object(d, "responseData"), "sceneItemId")
	return id, id > 0
}

// Move a scene item to a position.
@(private = "file")
obsws_place_source :: proc(conn: ^ws.Conn, scene, name: string, x, y: f32) {
	item_id, ok := obsws_scene_item_id(conn, scene, name)
	if !ok do return

	t := strings.builder_make(context.temp_allocator)
	strings.write_string(&t, `{"sceneName":"`)
	json_escape_string(&t, scene)
	fmt.sbprintf(
		&t,
		`","sceneItemId":%d,"sceneItemTransform":{{"positionX":%.1f,"positionY":%.1f}}}}`,
		item_id, x, y,
	)
	obsws_request(conn, "SetSceneItemTransform", strings.to_string(t))
}

// Round-trip helper for the two setup queries. Unlike the fire-and-
// forget path this waits for the reply, which is fine because it only
// runs on the connect worker before the reader thread starts.
@(private = "file")
obsws_request_sync :: proc(
	conn: ^ws.Conn,
	request_type: string,
	request_data := "",
	allocator := context.temp_allocator,
) -> (
	json.Value,
	bool,
) {
	id, sent := obsws_request(conn, request_type, request_data)
	if !sent do return nil, false

	// Match on requestId, not just "the next op 7 that turns up".
	// Fire-and-forget requests (CreateInput) leave their own responses
	// queued on the socket, so taking the first RequestResponse handed
	// back the wrong one — which read as a missing sceneItemId and
	// silently skipped positioning every other source.
	expected := fmt.tprintf("%d", id)

	for _ in 0 ..< 32 {
		reply, err := ws.receive(conn, allocator)
		if err != .None do return nil, false

		root, parse_err := json.parse(reply.payload, allocator = allocator)
		if parse_err != .None do continue
		if json_int(root, "op") != 7 do continue

		d := json_object(root, "d")
		if json_string(d, "requestId") != expected do continue
		return d, true
	}
	return nil, false
}

// Pick the platform's text source plugin: text_gdiplus_v3 / _v2 on
// Windows, text_ft2_source_v2 on Linux. Rather than hardcode a table,
// ask OBS and take the first text kind it reports.
// Does this OBS have a Browser source at all?
//
// Debian and Ubuntu package OBS without CEF, and there the kind simply
// isn't in the list. Everything about the overlay source hangs off this, so
// those users never see a control that couldn't work.
@(private = "file")
obsws_browser_kind :: proc(conn: ^ws.Conn) -> string {
	d, ok := obsws_request_sync(conn, "GetInputKindList")
	if !ok do return ""

	data := json_object(d, "responseData")
	obj, is_obj := data.(json.Object)
	if !is_obj do return ""

	kinds, has := obj["inputKinds"]
	if !has do return ""
	arr, is_arr := kinds.(json.Array)
	if !is_arr do return ""

	for v in arr {
		str, is_str := v.(json.String)
		if !is_str do continue
		if string(str) == "browser_source" do return "browser_source"
	}
	return ""
}

@(private = "file")
obsws_text_kind :: proc(conn: ^ws.Conn) -> string {
	d, ok := obsws_request_sync(conn, "GetInputKindList")
	if !ok do return ""

	data := json_object(d, "responseData")
	obj, is_obj := data.(json.Object)
	if !is_obj do return ""

	kinds, has := obj["inputKinds"]
	if !has do return ""
	arr, is_arr := kinds.(json.Array)
	if !is_arr do return ""

	// Prefer GDI+ where both exist — it's the better renderer on Windows.
	fallback := ""
	for v in arr {
		s, is_str := v.(json.String)
		if !is_str do continue
		if !strings.has_prefix(string(s), "text_") do continue
		if strings.has_prefix(string(s), "text_gdiplus") do return string(s)
		if len(fallback) == 0 do fallback = string(s)
	}
	return fallback
}

// ----------------------------------------------------------------------------
// Pushing progress
// ----------------------------------------------------------------------------

// Called from the HTTP worker that took a fresh measurement from the
// overlay page, to keep a managed Browser source fitted to the card.
//
// Touches nothing the GUI thread owns. The URL, the managed flag and the
// banner setting were all copied onto g_obs by the connect worker precisely
// so this path never has to read app.settings from another thread.
obsws_push_overlay_size :: proc() {
	sync.mutex_lock(&g_obs.send_mu)
	defer sync.mutex_unlock(&g_obs.send_mu)

	sync.mutex_lock(&g_obs.mu)
	conn := g_obs.conn
	connected := g_obs.state == .Connected
	managed := g_obs.overlay_managed
	banner := g_obs.overlay_banner
	url := strings.clone(g_obs.overlay_url, context.temp_allocator)
	sync.mutex_unlock(&g_obs.mu)

	if !connected || conn == nil || !managed do return

	width, height, ok := app_overlay_fit_size(banner)
	if !ok do return

	obsws_set_overlay_settings(conn, url, width, height, true)
}

// Called from the GUI thread after a change. Sends four SetInputSettings
// requests; if OBS isn't connected this is a no-op.
obsws_push_update :: proc() {
	sync.mutex_lock(&g_obs.send_mu)
	defer sync.mutex_unlock(&g_obs.send_mu)

	sync.mutex_lock(&g_obs.mu)
	conn := g_obs.conn
	connected := g_obs.state == .Connected
	sync.mutex_unlock(&g_obs.mu)

	if !connected || conn == nil do return

	total, killed := count_bosses(app.regions)
	name, level := app_active_character()

	next := app_next_bosses(1, context.temp_allocator)
	next_text := len(next) > 0 \
		? fmt.tprintf("%s — %s", next[0].boss, next[0].place) \
		: "All bosses defeated"

	character := len(name) > 0 ? fmt.tprintf("%s — RL %d", name, level) : "No character"

	attempts_text := "Attempt —"
	if n, ok := app_attempts(); ok {
		attempts_text = fmt.tprintf("Attempt %d", n)
	}
	session_text := session_summary()

	region_text := "All regions cleared"
	region_bosses := "All regions cleared"
	if idx := app_focus_region(app.settings.obsws_region); idx >= 0 {
		r := &app.regions[idx]
		r_total, r_killed := count_region_bosses(r)
		region_text = fmt.tprintf("%s (%d/%d)", r.region_name, r_killed, r_total)

		names := make([dynamic]string, context.temp_allocator)
		for &boss in r.bosses {
			if boss.killed do continue
			append(&names, boss.boss)
		}
		region_bosses = obs_join_lines(names[:], app.settings.obsws_roomy_lines)
	}

	// Built per kind so Widget_Kind stays the single source of truth for
	// what each source shows.
	for kind in Widget_Kind {
		if !obsws_sends(kind) do continue

		// Self-labelling, unlike the served pages. A text source stands
		// alone on the canvas with no caption above it, so "Deaths: 57"
		// has to carry its own word or it's a number with no meaning.
		value: string
		switch kind {
		case .Progress:      value = fmt.tprintf("%d / %d bosses", killed, total)
		case .Next_Boss:     value = next_text
		case .Deaths:        value = fmt.tprintf("Deaths: %d", app.death_count)
		case .Character:     value = character
		case .Region:        value = region_text
		case .Region_Bosses: value = region_bosses
		case .Attempts:      value = attempts_text
		case .Session:       value = session_text
		}

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"inputName":"`)
		json_escape_string(&b, obs_source_name(kind))
		strings.write_string(&b, `","inputSettings":{"text":"`)
		json_escape_string(&b, value)
		strings.write_string(&b, `"},"overlay":true}`)
		obsws_request(conn, "SetInputSettings", strings.to_string(b))
	}
}
