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
// Blocking on purpose, and therefore called from a worker rather than the GUI
// thread: xdg-open can sit there until the browser is up, and there is no way
// to release a process handle in core:os without waiting for it. Waiting on a
// worker costs nothing; waiting on the GUI thread would freeze the window
// during the one action whose whole point is that it happens elsewhere.
open_url :: proc(url: string) -> bool {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = {"xdg-open", url}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)

	return err == nil && state.success
}
