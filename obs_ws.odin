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

// Text sources the app creates and keeps updated, in the same order as
// the values built in obsws_push_update:
//
//   ER Progress    "113 / 207 bosses"
//   ER Next Boss   the next boss still standing, with its location
//   ER Deaths      death count
//   ER Character   character name and level
//
// The "ER " prefix keeps them recognisable in OBS's source list and out
// of the way of the user's own names.
OBS_SOURCES :: [?]string{"ER Progress", "ER Next Boss", "ER Deaths", "ER Character"}

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
	scene:     string, // owned; scene new sources get added to
	text_kind: string, // owned; platform's text input kind
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
	case .Connected:    return "Connected to OBS", .Connected
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
}

// Kick off a connection on a worker thread. Called from `update`, which
// must not block.
obsws_connect_command :: proc() -> Obsws_Connect_Params {
	return Obsws_Connect_Params {
		host     = strings.clone(app.settings.obsws_host),
		port     = app.settings.obsws_port,
		password = strings.clone(app.settings.obsws_password),
	}
}

obsws_connect_worker :: proc(p: Obsws_Connect_Params) -> Msg {
	defer delete(p.host)
	defer delete(p.password)

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
	obsws_prepare_sources(conn)

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
obsws_request :: proc(conn: ^ws.Conn, request_type: string, request_data: string) -> bool {
	if conn == nil do return false

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

	return ws.send_text(conn, strings.to_string(b)) == .None
}

// Ask OBS what scene we're on and which text plugin this platform has,
// then create any of our sources that don't exist yet.
@(private = "file")
obsws_prepare_sources :: proc(conn: ^ws.Conn) {
	scene := obsws_current_scene(conn)
	kind := obsws_text_kind(conn)

	sync.mutex_lock(&g_obs.mu)
	if len(g_obs.scene) > 0 do delete(g_obs.scene)
	if len(g_obs.text_kind) > 0 do delete(g_obs.text_kind)
	g_obs.scene = strings.clone(scene)
	g_obs.text_kind = strings.clone(kind)
	sync.mutex_unlock(&g_obs.mu)

	if len(scene) == 0 || len(kind) == 0 do return

	sources := OBS_SOURCES
	for name in sources {
		// CreateInput fails harmlessly when the source already exists,
		// which saves a GetInputList round trip.
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"sceneName":"`)
		json_escape_string(&b, scene)
		strings.write_string(&b, `","inputName":"`)
		json_escape_string(&b, name)
		strings.write_string(&b, `","inputKind":"`)
		json_escape_string(&b, kind)
		strings.write_string(&b, `","inputSettings":{"text":""},"sceneItemEnabled":true}`)
		obsws_request(conn, "CreateInput", strings.to_string(b))
	}
}

// Round-trip helper for the two setup queries. Unlike the fire-and-
// forget path this waits for the reply, which is fine because it only
// runs on the connect worker before the reader thread starts.
@(private = "file")
obsws_request_sync :: proc(
	conn: ^ws.Conn,
	request_type: string,
	allocator := context.temp_allocator,
) -> (
	json.Value,
	bool,
) {
	if !obsws_request(conn, request_type, "") do return nil, false

	// Skip anything that isn't a RequestResponse (op 7).
	for _ in 0 ..< 8 {
		reply, err := ws.receive(conn, allocator)
		if err != .None do return nil, false

		root, parse_err := json.parse(reply.payload, allocator = allocator)
		if parse_err != .None do continue
		if json_int(root, "op") != 7 do continue
		return json_object(root, "d"), true
	}
	return nil, false
}

@(private = "file")
obsws_current_scene :: proc(conn: ^ws.Conn) -> string {
	d, ok := obsws_request_sync(conn, "GetCurrentProgramScene")
	if !ok do return ""
	data := json_object(d, "responseData")
	// obs-websocket 5.5 renamed this; accept either spelling.
	if name := json_string(data, "sceneName"); len(name) > 0 do return name
	return json_string(data, "currentProgramSceneName")
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

	values := [?]string {
		fmt.tprintf("%d / %d bosses", killed, total),
		next_text,
		fmt.tprintf("%d", app.death_count),
		character,
	}

	sources := OBS_SOURCES
	#assert(len(OBS_SOURCES) == len(values))

	for name, i in sources {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"inputName":"`)
		json_escape_string(&b, name)
		strings.write_string(&b, `","inputSettings":{"text":"`)
		json_escape_string(&b, values[i])
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
