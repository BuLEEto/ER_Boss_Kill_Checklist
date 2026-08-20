package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "src/libs/http"

// ============================================================================
// Web server
//
// Since the desktop GUI took over configuration, this exists for exactly
// two audiences:
//
//   /overlay  the OBS browser source
//   /mobile   the phone companion page
//
// plus /events (SSE) and /api/status that those two poll. The old config
// page, file browser and save-scan endpoints are gone — they were only
// ever there because there was no native UI to put them in.
//
// The server runs on its own thread so Skald keeps the main one. Handlers
// are readers of `app` and take a shared lock; see app_state.odin for the
// full threading contract.
// ============================================================================

Server_Handle :: struct {
	server:   ^http.Server,
	thread:   ^thread.Thread,
	port:     int,
	running:  bool, // atomic
	stopping: bool, // atomic; tells SSE loops to let go

	// Set by the listener thread when bind/accept fails. A bool, not a
	// message, because the GUI thread reads this every frame and a string
	// written by one thread and read by another is a race.
	listen_failed: bool, // atomic

	// Only ever written by the GUI thread, during server_start.
	error: string,
}

// ----------------------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------------------

server_start :: proc(h: ^Server_Handle, port: int) -> bool {
	if sync.atomic_load(&h.running) do return true

	server_clear_error(h)

	// pool_size 16: this is thread-per-connection and every SSE client
	// pins a worker for its whole lifetime, so the pool is really "how
	// many overlay/mobile tabs can be open at once".
	srv, err := http.server_create(port = port, pool_size = 16)
	if err != nil {
		h.error = fmt.aprintf("Could not create server on port %d: %v", port, err)
		return false
	}

	router := http.router_create()
	http.router_use(router, http.cors_allow_all)
	http.server_static(srv, "static", "/static/")

	http.router_get(router, "/", handle_root)
	http.router_get(router, "/overlay", handle_overlay)
	http.router_get(router, "/mobile", handle_mobile)
	http.router_get(router, "/events", handle_sse)
	http.router_get(router, "/api/status", handle_api_status)
	srv.router = router

	h.server = srv
	h.port = port
	sync.atomic_store(&h.stopping, false)
	sync.atomic_store(&h.listen_failed, false)
	sync.atomic_store(&h.running, true)

	h.thread = thread.create_and_start_with_data(h, server_thread_proc)
	if h.thread == nil {
		sync.atomic_store(&h.running, false)
		http.server_destroy(srv)
		h.server = nil
		h.error = strings.clone("Could not start server thread")
		return false
	}
	return true
}

server_thread_proc :: proc(data: rawptr) {
	h := cast(^Server_Handle)data
	// Blocks in the accept loop until server_shutdown breaks it.
	if err := http.server_listen_and_serve(h.server); err != nil {
		sync.atomic_store(&h.listen_failed, true)
	}
	sync.atomic_store(&h.running, false)
}

server_stop :: proc(h: ^Server_Handle) {
	if h.server == nil do return

	// Let the SSE keep-alive loops fall out of their sleep before we ask
	// the pool to join, otherwise shutdown waits on them.
	sync.atomic_store(&h.stopping, true)

	// Drop every SSE client so no worker is parked on one.
	sync.mutex_lock(&app.sse_mutex)
	clear(&app.sse_clients)
	sync.mutex_unlock(&app.sse_mutex)

	// Order matters: break the accept loop, wait for our listener thread
	// to leave server_listen_and_serve, and only then free the server it
	// was reading from. Destroying first would pull the struct out from
	// under a thread still inside it.
	http.server_shutdown(h.server)
	if h.thread != nil {
		thread.destroy(h.thread) // joins
		h.thread = nil
	}
	http.server_destroy(h.server)
	h.server = nil

	sync.atomic_store(&h.running, false)
	sync.atomic_store(&h.listen_failed, false)
}

// Whatever the GUI should show about the server's health, or "" when
// there's nothing wrong.
server_error_text :: proc(h: ^Server_Handle) -> string {
	if sync.atomic_load(&h.listen_failed) {
		return fmt.tprintf("Port %d is not available — try another one", h.port)
	}
	return h.error
}

server_is_running :: proc(h: ^Server_Handle) -> bool {
	return sync.atomic_load(&h.running)
}

server_clear_error :: proc(h: ^Server_Handle) {
	if len(h.error) > 0 {
		delete(h.error)
		h.error = ""
	}
}

// ----------------------------------------------------------------------------
// Handlers
// ----------------------------------------------------------------------------

// Nothing lives at the root any more — the config UI it used to serve is
// the desktop window. Send visitors to the page they almost certainly
// wanted.
handle_root :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_redirect(res, "/mobile")
}

Overlay_Boss_View :: struct {
	boss:        string,
	place:       string,
	region_name: string,
}

Overlay_Region_Summary :: struct {
	region_name:   string,
	region_killed: int,
	region_total:  int,
	has_remaining: bool,
	is_complete:   bool,
}

handle_overlay :: proc(req: ^http.Request, res: ^http.Response) {
	tpl := app.tpl_overlay
	if tpl == nil {
		http.response_status(res, .Internal_Error)
		http.response_text(res, "Overlay template not loaded")
		return
	}

	// Query params: mode=summary|region|next, deaths=true, region=N, count=N
	mode_param, _ := http.request_query(req, "mode")
	deaths_param, _ := http.request_query(req, "deaths")
	region_param, _ := http.request_query(req, "region")
	count_param, _ := http.request_query(req, "count")

	sync.shared_guard(&app.mu)

	mode := len(mode_param) > 0 ? mode_param : app.settings.overlay_mode
	show_deaths := app.settings.show_deaths || deaths_param == "true"

	focus_region := parse_int_default(region_param, -1)
	next_count := parse_int_default(count_param, app.settings.overlay_next_count)
	if next_count < 1 do next_count = 8

	total, killed := count_bosses(app.regions)
	slot_name, slot_level := app_active_character()

	region_summaries := make([]Overlay_Region_Summary, len(app.regions), context.temp_allocator)
	for &r, i in app.regions {
		rt, rk := count_region_bosses(&r)
		region_summaries[i] = Overlay_Region_Summary {
			region_name   = r.region_name,
			region_killed = rk,
			region_total  = rt,
			has_remaining = rk < rt,
			is_complete   = rk == rt,
		}
	}

	// No region in the URL: fall back to whatever the app is pinned to,
	// so a copied overlay URL and the OBS sources agree.
	if mode == "region" && focus_region < 0 {
		focus_region = app_focus_region()
		if focus_region < 0 do focus_region = 0
	}

	bosses := make([dynamic]Overlay_Boss_View, context.temp_allocator)
	if mode == "region" && focus_region >= 0 && focus_region < len(app.regions) {
		r := &app.regions[focus_region]
		for &b in r.bosses {
			if b.killed do continue
			append(&bosses, Overlay_Boss_View{
				boss = b.boss, place = b.place, region_name = r.region_name,
			})
		}
	} else if mode == "next" {
		for ref in app_next_bosses(next_count, context.temp_allocator) {
			append(&bosses, Overlay_Boss_View{
				boss = ref.boss, place = ref.place, region_name = ref.region_name,
			})
		}
	}

	focus_region_name := ""
	if mode == "region" && focus_region >= 0 && focus_region < len(app.regions) {
		rt, rk := count_region_bosses(&app.regions[focus_region])
		focus_region_name = fmt.tprintf(
			"%s (%d/%d)", app.regions[focus_region].region_name, rk, rt,
		)
	}

	data := struct {
		save_loaded:       bool,
		slot_name:         string,
		slot_level:        u32,
		total_bosses:      int,
		killed_count:      int,
		remaining:         int,
		death_count:       u32,
		show_deaths:       bool,
		is_summary:        bool,
		is_region:         bool,
		is_next:           bool,
		regions:           []Overlay_Region_Summary,
		bosses:            []Overlay_Boss_View,
		focus_region_name: string,
	}{
		save_loaded       = app.save_loaded,
		slot_name         = slot_name,
		slot_level        = slot_level,
		total_bosses      = total,
		killed_count      = killed,
		remaining         = total - killed,
		death_count       = app.death_count,
		show_deaths       = show_deaths,
		is_summary        = mode == "summary",
		is_region         = mode == "region",
		is_next           = mode == "next",
		regions           = region_summaries,
		bosses            = bosses[:],
		focus_region_name = focus_region_name,
	}

	http.template_respond_with(res, tpl, data)
}

Mobile_Boss :: struct {
	boss:   string,
	place:  string,
	killed: bool,
}

Mobile_Region :: struct {
	region_name:   string,
	region_killed: int,
	region_total:  int,
	is_complete:   bool,
	bosses:        []Mobile_Boss,
}

handle_mobile :: proc(req: ^http.Request, res: ^http.Response) {
	tpl := app.tpl_mobile
	if tpl == nil {
		http.response_status(res, .Internal_Error)
		http.response_text(res, "Mobile template not loaded")
		return
	}

	sync.shared_guard(&app.mu)

	total, killed := count_bosses(app.regions)
	slot_name, slot_level := app_active_character()

	regions := make([]Mobile_Region, len(app.regions), context.temp_allocator)
	for &r, i in app.regions {
		rt, rk := count_region_bosses(&r)
		bosses := make([]Mobile_Boss, len(r.bosses), context.temp_allocator)
		for &b, j in r.bosses {
			bosses[j] = Mobile_Boss{boss = b.boss, place = b.place, killed = b.killed}
		}
		regions[i] = Mobile_Region {
			region_name   = r.region_name,
			region_killed = rk,
			region_total  = rt,
			is_complete   = rk == rt,
			bosses        = bosses,
		}
	}

	data := struct {
		save_loaded:  bool,
		slot_name:    string,
		slot_level:   u32,
		total_bosses: int,
		killed_count: int,
		remaining:    int,
		death_count:  u32,
		show_deaths:  bool,
		regions:      []Mobile_Region,
	}{
		save_loaded  = app.save_loaded,
		slot_name    = slot_name,
		slot_level   = slot_level,
		total_bosses = total,
		killed_count = killed,
		remaining    = total - killed,
		death_count  = app.death_count,
		show_deaths  = app.settings.show_deaths,
		regions      = regions,
	}

	http.template_respond_with(res, tpl, data)
}

// Long-lived connection: the worker thread stays here until the client
// goes away or the server shuts down.
handle_sse :: proc(req: ^http.Request, res: ^http.Response) {
	if !http.sse_start(res) do return

	sync.mutex_lock(&app.sse_mutex)
	append(&app.sse_clients, res)
	sync.mutex_unlock(&app.sse_mutex)

	// Ping every 15s to keep proxies and OBS's embedded browser happy,
	// but wake once a second so a shutdown doesn't wait out the sleep.
	ping_countdown := 15
	for !sync.atomic_load(&app.server.stopping) {
		time.sleep(time.Second)
		ping_countdown -= 1
		if ping_countdown > 0 do continue
		ping_countdown = 15
		if !http.sse_comment(res, "ping") do break
	}

	sync.mutex_lock(&app.sse_mutex)
	for i := 0; i < len(app.sse_clients); i += 1 {
		if app.sse_clients[i] == res {
			ordered_remove(&app.sse_clients, i)
			break
		}
	}
	sync.mutex_unlock(&app.sse_mutex)
}

Status_Entry :: struct {
	flag_id: u32,
	killed:  bool,
}

handle_api_status :: proc(req: ^http.Request, res: ^http.Response) {
	sync.shared_guard(&app.mu)

	total, killed := count_bosses(app.regions)

	entries := make([dynamic]Status_Entry, context.temp_allocator)
	for &r in app.regions {
		for &b in r.bosses {
			append(&entries, Status_Entry{flag_id = b.flag_id, killed = b.killed})
		}
	}

	slot_name, slot_level := app_active_character()

	http.response_json(res, struct {
		total:       int,
		killed:      int,
		death_count: u32,
		slot_name:   string,
		slot_level:  u32,
		bosses:      []Status_Entry,
	}{
		total       = total,
		killed      = killed,
		death_count = app.death_count,
		slot_name   = slot_name,
		slot_level  = slot_level,
		bosses      = entries[:],
	})
}

// ----------------------------------------------------------------------------
// Broadcast
// ----------------------------------------------------------------------------

// Tell every connected overlay / mobile page that something changed.
// Called from the GUI thread after a poll produces new numbers.
sse_broadcast_update :: proc(killed, total: int, deaths: u32) {
	payload := fmt.tprintf(
		`{{"killed_count":%d,"total":%d,"death_count":%d}}`,
		killed, total, deaths,
	)

	sync.mutex_lock(&app.sse_mutex)
	defer sync.mutex_unlock(&app.sse_mutex)

	for i := len(app.sse_clients) - 1; i >= 0; i -= 1 {
		if !http.sse_event(app.sse_clients[i], payload, event = "boss_update") {
			ordered_remove(&app.sse_clients, i)
		}
	}
}

// ----------------------------------------------------------------------------

parse_int_default :: proc(s: string, fallback: int) -> int {
	if len(s) == 0 do return fallback
	if v, ok := strconv.parse_int(s); ok do return v
	return fallback
}
