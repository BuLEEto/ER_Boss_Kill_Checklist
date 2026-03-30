#+build linux
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

foreign import libc "system:c"
foreign libc {
	chdir :: proc "c" (path: cstring) -> i32 ---
}

change_to_exe_dir :: proc() {
	exe_path, exe_err := os.read_link("/proc/self/exe", context.temp_allocator)
	if exe_err == nil {
		exe_dir := filepath.dir(exe_path, context.temp_allocator)
		cdir := strings.clone_to_cstring(exe_dir, context.temp_allocator)
		chdir(cdir)
	}
}

detect_lan_ip :: proc() -> string {
	// UDP connect trick: connect a UDP socket to an external IP.
	// The OS picks the right local interface without sending any data.
	sock, sock_err := linux.socket(.INET, .DGRAM, {}, .HOPOPT)
	if sock_err != .NONE do return ""

	target := linux.Sock_Addr_In{
		sin_family = .INET,
		sin_port   = 80,
		sin_addr   = {8, 8, 8, 8},
	}

	if linux.connect(sock, &target) != .NONE {
		linux.close(sock)
		return ""
	}

	local: linux.Sock_Addr_Any
	if linux.getsockname(sock, &local) != .NONE {
		linux.close(sock)
		return ""
	}
	linux.close(sock)

	a := local.ipv4.sin_addr
	if a == {0, 0, 0, 0} || a == {127, 0, 0, 1} do return ""

	return fmt.aprintf("%d.%d.%d.%d", a[0], a[1], a[2], a[3])
}
