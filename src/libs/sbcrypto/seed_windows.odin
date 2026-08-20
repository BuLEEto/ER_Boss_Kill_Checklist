#+build windows
package sbcrypto

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Windows has no /etc/machine-id. The closest equivalent is MachineGuid,
// written by the installer into
// HKLM\SOFTWARE\Microsoft\Cryptography and stable for the life of the
// install.
//
// The read goes through the 64-bit view explicitly: a 32-bit process
// would otherwise be redirected to the WOW6432Node copy, which holds a
// different GUID — and a key that changed with the build's bitness would
// silently invalidate every stored secret.
//
// Falling back to the computer and user names keeps this working in
// locked-down environments where the key isn't readable. Renaming the PC
// then invalidates stored secrets, which surfaces as "re-enter your
// password once" rather than anything worse.
machine_seed :: proc(allocator := context.allocator) -> string {
	if guid := machine_guid(allocator); len(guid) > 0 do return guid

	computer := os.get_env("COMPUTERNAME", context.temp_allocator)
	profile := os.get_env("USERPROFILE", context.temp_allocator)
	user := os.get_env("USERNAME", context.temp_allocator)
	if len(computer) == 0 && len(profile) == 0 && len(user) == 0 do return ""
	return strings.concatenate({computer, "\x00", profile, "\x00", user}, allocator)
}

@(private = "file")
machine_guid :: proc(allocator := context.allocator) -> string {
	sub_key := win.utf8_to_wstring("SOFTWARE\\Microsoft\\Cryptography")
	value := win.utf8_to_wstring("MachineGuid")

	buf: [128]u16
	size := win.DWORD(size_of(buf))

	status := win.RegGetValueW(
		win.HKEY_LOCAL_MACHINE,
		sub_key,
		value,
		win.RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
		nil,
		&buf[0],
		&size,
	)
	if status != 0 do return ""

	// size is bytes including the terminating NUL.
	n := int(size) / size_of(u16)
	for n > 0 && buf[n - 1] == 0 do n -= 1
	if n <= 0 do return ""

	text, err := win.utf16_to_utf8(buf[:n], allocator)
	if err != nil do return ""
	return text
}

// Not in core:sys/windows yet: force the 64-bit registry view so the
// answer doesn't depend on whether this build is 32- or 64-bit.
@(private = "file") RRF_SUBKEY_WOW6464KEY :: win.DWORD(0x00010000)
