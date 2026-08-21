package main

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
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

// Text sources the app can create and keep updated. Each is
// individually switchable from the OBS tab — unchecked ones are never
// created and never updated, because unlike a text file (which is a few
// bytes in a folder) a source is a real object in someone's scene.
//
// The "ER " prefix keeps them recognisable in OBS's source list and out
// of the way of the user's own names. Values carry their own label where
// a bare number would be meaningless alone — a text source stands by
// itself on screen, it isn't a cell next to a heading.
Obs_Source :: enum {
	Progress,      // "113 / 207 bosses"
	Next_Boss,     // the next boss standing, with its location
	Deaths,        // "Deaths: 57"
	Character,     // name and level
	Region,        // the focused area and its count
	Region_Bosses, // what's left in that area, one per line
	Attempts,      // "Attempt 12" — deaths since the last kill
	Session,       // "2 bosses · 31 deaths" this sitting

	// Not a text source: a browser source pointed at the overlay page
	// this app already serves. It's the only way to get real typography
	// in OBS — text sources have no alignment, no line height, and no
	// per-line control — so anything that wants a properly laid-out list
	// goes through here.
	Overlay,
}

obs_source_name :: proc(k: Obs_Source) -> string {
	switch k {
	case .Progress:      return "ER Progress"
	case .Next_Boss:     return "ER Next Boss"
	case .Deaths:        return "ER Deaths"
	case .Character:     return "ER Character"
	case .Region:        return "ER Region"
	case .Region_Bosses: return "ER Region Bosses"
	case .Attempts:      return "ER Attempts"
	case .Session:       return "ER Session"
	case .Overlay:       return "ER Overlay"
	}
	return ""
}

obs_source_label :: proc(k: Obs_Source) -> string {
	switch k {
	case .Progress:      return "Progress — \"113 / 207 bosses\""
	case .Next_Boss:     return "Next boss — with its location"
	case .Deaths:        return "Deaths — \"Deaths: 57\""
	case .Character:     return "Character — name and level"
	case .Region:        return "Region — the area and its count"
	case .Region_Bosses: return "Region bosses — what's left there"
	case .Attempts:      return "Attempts — deaths since your last kill"
	case .Session:       return "Session — bosses and deaths this sitting"
	case .Overlay:       return "Overlay page — the styled browser source"
	}
	return ""
}

// The /widget?type= value backing this source when the web style is in
// use. The overlay isn't one of these — it has its own full page.
obs_source_widget :: proc(k: Obs_Source) -> string {
	switch k {
	case .Progress:      return "progress"
	case .Next_Boss:     return "next"
	case .Deaths:        return "deaths"
	case .Character:     return "character"
	case .Region:        return "region"
	case .Region_Bosses: return "region_bosses"
	case .Attempts:      return "attempts"
	case .Session:       return "session"
	case .Overlay:       return ""
	}
	return ""
}

obs_source_enabled :: proc(k: Obs_Source) -> bool {
	switch k {
	case .Progress:      return app.settings.obsws_send_progress
	case .Next_Boss:     return app.settings.obsws_send_next_boss
	case .Deaths:        return app.settings.obsws_send_deaths
	case .Character:     return app.settings.obsws_send_character
	case .Region:        return app.settings.obsws_send_region
	case .Region_Bosses: return app.settings.obsws_send_region_bosses
	case .Attempts:      return app.settings.obsws_send_attempts
	case .Session:       return app.settings.obsws_send_session
	case .Overlay:       return app.settings.obsws_send_overlay
	}
	return false
}

// The scene picker's placeholder. An empty obsws_scene means "the user
// hasn't chosen yet", and in that state the app creates nothing at all —
// see obsws_prepare_sources. Falling back to the live scene was worse
// than useless: connect while OBS happens to be on Starting Soon and the
// sources land there, and you don't find out until you're on air.
OBSWS_SCENE_NONE_LABEL :: "Choose a scene…"

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
	reader:    ^thread.Thread,
	next_id:   int,
}

g_obs: Obsws

// ----------------------------------------------------------------------------
// Status, for the OBS tab
// ----------------------------------------------------------------------------

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
	// own. Empty means "whatever scene is live when we get there".
	scene: string,
}

// Kick off a connection on a worker thread. Called from `update`, which
// must not block.
obsws_connect_command :: proc() -> Obsws_Connect_Params {
	return Obsws_Connect_Params {
		host     = strings.clone(app.settings.obsws_host),
		port     = app.settings.obsws_port,
		password = strings.clone(app.settings.obsws_password),
		scene    = strings.clone(app.settings.obsws_scene),
	}
}

obsws_connect_worker :: proc(p: Obsws_Connect_Params) -> Msg {
	defer delete(p.host)
	defer delete(p.password)
	defer delete(p.scene)

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
	obsws_prepare_sources(conn, p.scene)

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
obsws_prepare_sources :: proc(conn: ^ws.Conn, want_scene: string) {
	scenes := obsws_scene_list(conn, context.temp_allocator)

	// Only ever the scene the user picked. No fallback to whatever is on
	// air: creating seven sources in someone's Starting Soon scene because
	// that's what OBS happened to be showing is not a helpful default, and
	// it's the kind of mess you discover mid-stream.
	scene := ""
	for sc in scenes {
		if sc == want_scene { scene = want_scene; break }
	}

	// The OBS plugin id for a text source, e.g. text_ft2_source_v2 — not
	// to be confused with the Obs_Source kinds looped over below.
	input_kind := obsws_text_kind(conn)

	sync.mutex_lock(&g_obs.mu)
	if len(g_obs.scene) > 0 do delete(g_obs.scene)
	if len(g_obs.text_kind) > 0 do delete(g_obs.text_kind)
	obsws_free_scenes()
	g_obs.scene = strings.clone(scene)
	g_obs.text_kind = strings.clone(input_kind)
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

	for kind in Obs_Source {
		name := obs_source_name(kind)

		// Unticked: hide it rather than delete it. The user may have
		// styled and positioned it, and OBS has no undo for a deleted
		// source — hiding takes it off the canvas, is one click to
		// reverse, and re-ticking here brings it straight back.
		if !obs_source_enabled(kind) {
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

		web := kind == .Overlay || app.settings.obsws_source_style == "web"
		kind_id := web ? "browser_source" : input_kind
		settings: string
		switch {
		case kind == .Overlay: settings = obsws_browser_settings(with_size = true)
		case web:              settings = obsws_widget_settings(kind, with_size = true)
		case:                  settings = obsws_default_text_settings(input_kind)
		}

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

// A browser source pointed at our own overlay page.
//
// This is what makes real typography possible in OBS: the page is HTML
// we serve and style, so alignment, line height and layout are CSS
// rather than whatever the text plugin happens to support. The page
// refreshes itself over SSE, so OBS never has to poll it.
//
// `with_size` is only true at creation. SetInputSettings merges the keys
// it's given over the existing ones, so resending width and height on
// every update would undo a resize the user had made in OBS. The URL is
// the one field we do have to maintain, because it carries the overlay
// mode, region and alignment.
//
// Note what is deliberately never sent: "css". That's OBS's Custom CSS
// box, and it belongs to the user — it's how they restyle the overlay.
// The page's colours are CSS variables on :root precisely so a couple of
// lines in that box can repaint the whole thing.
@(private = "file")
obsws_browser_settings :: proc(with_size := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"url":"`)
	json_escape_string(&b, overlay_url_string(context.temp_allocator))
	strings.write_string(&b, `"`)
	if with_size {
		// Generous enough for the longest list; the card inside is only
		// as big as its content, and the rest of the page is transparent.
		strings.write_string(&b, `,"width":520,"height":900,"reroute_audio":false`)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// One value as its own browser source. Same reasoning as
// obsws_browser_settings: never send "css" (that box is the user's), and
// only send a size at creation so a resize survives.
@(private = "file")
obsws_widget_settings :: proc(kind: Obs_Source, with_size := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"url":"`)
	json_escape_string(&b, fmt.tprintf(
		"http://localhost:%d/widget?type=%s&align=%s",
		app.server.port, obs_source_widget(kind), app.settings.ws_look.align,
	))
	strings.write_string(&b, `"`)
	if with_size {
		// Wide enough for the longest boss name; lists get more height.
		h := kind == .Region_Bosses ? 420 : 90
		fmt.sbprintf(&b, `,"width":760,"height":%d,"reroute_audio":false`, h)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// Settings a freshly-created text source starts with, so it's legible
// over gameplay the moment it appears instead of being 12 px black text
// on a dark scene.
//
// The two text plugins don't share a settings schema: text_gdiplus takes
// a font object plus `outline`, text_ft2_source takes `font` with
// `face`/`size` and has no outline of its own (users add a filter). Send
// each what it understands — OBS ignores unknown keys, but sending the
// wrong font shape means no font is applied at all.
@(private = "file")
obsws_default_text_settings :: proc(kind: string) -> string {
	COLOUR :: 4294967295 // 0xFFFFFFFF — white, ABGR with full alpha

	if strings.has_prefix(kind, "text_gdiplus") {
		return fmt.tprintf(
			`{{"text":"","color":%d,"outline":true,"outline_color":4278190080,` +
			`"outline_size":2,"font":{{"face":"Arial","size":36,"style":"Bold","flags":0}}}}`,
			COLOUR,
		)
	}

	// text_ft2_source_v2 (Linux, and Windows installs without GDI+).
	return fmt.tprintf(
		`{{"text":"","color1":%d,"color2":%d,"outline":true,` +
		`"font":{{"face":"Sans Serif","size":36,"style":"Bold","flags":0}}}}`,
		COLOUR, COLOUR,
	)
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
	if idx := app_focus_region(app.settings.ws_region); idx >= 0 {
		r := &app.regions[idx]
		r_total, r_killed := count_region_bosses(r)
		region_text = fmt.tprintf("%s (%d/%d)", r.region_name, r_killed, r_total)

		names := make([dynamic]string, context.temp_allocator)
		for &boss in r.bosses {
			if boss.killed do continue
			append(&names, boss.boss)
		}
		region_bosses = obs_join_lines(names[:], app.settings.ws_roomy_lines)
	}

	// Built per kind so the enum stays the single source of truth for
	// what each source shows.
	for kind in Obs_Source {
		if !obs_source_enabled(kind) do continue

		// A browser source updates itself over SSE, so all it needs is its
		// URL kept in step with the overlay settings — mode, region,
		// alignment. Sent as inputSettings like everything else.
		if kind == .Overlay || app.settings.obsws_source_style == "web" {
			url_settings := kind == .Overlay \
				? obsws_browser_settings() \
				: obsws_widget_settings(kind)

			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, `{"inputName":"`)
			json_escape_string(&b, obs_source_name(kind))
			strings.write_string(&b, `","inputSettings":`)
			strings.write_string(&b, url_settings)
			strings.write_string(&b, `,"overlay":true}`)
			obsws_request(conn, "SetInputSettings", strings.to_string(b))
			continue
		}

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
		case .Overlay:       // handled above
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

// ----------------------------------------------------------------------------
// Tiny JSON accessors
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
