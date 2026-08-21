#+build linux, darwin
package sbcrypto

import "core:os"
import "core:strings"

// A stable per-machine identifier, used only as key material.
//
// /etc/machine-id is the right answer where it exists: created once at
// install, readable by everyone, and it survives reboots and upgrades.
// /var/lib/dbus/machine-id is the older location some systems still use
// (and is usually a symlink to the first). Falling back to the user's
// home path and name keeps the app working on systems that have neither
// — a weaker seed, but still machine- and user-specific, which is the
// property that matters here.
machine_seed :: proc(allocator := context.allocator) -> string {
	for path in ([?]string{"/etc/machine-id", "/var/lib/dbus/machine-id"}) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do continue
		id := strings.trim_space(string(data))
		if len(id) > 0 do return strings.clone(id, allocator)
	}

	home := os.get_env("HOME", context.temp_allocator)
	user := os.get_env("USER", context.temp_allocator)
	if len(home) == 0 && len(user) == 0 do return ""
	return strings.concatenate({home, "\x00", user}, allocator)
}
