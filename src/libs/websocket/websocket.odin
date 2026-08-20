package websocket

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// ============================================================================
// Minimal RFC 6455 WebSocket client
//
// Enough to talk to a local obs-websocket server: the HTTP upgrade
// handshake, masked client frames, unmasked server frames, fragment
// reassembly, and automatic ping/pong. Deliberately not implemented:
//
//   * wss:// — no TLS. obs-websocket listens on plain ws:// on loopback.
//   * permessage-deflate — never negotiated, so the server won't use it.
//   * server-side operation.
//
// One connection is one socket used from one thread at a time. `send` is
// mutex-guarded so a keep-alive or a push from another thread can't
// interleave halfway through a frame, but `receive` must only ever be
// called from a single reader.
// ============================================================================

// The fixed UUID from RFC 6455 §1.3, concatenated with the client key to
// derive the server's expected Sec-WebSocket-Accept.
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

MAX_FRAME_PAYLOAD :: 8 * 1024 * 1024

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

Error :: enum {
	None,
	Dial_Failed,
	Handshake_Failed,
	Handshake_Rejected,
	Bad_Accept_Key,
	Send_Failed,
	Recv_Failed,
	Closed,
	Protocol_Error,
	Frame_Too_Large,
	Not_Connected,
}

Conn :: struct {
	socket:    net.TCP_Socket,
	connected: bool,
	send_lock: sync.Mutex,

	// Bytes read from the socket but not yet consumed by a frame.
	rx:        [dynamic]u8,
	allocator: mem.Allocator,
}

Message :: struct {
	opcode:  Opcode,
	payload: []u8, // allocated with the allocator passed to `receive`
}

// ----------------------------------------------------------------------------
// Connect
// ----------------------------------------------------------------------------

connect :: proc(
	host: string,
	port: int,
	path := "/",
	timeout := 5 * time.Second,
	allocator := context.allocator,
) -> (
	conn: ^Conn,
	err: Error,
) {
	endpoint, resolve_ok := resolve(host, port)
	if !resolve_ok do return nil, .Dial_Failed

	socket, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do return nil, .Dial_Failed

	// Without a receive timeout a dead server parks the reader thread
	// forever, and this runs on a worker we want to be able to retire.
	net.set_option(socket, .Receive_Timeout, timeout)
	net.set_option(socket, .Send_Timeout, timeout)
	net.set_option(socket, .TCP_Nodelay, true)

	c := new(Conn, allocator)
	c.socket = socket
	c.allocator = allocator
	c.rx = make([dynamic]u8, allocator)

	if hs_err := handshake(c, host, port, path); hs_err != .None {
		net.close(socket)
		delete(c.rx)
		free(c, allocator)
		return nil, hs_err
	}

	c.connected = true
	return c, .None
}

resolve :: proc(host: string, port: int) -> (net.Endpoint, bool) {
	if addr := net.parse_address(host); addr != nil {
		return net.Endpoint{address = addr, port = port}, true
	}
	ep, err := net.resolve_ip4(host)
	if err != nil do return {}, false
	ep.port = port
	return ep, true
}

@(private)
handshake :: proc(c: ^Conn, host: string, port: int, path: string) -> Error {
	key_bytes: [16]u8
	crypto.rand_bytes(key_bytes[:])
	key, _ := base64.encode(key_bytes[:], allocator = context.temp_allocator)

	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\n" +
		"Host: %s:%d\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: %s\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n",
		path, host, port, key,
	)

	if !send_all(c.socket, transmute([]u8)req) do return .Handshake_Failed

	// Read until the end of the header block. Anything past it is the
	// first frame — keep it in the rx buffer.
	header_end := -1
	for header_end < 0 {
		if !fill(c) do return .Handshake_Failed
		header_end = strings.index(string(c.rx[:]), "\r\n\r\n")
		if len(c.rx) > 16 * 1024 do return .Handshake_Failed
	}

	header := string(c.rx[:header_end])
	remove_front(c, header_end + 4)

	status_end := strings.index(header, "\r\n")
	if status_end < 0 do return .Handshake_Failed
	if !strings.contains(header[:status_end], " 101") do return .Handshake_Rejected

	expected := accept_key(key, context.temp_allocator)
	if !header_has(header, "sec-websocket-accept:", expected) do return .Bad_Accept_Key

	return .None
}

// SHA1(client_key + WS_GUID), base64-encoded — RFC 6455 §4.1.
@(private)
accept_key :: proc(key: string, allocator := context.allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)string(WS_GUID))

	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])

	encoded, _ := base64.encode(digest[:], allocator = allocator)
	return encoded
}

// Case-insensitive header lookup with an exact (trimmed) value match.
@(private)
header_has :: proc(header, name_lower, value: string) -> bool {
	lower := strings.to_lower(header, context.temp_allocator)
	idx := strings.index(lower, name_lower)
	if idx < 0 do return false

	rest := header[idx + len(name_lower):]
	if end := strings.index(rest, "\r\n"); end >= 0 {
		rest = rest[:end]
	}
	return strings.trim_space(rest) == value
}

// ----------------------------------------------------------------------------
// Send
// ----------------------------------------------------------------------------

send_text :: proc(c: ^Conn, text: string) -> Error {
	return send_frame(c, .Text, transmute([]u8)text)
}

send_pong :: proc(c: ^Conn, payload: []u8) -> Error {
	return send_frame(c, .Pong, payload)
}

send_close :: proc(c: ^Conn) -> Error {
	// 1000 = normal closure, big-endian, as the first two payload bytes.
	code := [2]u8{0x03, 0xE8}
	return send_frame(c, .Close, code[:])
}

@(private)
send_frame :: proc(c: ^Conn, opcode: Opcode, payload: []u8) -> Error {
	if c == nil || !c.connected do return .Not_Connected

	sync.mutex_lock(&c.send_lock)
	defer sync.mutex_unlock(&c.send_lock)

	buf := make([dynamic]u8, 0, len(payload) + 14, context.temp_allocator)

	append(&buf, 0x80 | u8(opcode)) // FIN set; we never fragment outbound

	// Client frames are always masked (RFC 6455 §5.3), so the length byte
	// carries the mask bit.
	n := len(payload)
	switch {
	case n <= 125:
		append(&buf, 0x80 | u8(n))
	case n <= 0xFFFF:
		append(&buf, 0x80 | 126)
		append(&buf, u8(n >> 8), u8(n))
	case:
		append(&buf, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 {
			append(&buf, u8(n >> uint(shift)))
		}
	}

	mask: [4]u8
	crypto.rand_bytes(mask[:])
	append(&buf, ..mask[:])

	start := len(buf)
	resize(&buf, start + n)
	for i in 0 ..< n {
		buf[start + i] = payload[i] ~ mask[i % 4]
	}

	if !send_all(c.socket, buf[:]) {
		c.connected = false
		return .Send_Failed
	}
	return .None
}

@(private)
send_all :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(socket, data[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// ----------------------------------------------------------------------------
// Receive
// ----------------------------------------------------------------------------

// Blocks until a complete application message arrives. Ping frames are
// answered and skipped; Close ends the connection and returns .Closed.
// The caller owns `msg.payload`.
receive :: proc(c: ^Conn, allocator := context.allocator) -> (msg: Message, err: Error) {
	if c == nil || !c.connected do return {}, .Not_Connected

	assembled := make([dynamic]u8, allocator)
	message_op := Opcode.Continuation

	for {
		fin, opcode, payload, frame_err := read_frame(c)
		if frame_err != .None {
			delete(assembled)
			return {}, frame_err
		}

		switch opcode {
		case .Ping:
			send_pong(c, payload)
			delete(payload, c.allocator)
			continue

		case .Pong:
			delete(payload, c.allocator)
			continue

		case .Close:
			delete(payload, c.allocator)
			delete(assembled)
			c.connected = false
			return {}, .Closed

		case .Text, .Binary:
			if message_op != .Continuation {
				// A new data frame before the previous one finished.
				delete(payload, c.allocator)
				delete(assembled)
				return {}, .Protocol_Error
			}
			message_op = opcode
			append(&assembled, ..payload)
			delete(payload, c.allocator)

		case .Continuation:
			if message_op == .Continuation {
				delete(payload, c.allocator)
				delete(assembled)
				return {}, .Protocol_Error
			}
			append(&assembled, ..payload)
			delete(payload, c.allocator)
		}

		if fin {
			return Message{opcode = message_op, payload = assembled[:]}, .None
		}
	}
}

// Reads exactly one frame. Payload is allocated with c.allocator and
// owned by the caller.
@(private)
read_frame :: proc(c: ^Conn) -> (fin: bool, opcode: Opcode, payload: []u8, err: Error) {
	if !want(c, 2) do return false, .Continuation, nil, .Recv_Failed

	b0 := c.rx[0]
	b1 := c.rx[1]
	fin = b0 & 0x80 != 0
	opcode = Opcode(b0 & 0x0F)
	masked := b1 & 0x80 != 0
	length := int(b1 & 0x7F)
	header := 2

	switch length {
	case 126:
		if !want(c, header + 2) do return false, opcode, nil, .Recv_Failed
		length = int(c.rx[2]) << 8 | int(c.rx[3])
		header += 2
	case 127:
		if !want(c, header + 8) do return false, opcode, nil, .Recv_Failed
		length = 0
		for i in 0 ..< 8 {
			length = length << 8 | int(c.rx[2 + i])
		}
		header += 8
	}

	if length < 0 || length > MAX_FRAME_PAYLOAD {
		c.connected = false
		return false, opcode, nil, .Frame_Too_Large
	}

	// A conforming server never masks, but honour the bit rather than
	// silently returning scrambled bytes if one does.
	mask: [4]u8
	if masked {
		if !want(c, header + 4) do return false, opcode, nil, .Recv_Failed
		copy(mask[:], c.rx[header:header + 4])
		header += 4
	}

	if !want(c, header + length) do return false, opcode, nil, .Recv_Failed

	out := make([]u8, length, c.allocator)
	copy(out, c.rx[header:header + length])
	if masked {
		for i in 0 ..< length {
			out[i] ~= mask[i % 4]
		}
	}

	remove_front(c, header + length)
	return fin, opcode, out, .None
}

// ----------------------------------------------------------------------------
// Buffered socket reads
// ----------------------------------------------------------------------------

// Ensure at least `n` bytes are buffered.
@(private)
want :: proc(c: ^Conn, n: int) -> bool {
	for len(c.rx) < n {
		if !fill(c) do return false
	}
	return true
}

@(private)
fill :: proc(c: ^Conn) -> bool {
	chunk: [8192]u8
	n, err := net.recv_tcp(c.socket, chunk[:])
	if err != nil || n <= 0 {
		c.connected = false
		return false
	}
	append(&c.rx, ..chunk[:n])
	return true
}

@(private)
remove_front :: proc(c: ^Conn, n: int) {
	if n <= 0 do return
	if n >= len(c.rx) {
		clear(&c.rx)
		return
	}
	copy(c.rx[:], c.rx[n:])
	resize(&c.rx, len(c.rx) - n)
}

// ----------------------------------------------------------------------------
// Teardown
// ----------------------------------------------------------------------------

close :: proc(c: ^Conn) {
	if c == nil do return
	if c.connected {
		send_close(c)
		c.connected = false
	}
	net.close(c.socket)
}

destroy :: proc(c: ^Conn) {
	if c == nil do return
	close(c)
	delete(c.rx)
	free(c, c.allocator)
}

is_connected :: proc(c: ^Conn) -> bool {
	return c != nil && c.connected
}
