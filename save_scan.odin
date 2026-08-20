package main

import "core:os"
import "core:strings"

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
// Structured save scan
//
// The old build did this inside an HTTP handler and hand-rolled the JSON
// on the way out. The GUI wants the data itself, so the scan returns
// values and the (now GUI-only) callers format them however they like.
// ============================================================================

Found_Character :: struct {
	index: int,
	name:  string,
	level: u32,
}

Found_Save :: struct {
	path:       string,
	filename:   string,
	app_id:     string, // Steam AppID the compatdata prefix belongs to
	characters: []Found_Character,
}

SAVE_EXTENSIONS :: [?]string{".sl2", ".co2", ".rd2"}

// True if `name` looks like an Elden Ring save we can read.
is_save_filename :: proc(name: string) -> bool {
	for ext in SAVE_EXTENSIONS {
		if strings.has_suffix(name, ext) do return true
	}
	return false
}

// Walk every Steam library (including Proton prefixes and Flatpak) for
// Elden Ring saves, reading each one's character list. Slow enough —
// it opens every save it finds — that callers should run it off the GUI
// thread.
scan_saves :: proc(allocator := context.allocator) -> []Found_Save {
	SEP :: "/" when ODIN_OS != .Windows else "\\"

	found := make([dynamic]Found_Save, allocator)
	er_save_dirs := get_er_save_dirs(allocator)

	for &dir_info in er_save_dirs {
		// Each subfolder of the EldenRing dir is a Steam user ID.
		user_entries, user_err := os.read_all_directory_by_path(dir_info.path, allocator)
		if user_err != nil do continue

		for user_entry in user_entries {
			if !entry_is_dir(dir_info.path, user_entry) do continue

			user_dir := strings.concatenate({dir_info.path, SEP, user_entry.name}, allocator)
			files, files_err := os.read_all_directory_by_path(user_dir, allocator)
			if files_err != nil do continue

			for sf in files {
				// Skip the .bak-style duplicates the game leaves behind.
				if strings.contains(sf.name, "copy") do continue
				if !is_save_filename(sf.name) do continue

				full_path := strings.concatenate({user_dir, SEP, sf.name}, allocator)

				chars := make([dynamic]Found_Character, allocator)
				if save, ok := open_save_file(full_path, allocator); ok {
					defer close_save_file(&save, allocator)
					for s in get_character_slots(&save, allocator) {
						if !s.active do continue
						append(&chars, Found_Character{
							index = s.index,
							name  = strings.clone(s.name, allocator),
							level = s.level,
						})
					}
				}

				append(&found, Found_Save{
					path       = full_path,
					filename   = strings.clone(sf.name, allocator),
					app_id     = strings.clone(dir_info.app_id, allocator),
					characters = chars[:],
				})
			}
		}
	}

	return found[:]
}

// Directory test that also follows symlinks, which Steam libraries are
// full of on Linux.
entry_is_dir :: proc(parent: string, fi: os.File_Info) -> bool {
	if fi.type == .Directory do return true
	when ODIN_OS != .Windows {
		if fi.type == .Symlink {
			SEP :: "/"
			link := strings.concatenate({parent, SEP, fi.name}, context.temp_allocator)
			return os.is_directory(link)
		}
	}
	return false
}
