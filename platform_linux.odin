#+build linux
package main

import "core:fmt"
import "core:os"
import "core:sys/linux"

// Work out which local address a phone on the same network should use.
// The trick: "connect" a UDP socket to a public address. No packet is
// sent — the kernel just picks the interface it would route through and
// binds the socket to that interface's address, which we then read back.
detect_lan_ip :: proc() -> string {
	sock, sock_err := linux.socket(.INET, .DGRAM, {}, .HOPOPT)
	if sock_err != .NONE do return ""
	defer linux.close(sock)

	target := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = 80,
		sin_addr   = {8, 8, 8, 8},
	}
	if linux.connect(sock, &target) != .NONE do return ""

	local: linux.Sock_Addr_Any
	if linux.getsockname(sock, &local) != .NONE do return ""

	a := local.ipv4.sin_addr
	if a == {0, 0, 0, 0} || a == {127, 0, 0, 1} do return ""

	return fmt.aprintf("%d.%d.%d.%d", a[0], a[1], a[2], a[3])
}

// Linux builds keep their console, so fatal() has already said its piece
// on stderr by the time we get here.
show_fatal_dialog :: proc(message: string) {}

// Hand a URL to whatever the desktop opens links with.
//
// process_start, not process_exec. process_exec builds pipes for stdout and
// stderr and reads them to EOF — and a browser launched by xdg-open inherits
// those pipes, so exec doesn't return until the browser is *closed*, not until
// it opens. Measured: `sh -c 'sleep 3 & exit 0'` takes three seconds to come
// back. Every click would have parked a worker thread, and its temp arena,
// for as long as the browser stayed open.
//
// Without pipes there is nothing to hold open, so the wait is for xdg-open
// itself, which exits as soon as it has handed the URL over. The wait is what
// reaps the child and releases the handle, and it runs on a worker, so a slow
// handler costs nothing.
open_url :: proc(url: string) -> bool {
	process, err := os.process_start(os.Process_Desc{command = {"xdg-open", url}})
	if err != nil do return false

	state, wait_err := os.process_wait(process)
	return wait_err == nil && state.success
}
