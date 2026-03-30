#+build windows
package main

import "core:fmt"
import "core:net"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign kernel32 {
	GetModuleFileNameW :: proc "stdcall" (hModule: rawptr, lpFilename: [^]u16, nSize: u32) -> u32 ---
	SetCurrentDirectoryW :: proc "stdcall" (lpPathName: [^]u16) -> b32 ---
}

change_to_exe_dir :: proc() {
	buf: [512]u16
	n := GetModuleFileNameW(nil, &buf[0], 512)
	if n > 0 {
		exe_str, _ := windows.utf16_to_utf8(buf[:n], context.temp_allocator)
		exe_dir := filepath.dir(exe_str, context.temp_allocator)
		wdir := windows.utf8_to_utf16(exe_dir, context.temp_allocator)
		SetCurrentDirectoryW(raw_data(wdir))
	}
}

detect_lan_ip :: proc() -> string {
	// Use core:net UDP send trick to detect local interface
	sock, sock_err := net.make_unbound_udp_socket(.IP4)
	if sock_err != nil do return ""

	target := net.Endpoint{
		address = net.IP4_Address{8, 8, 8, 8},
		port    = 80,
	}
	net.send_udp(sock, {0}, target)

	ep, ep_err := net.bound_endpoint(sock)
	net.close(sock)
	if ep_err != nil do return ""

	addr_str := net.to_string(ep.address)
	if addr_str == "0.0.0.0" || addr_str == "127.0.0.1" do return ""
	return strings.clone(addr_str)
}
