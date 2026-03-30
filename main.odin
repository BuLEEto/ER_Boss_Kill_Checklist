package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "src/libs/http"


// ============================================================================
// Application State
// ============================================================================

SETTINGS_FILE :: "settings.json"

App_State :: struct {
	// Configuration
	save_path:      string,
	active_slot:    int,
	boss_list_type: Boss_List_Type,
	show_deaths:    bool,
	poll_seconds:   int,

	// Data
	regions:     []Region,
	bst_map:     BST_Map,
	save_file:   Save_File,
	slots:       []Character_Slot,
	death_count: u32,
	save_loaded: bool,

	// SSE
	sse_clients: [dynamic]^http.Response,
	sse_mutex:   sync.Mutex,

	// Network
	lan_ip: string,

	// Templates (cached at startup)
	tpl_index:   ^http.Template,
	tpl_overlay: ^http.Template,
	tpl_mobile:  ^http.Template,

	// Polling
	poll_interval: time.Duration,
}

// Settings file JSON structure
Settings :: struct {
	save_path:    string `json:"save_path"`,
	active_slot:  int    `json:"active_slot"`,
	boss_list:    string `json:"boss_list"`,
	show_deaths:  bool   `json:"show_deaths"`,
	poll_seconds: int    `json:"poll_seconds"`,
}

app: App_State

// ============================================================================
// Settings Load / Save
// ============================================================================

load_settings :: proc() {
	raw, read_err := os.read_entire_file(SETTINGS_FILE, context.temp_allocator)
	if read_err != nil do return

	settings: Settings
	err := json.unmarshal(raw, &settings, allocator = context.temp_allocator)
	if err != nil do return

	if len(settings.save_path) > 0 {
		app.save_path = strings.clone(settings.save_path)
	}
	app.active_slot = settings.active_slot
	app.show_deaths = settings.show_deaths

	if settings.poll_seconds > 0 {
		app.poll_seconds = settings.poll_seconds
		app.poll_interval = time.Duration(settings.poll_seconds) * time.Second
	}

	if settings.boss_list == "hardlock" {
		app.boss_list_type = .Hardlock
		new_regions, ok := load_boss_data(.Hardlock)
		if ok do app.regions = new_regions
	} else if settings.boss_list == "remembrance" {
		app.boss_list_type = .Remembrance
		new_regions, ok := load_boss_data(.Remembrance)
		if ok do app.regions = new_regions
	} else if settings.boss_list == "remembrance_dlc" {
		app.boss_list_type = .Remembrance_DLC
		new_regions, ok := load_boss_data(.Remembrance_DLC)
		if ok do app.regions = new_regions
	} else if settings.boss_list == "great_runes" {
		app.boss_list_type = .Great_Runes
		new_regions, ok := load_boss_data(.Great_Runes)
		if ok do app.regions = new_regions
	} else if settings.boss_list == "main_story" {
		app.boss_list_type = .Main_Story
		new_regions, ok := load_boss_data(.Main_Story)
		if ok do app.regions = new_regions
	} else if settings.boss_list == "dlc_only" {
		app.boss_list_type = .DLC_Only
		new_regions, ok := load_boss_data(.DLC_Only)
		if ok do app.regions = new_regions
	}

	if len(app.save_path) > 0 {
		reload_save()
	}

	fmt.println("Settings loaded from", SETTINGS_FILE)
}

save_settings :: proc() {
	boss_list: string
	switch app.boss_list_type {
	case .Hardlock:        boss_list = "hardlock"
	case .Remembrance:     boss_list = "remembrance"
	case .Remembrance_DLC: boss_list = "remembrance_dlc"
	case .Great_Runes:     boss_list = "great_runes"
	case .Main_Story:      boss_list = "main_story"
	case .DLC_Only:        boss_list = "dlc_only"
	case .Standard:        boss_list = "standard"
	}

	settings := Settings {
		save_path    = app.save_path,
		active_slot  = app.active_slot,
		boss_list    = boss_list,
		show_deaths  = app.show_deaths,
		poll_seconds = app.poll_seconds,
	}

	data, err := json.marshal(settings, allocator = context.temp_allocator)
	if err != nil do return

	_ = os.write_entire_file(SETTINGS_FILE, data)
}

// ============================================================================
// Main
// ============================================================================

main :: proc() {
	// Change to the directory containing the executable so relative paths work
	change_to_exe_dir()

	// Load BST map
	bst, bst_ok := load_bst_map("eventflag_bst.txt")
	if !bst_ok {
		fmt.eprintln("Failed to load eventflag_bst.txt")
		return
	}
	app.bst_map = bst

	// Load default boss list
	regions, boss_ok := load_boss_data(.Standard)
	if !boss_ok {
		fmt.eprintln("Failed to load boss data")
		return
	}
	app.regions = regions
	app.active_slot = -1
	app.poll_seconds = 3
	app.poll_interval = 3 * time.Second
	app.show_deaths = false

	// Load saved settings (overrides defaults)
	load_settings()

	// Pre-load templates (avoids reading from disk on every request)
	tpl_idx, tpl_idx_err := http.template_load("templates/index.html")
	if tpl_idx_err != .None {
		fmt.eprintln("Failed to load templates/index.html:", tpl_idx_err)
		return
	}
	app.tpl_index = tpl_idx

	tpl_ovl, tpl_ovl_err := http.template_load("templates/overlay.html")
	if tpl_ovl_err != .None {
		fmt.eprintln("Failed to load templates/overlay.html:", tpl_ovl_err)
		return
	}
	app.tpl_overlay = tpl_ovl

	tpl_mob, tpl_mob_err := http.template_load("templates/mobile.html")
	if tpl_mob_err != .None {
		fmt.eprintln("Failed to load templates/mobile.html:", tpl_mob_err)
		return
	}
	app.tpl_mobile = tpl_mob

	// Create server
	// Pool size 16 to handle multiple SSE connections (each blocks a worker thread)
	server, _ := http.server_create(port = 3000, pool_size = 16)
	defer http.server_destroy(server)

	router := http.router_create()
	http.router_use(router, http.cors_allow_all)

	// Static files
	http.server_static(server, "static", "/static/")

	// Routes
	http.router_get(router, "/", handle_index)
	http.router_post(router, "/config", handle_config)
	http.router_get(router, "/overlay", handle_overlay)
	http.router_get(router, "/events", handle_sse)
	http.router_get(router, "/api/status", handle_api_status)
	http.router_get(router, "/api/slots", handle_api_slots)
	http.router_post(router, "/toggle-deaths", handle_toggle_deaths)
	http.router_get(router, "/api/browse", handle_api_browse)
	http.router_get(router, "/api/scan-saves", handle_api_scan_saves)
	http.router_get(router, "/mobile", handle_mobile)

	server.router = router

	// Detect LAN IP for mobile access
	app.lan_ip = detect_lan_ip()

	// Start polling thread
	thread.create_and_start_with_data(&app, poll_save_file)

	fmt.println("===========================================")
	fmt.println("  Elden Ring Boss Checklist")
	fmt.println("  http://localhost:3000")
	fmt.println("  OBS Overlay: http://localhost:3000/overlay")
	if len(app.lan_ip) > 0 {
		fmt.printfln("  Mobile View: http://%s:3000/mobile", app.lan_ip)
	} else {
		fmt.println("  Mobile View: http://localhost:3000/mobile")
	}
	fmt.println("===========================================")

	http.server_listen_and_serve(server)
}

// detect_lan_ip is defined in platform_linux.odin / platform_windows.odin

// ============================================================================
// Route Handlers
// ============================================================================

handle_index :: proc(req: ^http.Request, res: ^http.Response) {
	tpl := app.tpl_index
	if tpl == nil {
		http.response_status(res, .Internal_Error)
		http.response_text(res, "Template not loaded")
		return
	}

	total, killed := count_bosses(app.regions)

	slot_name := ""
	slot_level: u32 = 0
	if app.save_loaded && app.active_slot >= 0 && app.active_slot < len(app.slots) {
		s := app.slots[app.active_slot]
		slot_name = s.name
		slot_level = s.level
	}

	// Build region view data
	Region_View :: struct {
		region_name:   string,
		bosses:        []Boss_View,
		region_killed: int,
		region_total:  int,
	}
	Boss_View :: struct {
		boss:       string,
		place:      string,
		flag_id:    u32,
		difficulty: int,
		killed:     bool,
	}

	region_views := make([]Region_View, len(app.regions), context.temp_allocator)
	for &r, i in app.regions {
		rt, rk := count_region_bosses(&r)
		bv := make([]Boss_View, len(r.bosses), context.temp_allocator)
		for &b, j in r.bosses {
			bv[j] = Boss_View {
				boss       = b.boss,
				place      = b.place,
				flag_id    = b.flag_id,
				difficulty = b.difficulty,
				killed     = b.killed,
			}
		}
		region_views[i] = Region_View {
			region_name   = r.region_name,
			bosses        = bv,
			region_killed = rk,
			region_total  = rt,
		}
	}

	data := struct {
		save_loaded:       bool,
		save_path:         string,
		slot_name:         string,
		slot_level:        u32,
		active_slot:       int,
		total_bosses:      int,
		killed_count:      int,
		death_count:       u32,
		show_deaths:       bool,
		is_standard:       bool,
		is_hardlock:       bool,
		is_remembrance:    bool,
		is_remembrance_dlc: bool,
		is_great_runes:    bool,
		is_main_story:     bool,
		is_dlc_only:       bool,
		poll_seconds:      int,
		lan_ip:            string,
		regions:           []Region_View,
	}{
		save_loaded       = app.save_loaded,
		save_path         = app.save_path,
		slot_name         = slot_name,
		slot_level        = slot_level,
		active_slot       = app.active_slot,
		total_bosses      = total,
		killed_count      = killed,
		death_count       = app.death_count,
		show_deaths       = app.show_deaths,
		lan_ip            = app.lan_ip,
		is_standard       = app.boss_list_type == .Standard,
		is_hardlock       = app.boss_list_type == .Hardlock,
		is_remembrance    = app.boss_list_type == .Remembrance,
		is_remembrance_dlc = app.boss_list_type == .Remembrance_DLC,
		is_great_runes    = app.boss_list_type == .Great_Runes,
		is_main_story     = app.boss_list_type == .Main_Story,
		is_dlc_only       = app.boss_list_type == .DLC_Only,
		poll_seconds      = app.poll_seconds,
		regions           = region_views,
	}

	http.template_respond_with(res, tpl, data)
}

handle_config :: proc(req: ^http.Request, res: ^http.Response) {
	save_path, _ := http.request_form(req, "save_path")
	slot_str, _ := http.request_form(req, "slot")
	boss_list, _ := http.request_form(req, "boss_list")
	poll_str, _ := http.request_form(req, "poll_rate")

	// Update boss list type
	new_type: Boss_List_Type
	switch boss_list {
	case "hardlock":        new_type = .Hardlock
	case "remembrance":     new_type = .Remembrance
	case "remembrance_dlc": new_type = .Remembrance_DLC
	case "great_runes":     new_type = .Great_Runes
	case "main_story":      new_type = .Main_Story
	case "dlc_only":        new_type = .DLC_Only
	case:                   new_type = .Standard
	}
	if new_type != app.boss_list_type {
		app.boss_list_type = new_type
		new_regions, ok := load_boss_data(new_type)
		if ok do app.regions = new_regions
	}

	// Update save path (clone since request data is temporary)
	if len(save_path) > 0 {
		if len(app.save_path) > 0 {
			delete(app.save_path)
		}
		app.save_path = strings.clone(save_path)
	}

	// Update slot
	slot_val := 0
	for c in slot_str {
		if c >= '0' && c <= '9' {
			slot_val = slot_val * 10 + int(c - '0')
		}
	}
	app.active_slot = slot_val

	// Update poll rate
	poll_val := 0
	for c in poll_str {
		if c >= '0' && c <= '9' {
			poll_val = poll_val * 10 + int(c - '0')
		}
	}
	if poll_val >= 1 && poll_val <= 60 {
		app.poll_seconds = poll_val
		app.poll_interval = time.Duration(poll_val) * time.Second
	}

	// Reload save
	reload_save()

	// Save settings to file
	save_settings()

	http.response_redirect(res, "/")
}

handle_toggle_deaths :: proc(req: ^http.Request, res: ^http.Response) {
	app.show_deaths = !app.show_deaths
	save_settings()
	http.response_redirect(res, "/")
}

handle_overlay :: proc(req: ^http.Request, res: ^http.Response) {
	// Query params: mode=summary|region|next, deaths=true, region=N, count=N
	mode_param, _ := http.request_query(req, "mode")
	show_deaths_param, _ := http.request_query(req, "deaths")
	region_param, _ := http.request_query(req, "region")
	count_param, _ := http.request_query(req, "count")

	show_deaths := app.show_deaths || show_deaths_param == "true"

	// Parse region index for region mode
	focus_region := -1
	for c in region_param {
		if c >= '0' && c <= '9' {
			focus_region = (focus_region < 0 ? 0 : focus_region) * 10 + int(c - '0')
		}
	}

	// Parse count for next mode (default 8)
	next_count := 8
	parsed_count := 0
	for c in count_param {
		if c >= '0' && c <= '9' {
			parsed_count = parsed_count * 10 + int(c - '0')
		}
	}
	if parsed_count > 0 do next_count = parsed_count

	// Determine mode
	mode := mode_param if len(mode_param) > 0 else "summary"

	total, killed := count_bosses(app.regions)

	slot_name := ""
	slot_level: u32 = 0
	if app.save_loaded && app.active_slot >= 0 && app.active_slot < len(app.slots) {
		slot_name = app.slots[app.active_slot].name
		slot_level = app.slots[app.active_slot].level
	}

	// Build region summary data
	Region_Summary :: struct {
		region_name:   string,
		region_killed: int,
		region_total:  int,
		has_remaining: bool,
		is_complete:   bool,
	}

	Boss_View :: struct {
		boss:        string,
		place:       string,
		region_name: string,
		killed:      bool,
	}

	region_summaries := make([]Region_Summary, len(app.regions), context.temp_allocator)
	for &r, i in app.regions {
		rt, rk := count_region_bosses(&r)
		region_summaries[i] = Region_Summary {
			region_name   = r.region_name,
			region_killed = rk,
			region_total  = rt,
			has_remaining = rk < rt,
			is_complete   = rk == rt,
		}
	}

	// For region mode, default to first incomplete region
	if mode == "region" && focus_region < 0 {
		for &r, i in app.regions {
			rt, rk := count_region_bosses(&r)
			if rk < rt {
				focus_region = i
				break
			}
		}
		if focus_region < 0 do focus_region = 0
	}

	// Build boss list for region/next modes
	next_bosses := make([dynamic]Boss_View, context.temp_allocator)

	if mode == "region" && focus_region >= 0 && focus_region < len(app.regions) {
		r := &app.regions[focus_region]
		for &b in r.bosses {
			if !b.killed {
				append(&next_bosses, Boss_View{
					boss        = b.boss,
					place       = b.place,
					region_name = r.region_name,
					killed      = false,
				})
			}
		}
	} else if mode == "next" {
		// Collect next N unkilled bosses across all regions
		count := 0
		outer: for &r in app.regions {
			for &b in r.bosses {
				if !b.killed {
					append(&next_bosses, Boss_View{
						boss        = b.boss,
						place       = b.place,
						region_name = r.region_name,
						killed      = false,
					})
					count += 1
					if count >= next_count do break outer
				}
			}
		}
	}

	// Focus region name for title
	focus_region_name := ""
	if mode == "region" && focus_region >= 0 && focus_region < len(app.regions) {
		rt, rk := count_region_bosses(&app.regions[focus_region])
		focus_region_name = fmt.tprintf("%s (%d/%d)", app.regions[focus_region].region_name, rk, rt)
	}

	tpl := app.tpl_overlay
	if tpl == nil {
		http.response_status(res, .Internal_Error)
		http.response_text(res, "Overlay template not loaded")
		return
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
		regions:           []Region_Summary,
		bosses:            []Boss_View,
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
		bosses            = next_bosses[:],
		focus_region_name = focus_region_name,
	}

	http.template_respond_with(res, tpl, data)
}

handle_mobile :: proc(req: ^http.Request, res: ^http.Response) {
	tpl := app.tpl_mobile
	if tpl == nil {
		http.response_status(res, .Internal_Error)
		http.response_text(res, "Mobile template not loaded")
		return
	}

	total, killed := count_bosses(app.regions)

	slot_name := ""
	slot_level: u32 = 0
	if app.save_loaded && app.active_slot >= 0 && app.active_slot < len(app.slots) {
		slot_name = app.slots[app.active_slot].name
		slot_level = app.slots[app.active_slot].level
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

	regions := make([]Mobile_Region, len(app.regions), context.temp_allocator)
	for &r, i in app.regions {
		rt, rk := count_region_bosses(&r)
		boss_views := make([]Mobile_Boss, len(r.bosses), context.temp_allocator)
		for &b, j in r.bosses {
			boss_views[j] = Mobile_Boss{
				boss   = b.boss,
				place  = b.place,
				killed = b.killed,
			}
		}
		regions[i] = Mobile_Region{
			region_name   = r.region_name,
			region_killed = rk,
			region_total  = rt,
			is_complete   = rk == rt,
			bosses        = boss_views,
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
		show_deaths  = app.show_deaths,
		regions      = regions,
	}

	http.template_respond_with(res, tpl, data)
}

handle_sse :: proc(req: ^http.Request, res: ^http.Response) {
	if !http.sse_start(res) do return

	sync.mutex_lock(&app.sse_mutex)
	append(&app.sse_clients, res)
	sync.mutex_unlock(&app.sse_mutex)

	// Keep connection alive until client disconnects
	for {
		time.sleep(15 * time.Second)
		if !http.sse_comment(res, "ping") {
			break
		}
	}

	// Remove from client list
	sync.mutex_lock(&app.sse_mutex)
	for i := 0; i < len(app.sse_clients); i += 1 {
		if app.sse_clients[i] == res {
			ordered_remove(&app.sse_clients, i)
			break
		}
	}
	sync.mutex_unlock(&app.sse_mutex)
}

handle_api_status :: proc(req: ^http.Request, res: ^http.Response) {
	total, killed := count_bosses(app.regions)

	Status_Entry :: struct {
		flag_id: u32,
		killed:  bool,
	}

	entries := make([dynamic]Status_Entry, context.temp_allocator)
	for &r in app.regions {
		for &b in r.bosses {
			append(&entries, Status_Entry{flag_id = b.flag_id, killed = b.killed})
		}
	}

	data := struct {
		total:       int,
		killed:      int,
		death_count: u32,
		bosses:      []Status_Entry,
	}{
		total       = total,
		killed      = killed,
		death_count = app.death_count,
		bosses      = entries[:],
	}

	http.response_json(res, data)
}

handle_api_slots :: proc(req: ^http.Request, res: ^http.Response) {
	path, _ := http.request_query(req, "path")
	if len(path) == 0 {
		http.response_status(res, .Bad_Request)
		http.response_json_string(res, `{"error":"path parameter required"}`)
		return
	}

	save, ok := open_save_file(path, context.temp_allocator)
	if !ok {
		http.response_status(res, .Bad_Request)
		http.response_json_string(res, `{"error":"failed to open save file"}`)
		return
	}

	slots := get_character_slots(&save, context.temp_allocator)
	if slots == nil {
		http.response_json_string(res, `{"slots":[]}`)
		return
	}

	Slot_Info :: struct {
		index:  int,
		name:   string,
		level:  u32,
		active: bool,
	}

	infos := make([dynamic]Slot_Info, context.temp_allocator)
	for &s in slots {
		if s.active {
			append(&infos, Slot_Info{index = s.index, name = s.name, level = s.level, active = true})
		}
	}

	http.response_json(res, struct{ slots: []Slot_Info }{slots = infos[:]})
}

// ============================================================================
// File Browser API
// ============================================================================

handle_api_browse :: proc(req: ^http.Request, res: ^http.Response) {
	dir_path, _ := http.request_query(req, "path")

	// Default to appropriate root
	if len(dir_path) == 0 {
		when ODIN_OS == .Windows {
			dir_path = "C:\\"
		} else {
			cwd, cwd_err := os.get_working_directory(context.temp_allocator)
			dir_path = cwd_err == nil ? cwd : "/"
		}
	}

	// Open and read directory
	dir_handle, open_err := os.open(dir_path)
	if open_err != nil {
		http.response_status(res, .Bad_Request)
		http.response_json_string(res, `{"error":"cannot open directory"}`)
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_all_directory(dir_handle, context.temp_allocator)
	if read_err != nil {
		http.response_status(res, .Bad_Request)
		http.response_json_string(res, `{"error":"cannot read directory"}`)
		return
	}
	defer os.file_info_slice_delete(file_infos, context.temp_allocator)

	Dir_Entry :: struct {
		name:  string,
		is_dir: bool,
		is_save: bool,
	}

	entries := make([dynamic]Dir_Entry, context.temp_allocator)

	// Add parent directory entry
	append(&entries, Dir_Entry{name = "..", is_dir = true, is_save = false})

	for fi in file_infos {
		is_dir := fi.type == .Directory

		// Resolve symlinks — check if target is a directory
		when ODIN_OS != .Windows {
			if fi.type == .Symlink {
				SEP :: "/" when ODIN_OS != .Windows else "\\"
				link_path := strings.concatenate({dir_path, SEP, fi.name}, context.temp_allocator)
				target_info, stat_err := os.stat(link_path, context.temp_allocator)
				if stat_err == nil {
					is_dir = target_info.type == .Directory
				}
			}

			// Skip hidden files but allow hidden directories (e.g. .steam)
			if len(fi.name) > 0 && fi.name[0] == '.' && !is_dir do continue
		}

		is_save := false
		if !is_dir {
			is_save = strings.has_suffix(fi.name, ".sl2") ||
			          strings.has_suffix(fi.name, ".co2") ||
			          strings.has_suffix(fi.name, ".rd2")
		}

		if is_dir || is_save {
			append(&entries, Dir_Entry{
				name    = fi.name,
				is_dir  = is_dir,
				is_save = is_save,
			})
		}
	}

	// Get absolute path for display
	abs_path, abs_err := os.get_absolute_path(dir_path, context.temp_allocator)
	display_path := abs_err == nil ? abs_path : dir_path

	// Build JSON manually to ensure proper escaping
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"path":"`)
	json_escape_string(&builder, display_path)
	strings.write_string(&builder, `","sep":"`)
	when ODIN_OS == .Windows {
		strings.write_string(&builder, `\\`)
	} else {
		strings.write_string(&builder, `/`)
	}
	strings.write_string(&builder, `","entries":[`)
	for entry, i in entries[:] {
		if i > 0 do strings.write_string(&builder, ",")
		strings.write_string(&builder, `{"name":"`)
		json_escape_string(&builder, entry.name)
		strings.write_string(&builder, `","is_dir":`)
		strings.write_string(&builder, entry.is_dir ? "true" : "false")
		strings.write_string(&builder, `,"is_save":`)
		strings.write_string(&builder, entry.is_save ? "true" : "false")
		strings.write_string(&builder, "}")
	}
	strings.write_string(&builder, "]}")

	http.response_json_string(res, strings.to_string(builder))
}

// Escape a string for JSON output — handles raw bytes safely
json_escape_string :: proc(builder: ^strings.Builder, s: string) {
	for i := 0; i < len(s); {
		b := s[i]
		switch b {
		case '"':  strings.write_string(builder, `\"`)  ; i += 1
		case '\\': strings.write_string(builder, `\\`)  ; i += 1
		case '\n': strings.write_string(builder, `\n`)  ; i += 1
		case '\r': strings.write_string(builder, `\r`)  ; i += 1
		case '\t': strings.write_string(builder, `\t`)  ; i += 1
		case 0x00..=0x1F:
			fmt.sbprintf(builder, "\\u%04x", int(b))
			i += 1
		case 0x20..=0x7E:
			// Normal ASCII
			strings.write_byte(builder, b)
			i += 1
		case:
			// Non-ASCII: check if valid UTF-8 sequence
			width := 1
			if b & 0xE0 == 0xC0 && i + 1 < len(s) && s[i+1] & 0xC0 == 0x80 {
				width = 2
			} else if b & 0xF0 == 0xE0 && i + 2 < len(s) && s[i+1] & 0xC0 == 0x80 && s[i+2] & 0xC0 == 0x80 {
				width = 3
			} else if b & 0xF8 == 0xF0 && i + 3 < len(s) && s[i+1] & 0xC0 == 0x80 && s[i+2] & 0xC0 == 0x80 && s[i+3] & 0xC0 == 0x80 {
				width = 4
			}

			if width > 1 {
				// Valid multi-byte UTF-8 — write as-is
				for j in 0..<width {
					strings.write_byte(builder, s[i + j])
				}
			} else {
				// Invalid byte — escape as \uXXXX
				fmt.sbprintf(builder, "\\u%04x", int(b))
			}
			i += width
		}
	}
}

// ============================================================================
// Save File Scanner
// ============================================================================

handle_api_scan_saves :: proc(req: ^http.Request, res: ^http.Response) {
	Char_Info :: struct {
		name:  string,
		level: u32,
	}

	Save_Found :: struct {
		path:       string,
		filename:   string,
		app_id:     string,
		ext:        string,
		characters: []Char_Info,
	}

	found := make([dynamic]Save_Found, context.temp_allocator)

	// Get EldenRing save directories (platform-specific)
	er_save_dirs := get_er_save_dirs(context.temp_allocator)

	save_exts := [?]string{".sl2", ".co2", ".rd2"}
	SEP :: "/" when ODIN_OS != .Windows else "\\"

	// Search all EldenRing save directories
	for &dir_info in er_save_dirs {
		er_handle, er_err := os.open(dir_info.path)
		if er_err != nil do continue

		er_entries, er_read_err := os.read_all_directory(er_handle, context.temp_allocator)
		os.close(er_handle)
		if er_read_err != nil do continue

		// Each subfolder is a Steam user ID
		for user_entry in er_entries {
			uid_is_dir := user_entry.type == .Directory
			when ODIN_OS != .Windows {
				if user_entry.type == .Symlink {
					link_path := strings.concatenate({dir_info.path, SEP, user_entry.name}, context.temp_allocator)
					target_info, stat_err := os.stat(link_path, context.temp_allocator)
					if stat_err == nil do uid_is_dir = target_info.type == .Directory
				}
			}
			if !uid_is_dir do continue

			user_dir := strings.concatenate({dir_info.path, SEP, user_entry.name}, context.temp_allocator)
			user_handle, user_err := os.open(user_dir)
			if user_err != nil do continue

			user_files, user_read_err := os.read_all_directory(user_handle, context.temp_allocator)
			os.close(user_handle)
			if user_read_err != nil do continue

			for sf in user_files {
				if strings.contains(sf.name, "copy") do continue
				for ext in save_exts {
					if strings.has_suffix(sf.name, ext) {
						full_path := strings.concatenate({user_dir, SEP, sf.name}, context.temp_allocator)

						// Read character info
						chars := make([dynamic]Char_Info, context.temp_allocator)
						save, save_ok := open_save_file(full_path, context.temp_allocator)
						if save_ok {
							slots := get_character_slots(&save, context.temp_allocator)
							for s in slots {
								if s.active {
									append(&chars, Char_Info{name = s.name, level = s.level})
								}
							}
						}

						append(&found, Save_Found{
							path       = full_path,
							filename   = sf.name,
							app_id     = dir_info.app_id,
							ext        = ext,
							characters = chars[:],
						})
					}
				}
			}
		}
	}

	// Build JSON response
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"saves":[`)
	for entry, i in found[:] {
		if i > 0 do strings.write_string(&builder, ",")
		strings.write_string(&builder, `{"path":"`)
		json_escape_string(&builder, entry.path)
		strings.write_string(&builder, `","filename":"`)
		json_escape_string(&builder, entry.filename)
		strings.write_string(&builder, `","app_id":"`)
		json_escape_string(&builder, entry.app_id)
		strings.write_string(&builder, `","ext":"`)
		json_escape_string(&builder, entry.ext)
		strings.write_string(&builder, `","characters":[`)
		for c, ci in entry.characters {
			if ci > 0 do strings.write_string(&builder, ",")
			strings.write_string(&builder, `{"name":"`)
			json_escape_string(&builder, c.name)
			strings.write_string(&builder, `","level":`)
			fmt.sbprintf(&builder, "%d", c.level)
			strings.write_string(&builder, "}")
		}
		strings.write_string(&builder, "]}")
	}
	strings.write_string(&builder, "]}")

	http.response_json_string(res, strings.to_string(builder))
}

// ============================================================================
// Platform-specific save file discovery
// ============================================================================

ER_Save_Dir :: struct {
	path:   string,
	app_id: string,
}

// Parse Steam libraryfolders.vdf to find additional library paths
parse_steam_libraries :: proc(vdf_paths: []string, default_roots: []string, allocator := context.allocator) -> []string {
	libs := make([dynamic]string, allocator)

	for vdf_path in vdf_paths {
		data, ok := os.read_entire_file(vdf_path, allocator)
		if ok != nil do continue

		content := string(data)
		idx := 0
		for idx < len(content) {
			pos := strings.index(content[idx:], `"path"`)
			if pos < 0 do break
			idx += pos + 6

			q1 := strings.index(content[idx:], `"`)
			if q1 < 0 do break
			idx += q1 + 1
			q2 := strings.index(content[idx:], `"`)
			if q2 < 0 do break

			lib_path := content[idx:idx + q2]
			idx += q2 + 1

			// Skip default roots we already check
			is_default := false
			for dr in default_roots {
				if strings.contains(lib_path, dr) {
					is_default = true
					break
				}
			}
			if is_default do continue

			append(&libs, strings.clone(lib_path, allocator))
		}
	}

	return libs[:]
}

// Scan a list of Steam roots for EldenRing save dirs via compatdata
scan_proton_roots :: proc(roots: []string, er_suffix: string, allocator := context.allocator) -> []ER_Save_Dir {
	SEP :: "/" when ODIN_OS != .Windows else "\\"
	dirs := make([dynamic]ER_Save_Dir, allocator)
	seen := make(map[string]bool, 16, allocator)

	for root in roots {
		// De-duplicate
		real, real_err := os.get_absolute_path(root, allocator)
		key := real_err == nil ? real : root
		if key in seen do continue
		seen[key] = true

		compatdata_path := strings.concatenate({root, SEP, "steamapps", SEP, "compatdata"}, allocator)
		compat_handle, compat_err := os.open(compatdata_path)
		if compat_err != nil do continue

		compat_entries, compat_read_err := os.read_all_directory(compat_handle, allocator)
		os.close(compat_handle)
		if compat_read_err != nil do continue

		for app_entry in compat_entries {
			is_dir := app_entry.type == .Directory
			when ODIN_OS != .Windows {
				if app_entry.type == .Symlink {
					link_path := strings.concatenate({compatdata_path, SEP, app_entry.name}, allocator)
					target_info, stat_err := os.stat(link_path, allocator)
					if stat_err == nil do is_dir = target_info.type == .Directory
				}
			}
			if !is_dir do continue

			er_path := strings.concatenate({compatdata_path, SEP, app_entry.name, er_suffix}, allocator)
			// Check if the directory exists
			er_handle, er_err := os.open(er_path)
			if er_err != nil do continue
			os.close(er_handle)

			append(&dirs, ER_Save_Dir{path = er_path, app_id = app_entry.name})
		}
	}

	return dirs[:]
}

// Scan a direct EldenRing AppData path (Windows native or single path)
scan_direct_er_path :: proc(er_base: string, app_id: string, allocator := context.allocator) -> []ER_Save_Dir {
	dirs := make([dynamic]ER_Save_Dir, allocator)

	er_handle, er_err := os.open(er_base)
	if er_err != nil do return dirs[:]
	os.close(er_handle)

	append(&dirs, ER_Save_Dir{path = er_base, app_id = app_id})
	return dirs[:]
}

when ODIN_OS == .Windows {
	get_er_save_dirs :: proc(allocator := context.allocator) -> []ER_Save_Dir {
		all_dirs := make([dynamic]ER_Save_Dir, allocator)
		SEP :: "/" when ODIN_OS != .Windows else "\\"

		// Windows: saves are in %APPDATA%/EldenRing/
		appdata := os.get_env("APPDATA", allocator)
		if len(appdata) > 0 {
			er_base := strings.concatenate({appdata, SEP, "EldenRing"}, allocator)
			for d in scan_direct_er_path(er_base, "1245620", allocator) {
				append(&all_dirs, d)
			}
		}

		// Also check Steam libraries for any modded installs
		// Find Steam install — common Windows locations
		steam_paths := make([dynamic]string, allocator)

		prog_x86 := os.get_env("ProgramFiles(x86)", allocator)
		if len(prog_x86) > 0 {
			append(&steam_paths, strings.concatenate({prog_x86, SEP, "Steam"}, allocator))
		}
		prog := os.get_env("ProgramFiles", allocator)
		if len(prog) > 0 {
			append(&steam_paths, strings.concatenate({prog, SEP, "Steam"}, allocator))
		}
		// Common custom install location
		append(&steam_paths, "C:\\Steam")
		append(&steam_paths, "D:\\Steam")
		append(&steam_paths, "D:\\SteamLibrary")

		// Parse libraryfolders.vdf for extra libraries
		vdf_paths := make([dynamic]string, allocator)
		for sp in steam_paths {
			append(&vdf_paths, strings.concatenate({sp, SEP, "steamapps", SEP, "libraryfolders.vdf"}, allocator))
		}

		default_checks := make([]string, 0, allocator)
		extra_libs := parse_steam_libraries(vdf_paths[:], default_checks, allocator)
		for lib in extra_libs {
			append(&steam_paths, lib)
		}

		// On Windows, modded games might store saves in compatdata-like structures
		// but typically saves are always in %APPDATA%/EldenRing/ regardless of mod
		// So the appdata scan above should catch everything

		return all_dirs[:]
	}
} else {
	get_er_save_dirs :: proc(allocator := context.allocator) -> []ER_Save_Dir {
		all_dirs := make([dynamic]ER_Save_Dir, allocator)

		home := os.get_env("HOME", allocator)
		if len(home) == 0 do return all_dirs[:]

		// Default Steam roots on Linux (native + Flatpak)
		steam_roots := make([dynamic]string, allocator)
		append(&steam_roots, strings.concatenate({home, "/.steam/steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.local/share/Steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.steam/steam"}, allocator))
		append(&steam_roots, strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.local/share/Steam"}, allocator))

		// Parse libraryfolders.vdf for extra libraries
		vdf_paths := [?]string{
			strings.concatenate({home, "/.steam/steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.local/share/Steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps/libraryfolders.vdf"}, allocator),
			strings.concatenate({home, "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"}, allocator),
		}

		default_roots := [?]string{"/.steam/steam", "/.local/share/Steam", "/.var/app/com.valvesoftware.Steam/.steam/steam", "/.var/app/com.valvesoftware.Steam/.local/share/Steam"}
		extra_libs := parse_steam_libraries(vdf_paths[:], default_roots[:], allocator)
		for lib in extra_libs {
			append(&steam_roots, lib)
		}

		// Scan all compatdata for EldenRing saves (catches mods, seamless co-op, etc.)
		ER_APPDATA_SUFFIX :: "/pfx/drive_c/users/steamuser/AppData/Roaming/EldenRing"
		for d in scan_proton_roots(steam_roots[:], ER_APPDATA_SUFFIX, allocator) {
			append(&all_dirs, d)
		}

		return all_dirs[:]
	}
}

// ============================================================================
// Save Reload & Boss Status Update
// ============================================================================

reload_save :: proc() {
	if len(app.save_path) == 0 do return

	if app.save_loaded {
		close_save_file(&app.save_file)
		app.save_loaded = false
	}

	save, ok := open_save_file(app.save_path)
	if !ok do return

	app.save_file = save
	app.save_loaded = true

	// Get character slots
	app.slots = get_character_slots(&app.save_file)

	// Update boss status
	update_boss_status()
}

update_boss_status :: proc() {
	if !app.save_loaded || app.active_slot < 0 do return

	event_flags, ef_offset := get_slot_event_flags(&app.save_file, app.active_slot, app.bst_map)
	if event_flags == nil {
		fmt.eprintln("Could not find event flags for slot", app.active_slot)
		return
	}

	for &r in app.regions {
		for &b in r.bosses {
			b.killed = check_event_flag(event_flags, b.flag_id, app.bst_map)
		}
	}

	// Read death count
	app.death_count = get_death_count(&app.save_file, app.active_slot, ef_offset)

}

// ============================================================================
// Polling Thread
// ============================================================================

poll_save_file :: proc(data: rawptr) {
	state := cast(^App_State)data
	last_mod_time: time.Time

	for {
		time.sleep(state.poll_interval)

		if !state.save_loaded || len(state.save_path) == 0 do continue
		if state.active_slot < 0 do continue

		// Check file modification time first
		file_info, stat_err := os.stat(state.save_path, context.temp_allocator)
		if stat_err != nil do continue

		if last_mod_time._nsec != 0 && file_info.modification_time._nsec == last_mod_time._nsec {
			continue  // File hasn't been modified
		}
		last_mod_time = file_info.modification_time

		// Re-read the save file
		raw, read_err := os.read_entire_file(state.save_path, context.temp_allocator)
		if read_err != nil do continue

		// Copy new data over the existing allocation
		if len(raw) == len(state.save_file.raw_data) {
			copy(state.save_file.raw_data, raw)
		} else {
			continue  // Size changed unexpectedly
		}

		// Re-parse character slots (updates level, name, etc.)
		state.slots = get_character_slots(&state.save_file, context.temp_allocator)

		// Record old status
		old_killed := make(map[u32]bool, 256, context.temp_allocator)
		for &r in state.regions {
			for &b in r.bosses {
				old_killed[b.flag_id] = b.killed
			}
		}

		old_deaths := state.death_count

		// Update
		update_boss_status()

		// Check for changes and broadcast SSE
		has_changes := false
		for &r in state.regions {
			for &b in r.bosses {
				if old, found := old_killed[b.flag_id]; found && old != b.killed {
					has_changes = true
					break
				}
			}
			if has_changes do break
		}

		if !has_changes && old_deaths == state.death_count do continue

		// Broadcast SSE update
		total, killed := count_bosses(state.regions)
		sse_data := fmt.tprintf(
			`{"killed_count":%d,"total":%d,"death_count":%d}`,
			killed, total, state.death_count,
		)

		sync.mutex_lock(&state.sse_mutex)
		for i := len(state.sse_clients) - 1; i >= 0; i -= 1 {
			if !http.sse_event(state.sse_clients[i], sse_data, event = "boss_update") {
				ordered_remove(&state.sse_clients, i)
			}
		}
		sync.mutex_unlock(&state.sse_mutex)
	}
}

