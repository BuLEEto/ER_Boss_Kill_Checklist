#+build windows
package main

import "core:net"
import "core:strings"

// See platform_linux.odin for why this works — same UDP routing trick,
// expressed through core:net because Winsock's getsockname needs more
// ceremony than it's worth here.
detect_lan_ip :: proc() -> string {
	sock, sock_err := net.make_unbound_udp_socket(.IP4)
	if sock_err != nil do return ""
	defer net.close(sock)

	target := net.Endpoint {
		address = net.IP4_Address{8, 8, 8, 8},
		port    = 80,
	}
	net.send_udp(sock, {0}, target)

	ep, ep_err := net.bound_endpoint(sock)
	if ep_err != nil do return ""

	addr := net.to_string(ep.address)
	if addr == "0.0.0.0" || addr == "127.0.0.1" do return ""
	return strings.clone(addr)
}
