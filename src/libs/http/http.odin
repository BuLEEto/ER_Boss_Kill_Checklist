package http

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ============================================================================
// Error Types
// ============================================================================

Error :: enum {
	None,
	Server_Start_Failed,
	Socket_Error,
	Accept_Failed,
	Invalid_Request,
	Invalid_Method,
	Request_Too_Large,
	Route_Not_Found,
	Method_Not_Allowed,
	Session_Not_Found,
	Session_Expired,
	File_Not_Found,
	Template_Error,
	Parse_Error,
}

// ============================================================================
// HTTP Primitives
// ============================================================================

Method :: enum {
	GET,
	POST,
	PUT,
	DELETE,
	PATCH,
	HEAD,
	OPTIONS,
}

Status :: enum u16 {
	// 1xx Informational
	Continue            = 100,
	Switching_Protocols = 101,

	// 2xx Success
	OK                  = 200,
	Created             = 201,
	Accepted            = 202,
	No_Content          = 204,

	// 3xx Redirection
	Moved_Permanently   = 301,
	Found               = 302,
	See_Other           = 303,
	Not_Modified        = 304,
	Temporary_Redirect  = 307,
	Permanent_Redirect  = 308,

	// 4xx Client Errors
	Bad_Request         = 400,
	Unauthorized        = 401,
	Forbidden           = 403,
	Not_Found           = 404,
	Method_Not_Allowed  = 405,
	Not_Acceptable      = 406,
	Request_Timeout     = 408,
	Conflict            = 409,
	Gone                = 410,
	Length_Required     = 411,
	Payload_Too_Large   = 413,
	URI_Too_Long        = 414,
	Unsupported_Media   = 415,
	Too_Many_Requests   = 429,

	// 5xx Server Errors
	Internal_Error      = 500,
	Not_Implemented     = 501,
	Bad_Gateway         = 502,
	Service_Unavailable = 503,
	Gateway_Timeout     = 504,
}

// Get status text for HTTP response line
status_text :: proc(status: Status) -> string {
	switch status {
	case .Continue:
		return "Continue"
	case .Switching_Protocols:
		return "Switching Protocols"
	case .OK:
		return "OK"
	case .Created:
		return "Created"
	case .Accepted:
		return "Accepted"
	case .No_Content:
		return "No Content"
	case .Moved_Permanently:
		return "Moved Permanently"
	case .Found:
		return "Found"
	case .See_Other:
		return "See Other"
	case .Not_Modified:
		return "Not Modified"
	case .Temporary_Redirect:
		return "Temporary Redirect"
	case .Permanent_Redirect:
		return "Permanent Redirect"
	case .Bad_Request:
		return "Bad Request"
	case .Unauthorized:
		return "Unauthorized"
	case .Forbidden:
		return "Forbidden"
	case .Not_Found:
		return "Not Found"
	case .Method_Not_Allowed:
		return "Method Not Allowed"
	case .Not_Acceptable:
		return "Not Acceptable"
	case .Request_Timeout:
		return "Request Timeout"
	case .Conflict:
		return "Conflict"
	case .Gone:
		return "Gone"
	case .Length_Required:
		return "Length Required"
	case .Payload_Too_Large:
		return "Payload Too Large"
	case .URI_Too_Long:
		return "URI Too Long"
	case .Unsupported_Media:
		return "Unsupported Media Type"
	case .Too_Many_Requests:
		return "Too Many Requests"
	case .Internal_Error:
		return "Internal Server Error"
	case .Not_Implemented:
		return "Not Implemented"
	case .Bad_Gateway:
		return "Bad Gateway"
	case .Service_Unavailable:
		return "Service Unavailable"
	case .Gateway_Timeout:
		return "Gateway Timeout"
	}
	return "Unknown"
}

// ============================================================================
// Request
// ============================================================================

Request :: struct {
	method:       Method,
	path:         string,
	query_string: string,
	version:      string,
	headers:      map[string]string,
	cookies:      map[string]string,
	params:       map[string]string, // Route parameters like /users/{id}
	query:        map[string]string, // Parsed query string
	body:         []byte,
	remote_addr:  string,
	allocator:    mem.Allocator,
}

// ============================================================================
// Response
// ============================================================================

Cookie :: struct {
	name:      string,
	value:     string,
	path:      string,
	domain:    string,
	expires:   time.Time,
	max_age:   int, // In seconds, 0 means session cookie
	secure:    bool,
	http_only: bool,
	same_site: Same_Site,
}

Same_Site :: enum {
	Default,
	Strict,
	Lax,
	None,
}

Response :: struct {
	status:       Status,
	headers:      map[string]string,
	cookies:      [dynamic]Cookie,
	body:         [dynamic]byte,
	socket:       net.TCP_Socket,
	written:      bool, // Has response been sent?
	streaming:    bool, // Is this an SSE streaming response?
	headers_sent: bool, // Have headers been flushed to socket?
	allocator:    mem.Allocator,
}

// ============================================================================
// Router
// ============================================================================

Handler :: #type proc(req: ^Request, res: ^Response)

// Middleware function - returns true to continue to next middleware/handler, false to stop chain
// If middleware sends a response (res.written = true), chain automatically stops
Middleware :: #type proc(req: ^Request, res: ^Response) -> bool

Route :: struct {
	pattern:  string, // e.g., "/users/{id}"
	method:   Method,
	handler:  Handler,
	segments: []Route_Segment, // Parsed pattern
}

Route_Segment :: struct {
	value:    string,
	is_param: bool, // True if this is a {param}
}

Router :: struct {
	routes:     [dynamic]Route,
	middleware: [dynamic]Middleware, // Global middleware chain
	not_found:  Handler,
	allocator:  mem.Allocator,
}

// ============================================================================
// Sessions
// ============================================================================

Session :: struct {
	id:         string,
	data:       map[string]string,
	mutex:      sync.Mutex,
	created_at: time.Time,
	expires_at: time.Time,
	allocator:  mem.Allocator,
}

Session_Store :: struct {
	sessions:    map[string]^Session,
	mutex:       sync.Mutex,
	ttl:         time.Duration,
	cookie_name: string,
	secure:      bool,
	allocator:   mem.Allocator,
}

// ============================================================================
// Request Logging
// ============================================================================

// Log entry passed to logger callback after each request
Log_Entry :: struct {
	method:      Method,
	path:        string,
	status:      Status,
	duration:    time.Duration,
	remote_addr: string,
	user_agent:  string,
	bytes_sent:  int,
	request:     ^Request, // full request, for custom loggers that need headers etc.
}

// Logger callback type - called after each request completes
Logger_Callback :: #type proc(entry: ^Log_Entry)

// Default logger that prints to stdout in Common Log Format style
default_logger :: proc(entry: ^Log_Entry) {
	duration_ms := f64(time.duration_microseconds(entry.duration)) / 1000.0
	fmt.printf(
		"[%s] %s %s -> %d (%.2fms, %d bytes)\n",
		entry.remote_addr,
		method_to_string(entry.method),
		entry.path,
		int(entry.status),
		duration_ms,
		entry.bytes_sent,
	)
}

// ============================================================================
// Server
// ============================================================================

Server :: struct {
	listener:         net.TCP_Socket,
	router:           ^Router,
	sessions:         ^Session_Store,
	address:          string,
	port:             int,
	static_dir:       string,
	static_prefix:    string,
	running:          bool,
	thread_pool:      [dynamic]^thread.Thread,
	pool_size:        int,
	request_queue:    Queue(Connection_Task),
	queue_mutex:      sync.Mutex,
	queue_cond:       sync.Cond,
	shutdown:         bool,
	allocator:        mem.Allocator,
	max_request_size:   int, // Maximum request body size (default: 10MB)
	read_timeout:       time.Duration, // Socket read timeout (default: 30s)
	write_timeout:      time.Duration, // Socket write timeout (default: 30s)
	shutdown_timeout:   time.Duration, // Graceful shutdown timeout (default: 30s)
	keep_alive_timeout: time.Duration, // Keep-alive idle timeout between requests (default: 5s)
	max_keep_alive:     int, // Max requests per connection (default: 100)
	active_requests:    int, // Counter for in-flight requests (atomic)
	logger:             Logger_Callback, // Optional request logger (nil = no logging)
}

Connection_Task :: struct {
	client_socket: net.TCP_Socket,
	client_addr:   net.Endpoint,
}

// Simple thread-safe queue
Queue :: struct($T: typeid) {
	items: [dynamic]T,
}

// ============================================================================
// Server API
// ============================================================================

server_create :: proc(
	address: string = "0.0.0.0",
	port: int = 8080,
	pool_size: int = 4,
	max_request_size: int = 10 * 1024 * 1024, // 10MB default
	read_timeout: time.Duration = 30 * time.Second, // 30s default
	write_timeout: time.Duration = 30 * time.Second, // 30s default
	shutdown_timeout: time.Duration = 30 * time.Second, // 30s default
	keep_alive_timeout: time.Duration = 5 * time.Second, // 5s idle timeout between keep-alive requests
	max_keep_alive: int = 100, // Max requests per keep-alive connection
	allocator := context.allocator,
) -> (
	server: ^Server,
	err: Error,
) {
	context.allocator = allocator

	server = new(Server)
	server.address = strings.clone(address, allocator)
	server.port = port
	server.pool_size = pool_size
	server.max_request_size = max_request_size
	server.read_timeout = read_timeout
	server.write_timeout = write_timeout
	server.shutdown_timeout = shutdown_timeout
	server.keep_alive_timeout = keep_alive_timeout
	server.max_keep_alive = max_keep_alive
	server.allocator = allocator
	server.running = false
	server.shutdown = false
	server.active_requests = 0
	server.static_prefix = "/static/"
	server.request_queue.items = make([dynamic]Connection_Task, allocator)
	server.thread_pool = make([dynamic]^thread.Thread, allocator)

	return server, .None
}

server_destroy :: proc(server: ^Server) {
	if server == nil do return

	// Graceful shutdown first
	server_shutdown(server)

	// Clean up resources
	if server.router != nil {
		router_destroy(server.router)
	}

	if server.sessions != nil {
		session_store_destroy(server.sessions)
	}

	delete(server.address, server.allocator)
	if server.static_dir != "" {
		delete(server.static_dir, server.allocator)
	}
	if server.static_prefix != "/static/" {
		delete(server.static_prefix, server.allocator)
	}
	delete(server.request_queue.items)
	delete(server.thread_pool)
	free(server, server.allocator)
}

// Gracefully shutdown the server, waiting for in-flight requests to complete
server_shutdown :: proc(server: ^Server) {
	if server == nil do return
	if server.shutdown do return // Already shutting down

	server.shutdown = true
	server.running = false

	// Close listener to stop accepting new connections
	net.close(server.listener)

	// Signal all worker threads to wake up and check shutdown flag
	sync.cond_broadcast(&server.queue_cond)

	// Wait for in-flight requests to complete (with timeout)
	start_time := time.now()
	for {
		active := sync.atomic_load(&server.active_requests)
		if active == 0 {
			break // All requests finished
		}

		elapsed := time.diff(start_time, time.now())
		if elapsed >= server.shutdown_timeout {
			// Timeout - force shutdown
			break
		}

		// Wait a bit before checking again
		time.sleep(10 * time.Millisecond)
	}

	// Wait for worker threads to finish
	for t in server.thread_pool {
		thread.join(t)
		thread.destroy(t)
	}
	clear(&server.thread_pool)
}

server_static :: proc(server: ^Server, dir: string, prefix := "/static/") {
	if server.static_dir != "" {
		delete(server.static_dir, server.allocator)
	}
	if server.static_prefix != "/static/" {
		delete(server.static_prefix, server.allocator)
	}
	server.static_dir = strings.clone(dir, server.allocator)
	server.static_prefix = strings.clone(prefix, server.allocator)
}

// Set a logger callback for request logging
// Use default_logger for standard stdout logging, or provide custom logger
server_set_logger :: proc(server: ^Server, logger: Logger_Callback) {
	server.logger = logger
}

server_listen_and_serve :: proc(server: ^Server) -> Error {
	if server.router == nil {
		server.router = router_create(server.allocator)
	}

	// Parse address into IP4_Address
	ip_addr: net.IP4_Address
	if server.address == "0.0.0.0" {
		ip_addr = {0, 0, 0, 0}
	} else {
		parts := strings.split(server.address, ".", context.temp_allocator)
		if len(parts) == 4 {
			for i in 0 ..< 4 {
				if val, ok := strconv.parse_int(parts[i]); ok {
					ip_addr[i] = u8(val)
				}
			}
		}
	}

	// Create TCP socket
	endpoint := net.Endpoint {
		address = ip_addr,
		port    = server.port,
	}

	socket, bind_err := net.listen_tcp(endpoint)
	if bind_err != nil {
		return .Server_Start_Failed
	}
	server.listener = socket
	server.running = true

	// Start worker threads
	for _ in 0 ..< server.pool_size {
		t := thread.create_and_start_with_data(server, worker_thread_proc)
		if t != nil {
			append(&server.thread_pool, t)
		}
	}

	// Accept loop
	for server.running {
		client, client_endpoint, accept_err := net.accept_tcp(server.listener)
		if accept_err != nil {
			if server.running {
				continue
			}
			break
		}

		// Add to queue (with backpressure — reject if queue is full)
		MAX_QUEUE_SIZE :: 1024

		task := Connection_Task {
			client_socket = client,
			client_addr   = client_endpoint,
		}

		sync.mutex_lock(&server.queue_mutex)
		if len(server.request_queue.items) >= MAX_QUEUE_SIZE {
			sync.mutex_unlock(&server.queue_mutex)
			net.close(client)
			continue
		}
		append(&server.request_queue.items, task)
		sync.cond_signal(&server.queue_cond)
		sync.mutex_unlock(&server.queue_mutex)
	}

	return .None
}

// Worker thread procedure
worker_thread_proc :: proc(data: rawptr) {
	server := cast(^Server)data

	for !server.shutdown {
		// Get task from queue
		sync.mutex_lock(&server.queue_mutex)
		for len(server.request_queue.items) == 0 && !server.shutdown {
			sync.cond_wait(&server.queue_cond, &server.queue_mutex)
		}

		if server.shutdown {
			sync.mutex_unlock(&server.queue_mutex)
			break
		}

		task := server.request_queue.items[0]
		unordered_remove(&server.request_queue.items, 0)
		sync.mutex_unlock(&server.queue_mutex)

		// Handle the connection
		handle_connection(server, task.client_socket, task.client_addr)
	}
}

// Handle a connection (supports HTTP keep-alive for multiple requests)
handle_connection :: proc(server: ^Server, client: net.TCP_Socket, addr: net.Endpoint) {
	defer free_all(context.temp_allocator)

	// Track active requests for graceful shutdown
	sync.atomic_add(&server.active_requests, 1)
	defer sync.atomic_sub(&server.active_requests, 1)

	defer net.close(client)

	// Set socket timeouts to prevent slow loris attacks
	if server.read_timeout > 0 {
		net.set_option(client, .Receive_Timeout, server.read_timeout)
	}
	if server.write_timeout > 0 {
		net.set_option(client, .Send_Timeout, server.write_timeout)
	}

	// Helper to log request
	log_request :: proc(server: ^Server, req: ^Request, res: ^Response, start: time.Time) {
		if server.logger == nil do return
		entry := Log_Entry {
			method      = req.method,
			path        = req.path,
			status      = res.status,
			duration    = time.diff(start, time.now()),
			remote_addr = req.remote_addr,
			user_agent  = req.headers["user-agent"] or_else "",
			bytes_sent  = len(res.body),
			request     = req,
		}
		server.logger(&entry)
	}

	requests_on_conn := 0

	for !server.shutdown {
		start_time := time.now()
		requests_on_conn += 1

		// After the first request, use the shorter keep-alive timeout
		if requests_on_conn > 1 && server.keep_alive_timeout > 0 {
			net.set_option(client, .Receive_Timeout, server.keep_alive_timeout)
		}

		// Fresh arena for each request
		arena: mem.Arena
		arena_buf: [64 * 1024]byte
		mem.arena_init(&arena, arena_buf[:])
		allocator := mem.arena_allocator(&arena)

		// Read request
		req, parse_err := parse_request(client, addr, server.max_request_size, allocator)
		if parse_err != .None {
			// On keep-alive connections, a socket error on read just means the
			// client closed the connection — not an error worth reporting.
			if requests_on_conn > 1 && (parse_err == .Socket_Error || parse_err == .Invalid_Request) {
				return
			}
			error_status: Status = .Bad_Request
			if parse_err == .Request_Too_Large {
				error_status = .Payload_Too_Large
			}
			send_error_response(client, error_status)
			if server.logger != nil {
				entry := Log_Entry {
					method      = .GET,
					path        = "/",
					status      = error_status,
					duration    = time.diff(start_time, time.now()),
					remote_addr = fmt.tprintf("%v", addr),
					user_agent  = "",
					bytes_sent  = 0,
				}
				server.logger(&entry)
			}
			return
		}

		// Determine if we should keep the connection alive
		// HTTP/1.1 defaults to keep-alive; HTTP/1.0 defaults to close
		keep_alive := req.version == "HTTP/1.1"
		if conn_header, has_conn := req.headers["connection"]; has_conn {
			conn_lower := strings.to_lower(conn_header, context.temp_allocator)
			if conn_lower == "keep-alive" {
				keep_alive = true
			} else if conn_lower == "close" {
				keep_alive = false
			}
		}
		if requests_on_conn >= server.max_keep_alive {
			keep_alive = false
		}

		// Create response
		res := Response {
			status    = .OK,
			headers   = make(map[string]string, 16, allocator),
			cookies   = make([dynamic]Cookie, allocator),
			body      = make([dynamic]byte),
			socket    = client,
			written   = false,
			allocator = allocator,
		}

		// Set default headers
		res.headers["Server"] = "Odin-HTTP/1.0"
		res.headers["Connection"] = "keep-alive" if keep_alive else "close"
		res.headers["X-Content-Type-Options"] = "nosniff"
		res.headers["X-Frame-Options"] = "DENY"
		res.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
		res.headers["X-Robots-Tag"] = "noindex, nofollow"
		res.headers["Content-Security-Policy"] = "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; object-src 'none'; form-action 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'"

		// Check static files first
		served_static := false
		if server.static_dir != "" && strings.has_prefix(req.path, server.static_prefix) {
			file_path := strings.trim_prefix(req.path, server.static_prefix)
			if path_contains_unsafe_chars(file_path) || strings.has_prefix(file_path, "/") {
				response_status(&res, .Forbidden)
				response_send(&res)
				log_request(server, &req, &res, start_time)
				served_static = true
			} else {
				clean_rel, clean_err := filepath.clean(file_path, context.temp_allocator)
				bad_rel_path := clean_err != nil ||
					clean_rel == "" ||
					clean_rel == "." ||
					clean_rel == ".." ||
					strings.has_prefix(clean_rel, "../") ||
					strings.has_prefix(clean_rel, "..\\") ||
					strings.has_prefix(clean_rel, "/") ||
					(len(clean_rel) >= 2 && clean_rel[1] == ':')
				if bad_rel_path {
					response_status(&res, .Forbidden)
					response_send(&res)
					log_request(server, &req, &res, start_time)
					served_static = true
				} else {
					full_path, join_err := filepath.join({server.static_dir, clean_rel}, context.temp_allocator)
					if join_err != nil {
						response_status(&res, .Forbidden)
						response_send(&res)
						log_request(server, &req, &res, start_time)
						served_static = true
					} else if serve_static_file(&res, full_path, server.static_dir) == .None {
						response_send(&res)
						log_request(server, &req, &res, start_time)
						served_static = true
					}
				}
			}
		}

		if !served_static {
			// Route the request
			route, found := router_match(server.router, &req)
			if !found {
				if server.router.not_found != nil {
					server.router.not_found(&req, &res)
				} else {
					response_status(&res, .Not_Found)
					response_html(&res, "<h1>404 Not Found</h1>")
				}
			} else if route.method != req.method {
				response_status(&res, .Method_Not_Allowed)
				response_header(&res, "Allow", method_to_string(route.method))
			} else {
				// Run middleware chain, then handler
				should_continue := true
				for mw in server.router.middleware {
					if res.written do break
					should_continue = mw(&req, &res)
					if !should_continue do break
				}
				if should_continue && !res.written {
					route.handler(&req, &res)
				}
			}

			if !res.written {
				response_send(&res)
			}
			log_request(server, &req, &res, start_time)
		}

		// If handler set Connection: close, or SSE streamed, don't reuse
		if res.streaming do keep_alive = false
		if conn_val, has := res.headers["Connection"]; has {
			if conn_val == "close" do keep_alive = false
		}

		// Clean up heap-allocated request/response bodies before next iteration
		delete(req.body)
		delete(res.body)

		// Free temp allocator each iteration — without this, temp memory
		// from fmt.tprintf, filepath.join, response_send, etc. accumulates
		// across all keep-alive requests on this connection.
		free_all(context.temp_allocator)

		if !keep_alive {
			return
		}
	}
}

// ============================================================================
// Router API
// ============================================================================

router_create :: proc(allocator := context.allocator) -> ^Router {
	router := new(Router, allocator)
	router.routes = make([dynamic]Route, allocator)
	router.middleware = make([dynamic]Middleware, allocator)
	router.allocator = allocator
	return router
}

// Add global middleware (runs for all routes in order added)
router_use :: proc(router: ^Router, mw: Middleware) {
	append(&router.middleware, mw)
}

router_destroy :: proc(router: ^Router) {
	if router == nil do return

	for &route in router.routes {
		delete(route.pattern, router.allocator)
		for seg in route.segments {
			delete(seg.value, router.allocator)
		}
		delete(route.segments, router.allocator)
	}
	delete(router.routes)
	delete(router.middleware)
	free(router, router.allocator)
}

router_add :: proc(router: ^Router, method: Method, pattern: string, handler: Handler) {
	route := Route {
		pattern  = strings.clone(pattern, router.allocator),
		method   = method,
		handler  = handler,
		segments = parse_route_pattern(pattern, router.allocator),
	}
	append(&router.routes, route)
}

router_get :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .GET, pattern, handler)
}

router_post :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .POST, pattern, handler)
}

router_put :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .PUT, pattern, handler)
}

router_delete :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .DELETE, pattern, handler)
}

router_patch :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .PATCH, pattern, handler)
}

router_head :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .HEAD, pattern, handler)
}

router_options :: proc(router: ^Router, pattern: string, handler: Handler) {
	router_add(router, .OPTIONS, pattern, handler)
}

router_not_found :: proc(router: ^Router, handler: Handler) {
	router.not_found = handler
}

// Route group — prefixes all patterns with a common path
Route_Group :: struct {
	router: ^Router,
	prefix: string,
}

router_group :: proc(router: ^Router, prefix: string) -> Route_Group {
	return Route_Group{router = router, prefix = prefix}
}

group_add :: proc(g: Route_Group, method: Method, pattern: string, handler: Handler) {
	full := strings.concatenate({g.prefix, pattern}, context.temp_allocator)
	router_add(g.router, method, full, handler)
}

group_get :: proc(g: Route_Group, pattern: string, handler: Handler) {
	group_add(g, .GET, pattern, handler)
}

group_post :: proc(g: Route_Group, pattern: string, handler: Handler) {
	group_add(g, .POST, pattern, handler)
}

group_put :: proc(g: Route_Group, pattern: string, handler: Handler) {
	group_add(g, .PUT, pattern, handler)
}

group_delete :: proc(g: Route_Group, pattern: string, handler: Handler) {
	group_add(g, .DELETE, pattern, handler)
}

group_patch :: proc(g: Route_Group, pattern: string, handler: Handler) {
	group_add(g, .PATCH, pattern, handler)
}

// Parse route pattern into segments
parse_route_pattern :: proc(pattern: string, allocator: mem.Allocator) -> []Route_Segment {
	parts := strings.split(pattern, "/", context.temp_allocator)
	segments := make([dynamic]Route_Segment, allocator)

	for part in parts {
		if len(part) == 0 do continue

		if len(part) >= 2 && part[0] == '{' && part[len(part) - 1] == '}' {
			// Parameter segment
			param_name := part[1:len(part) - 1]
			append(
				&segments,
				Route_Segment{value = strings.clone(param_name, allocator), is_param = true},
			)
		} else {
			// Literal segment
			append(
				&segments,
				Route_Segment{value = strings.clone(part, allocator), is_param = false},
			)
		}
	}

	return segments[:]
}

// Match request against routes
router_match :: proc(router: ^Router, req: ^Request) -> (^Route, bool) {
	path_parts := strings.split(req.path, "/", context.temp_allocator)

	// Filter empty parts
	path_segments: [dynamic]string
	defer delete(path_segments)
	for part in path_parts {
		if len(part) > 0 {
			append(&path_segments, part)
		}
	}

	// First pass: find exact method match
	for &route in router.routes {
		if route.method != req.method {
			continue
		}

		if len(route.segments) != len(path_segments) {
			continue
		}

		match := true
		for seg, i in route.segments {
			if seg.is_param {
				// Extract parameter
				req.params[seg.value] = path_segments[i]
			} else if seg.value != path_segments[i] {
				match = false
				break
			}
		}

		if match {
			return &route, true
		}

		// Clear params if no match
		clear(&req.params)
	}

	// Second pass: find any path match (for 405 Method Not Allowed)
	for &route in router.routes {
		if len(route.segments) != len(path_segments) {
			continue
		}

		match := true
		for seg, i in route.segments {
			if seg.is_param {
				req.params[seg.value] = path_segments[i]
			} else if seg.value != path_segments[i] {
				match = false
				break
			}
		}

		if match {
			// Path matches but method doesn't - return for 405
			return &route, true
		}

		clear(&req.params)
	}

	return nil, false
}

// ============================================================================
// Built-in Middleware
// ============================================================================

// CORS configuration
CORS_Config :: struct {
	allowed_origins:   []string, // Origins to allow (empty = allow all with "*")
	allowed_methods:   []string, // Methods to allow (default: GET, POST, PUT, DELETE, PATCH, OPTIONS)
	allowed_headers:   []string, // Headers to allow (default: Content-Type, Authorization)
	allow_credentials: bool, // Allow credentials (cookies, auth)
	max_age:           int, // Preflight cache duration in seconds (default: 86400)
}

// Default CORS config - allows all origins
CORS_DEFAULT :: CORS_Config {
	allowed_origins   = {},
	allowed_methods   = {"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"},
	allowed_headers   = {"Content-Type", "Authorization", "X-Requested-With"},
	allow_credentials = false,
	max_age           = 86400,
}

// Create CORS middleware with config — NOT IMPLEMENTED.
// Odin procs cannot capture variables, so the config cannot be stored.
// Do NOT use this; configure CORS in your reverse proxy or implement
// origin checking directly in your route handlers.
cors_middleware :: proc(config: CORS_Config) -> Middleware {
	return proc(req: ^Request, res: ^Response) -> bool {
			response_status(res, .Internal_Error)
			response_text(res, "Not implemented")
			return false
		}
}

// Simple CORS middleware - allows all origins (permissive)
cors_allow_all :: proc(req: ^Request, res: ^Response) -> bool {
	origin := req.headers["origin"] or_else "*"

	response_header(res, "Access-Control-Allow-Origin", origin)
	response_header(res, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
	response_header(
		res,
		"Access-Control-Allow-Headers",
		"Content-Type, Authorization, X-Requested-With",
	)
	response_header(res, "Access-Control-Max-Age", "86400")

	// Handle preflight OPTIONS request
	if req.method == .OPTIONS {
		response_status(res, .No_Content)
		response_send(res)
		return false // Stop chain
	}

	return true
}

// CORS middleware for specific origin(s) — NOT IMPLEMENTED.
// Odin procs cannot capture variables, so the allowed string cannot be
// stored. Do NOT use this; configure CORS in your reverse proxy or
// implement origin checking directly in your route handlers.
cors_allow_origin :: proc(allowed: string) -> Middleware {
	return proc(req: ^Request, res: ^Response) -> bool {
			response_status(res, .Internal_Error)
			response_text(res, "Not implemented")
			return false
		}
}

// Basic authentication middleware — NOT IMPLEMENTED.
// Odin procs cannot capture variables, so the check_credentials callback
// cannot be stored. Do NOT use this; implement auth checks directly in
// your route handlers instead.
basic_auth_middleware :: proc(check_credentials: proc(user, pass: string) -> bool) -> Middleware {
	return proc(req: ^Request, res: ^Response) -> bool {
			response_status(res, .Internal_Error)
			response_text(res, "Not implemented")
			return false
		}
}

// Request ID middleware - adds X-Request-ID header
request_id_middleware :: proc(req: ^Request, res: ^Response) -> bool {
	// Generate simple request ID from timestamp
	id := fmt.tprintf("req-%d", time.to_unix_nanoseconds(time.now()))
	response_header(res, "X-Request-ID", id)
	return true
}

// ============================================================================
// Request Helpers
// ============================================================================

request_param :: proc(req: ^Request, name: string) -> (string, bool) {
	if val, ok := req.params[name]; ok {
		return val, true
	}
	return "", false
}

request_query :: proc(req: ^Request, name: string) -> (string, bool) {
	if val, ok := req.query[name]; ok {
		return val, true
	}
	return "", false
}

request_header :: proc(req: ^Request, name: string) -> (string, bool) {
	// Headers are stored lowercase, so normalize the lookup key
	lower_name := strings.to_lower(name, context.temp_allocator)
	if val, ok := req.headers[lower_name]; ok {
		return val, true
	}
	return "", false
}

request_cookie :: proc(req: ^Request, name: string) -> (string, bool) {
	if val, ok := req.cookies[name]; ok {
		return val, true
	}
	return "", false
}

request_form :: proc(req: ^Request, name: string) -> (string, bool) {
	// Parse body as form data if not already done
	content_type, _ := request_header(req, "Content-Type")
	if !strings.has_prefix(content_type, "application/x-www-form-urlencoded") {
		return "", false
	}

	form := parse_query_string(string(req.body), context.temp_allocator)
	if val, ok := form[name]; ok {
		return val, true
	}
	return "", false
}

request_form_all :: proc(req: ^Request) -> (map[string]string, bool) {
	content_type, _ := request_header(req, "Content-Type")
	if !strings.has_prefix(content_type, "application/x-www-form-urlencoded") {
		return {}, false
	}
	return parse_query_string(string(req.body), context.temp_allocator), true
}

// Parse a string as a boolean. Returns true for "true", "1", "on", "yes" (case-insensitive).
form_bool :: proc(val: string) -> bool {
	lower := strings.to_lower(strings.trim_space(val), context.temp_allocator)
	return lower == "true" || lower == "1" || lower == "on" || lower == "yes"
}

request_body_string :: proc(req: ^Request) -> string {
	return string(req.body)
}

// ============================================================================
// Multipart Form Parsing
// ============================================================================

Multipart_File :: struct {
	field_name:   string, // form field name (e.g. "fn")
	filename:     string, // original filename
	content_type: string, // MIME type from Content-Type header
	data:         []byte, // raw file bytes (references req.body — valid for request lifetime)
}

Multipart_Form :: struct {
	fields: map[string]string,
	files:  [dynamic]Multipart_File,
}

// Parse multipart/form-data request body. Returns form fields and file uploads.
// All data references the original req.body and is valid for the request lifetime.
request_multipart :: proc(req: ^Request) -> (Multipart_Form, bool) {
	content_type, _ := request_header(req, "Content-Type")
	if !strings.has_prefix(content_type, "multipart/form-data") {
		return {}, false
	}

	// Extract boundary from Content-Type header
	boundary := ""
	if idx := strings.index(content_type, "boundary="); idx >= 0 {
		boundary = content_type[idx + 9:]
		// Trim surrounding quotes if present
		if len(boundary) > 1 && boundary[0] == '"' {
			if end := strings.index(boundary[1:], "\""); end >= 0 {
				boundary = boundary[1:end + 1]
			}
		}
	}
	if len(boundary) == 0 {
		return {}, false
	}

	form := Multipart_Form {
		fields = make(map[string]string, 16, context.temp_allocator),
		files  = make([dynamic]Multipart_File, 0, 4, context.temp_allocator),
	}

	delimiter := fmt.tprintf("--%s", boundary)
	body := req.body

	// Find each part by scanning for the delimiter in the raw bytes
	delim_bytes := transmute([]byte)delimiter
	crlf := [2]byte{'\r', '\n'}

	// Skip preamble — find first delimiter
	pos := bytes_index(body, delim_bytes)
	if pos < 0 {
		return form, true
	}
	pos += len(delim_bytes)

	for pos < len(body) {
		// Check for closing delimiter (--)
		if pos + 2 <= len(body) && body[pos] == '-' && body[pos + 1] == '-' {
			break
		}

		// Skip \r\n after delimiter
		if pos + 2 <= len(body) && body[pos] == '\r' && body[pos + 1] == '\n' {
			pos += 2
		}

		// Find end of headers (blank line: \r\n\r\n)
		header_start := pos
		header_end := -1
		for i in header_start ..< len(body) - 3 {
			if body[i] == '\r' && body[i + 1] == '\n' && body[i + 2] == '\r' && body[i + 3] == '\n' {
				header_end = i
				break
			}
		}
		if header_end < 0 {
			break
		}

		headers_str := string(body[header_start:header_end])
		body_start := header_end + 4

		// Find next delimiter to determine body end
		next_delim := bytes_index(body[body_start:], delim_bytes)
		if next_delim < 0 {
			break
		}

		body_end := body_start + next_delim
		// Trim trailing \r\n before delimiter
		if body_end >= 2 && body[body_end - 2] == '\r' && body[body_end - 1] == '\n' {
			body_end -= 2
		}

		part_body := body[body_start:body_end]

		// Parse headers for Content-Disposition and Content-Type
		name := ""
		filename := ""
		part_content_type := ""

		for line in strings.split(headers_str, "\r\n", context.temp_allocator) {
			lower_line := strings.to_lower(line, context.temp_allocator)
			if strings.has_prefix(lower_line, "content-disposition:") {
				if name_idx := strings.index(line, "name=\""); name_idx >= 0 {
					rest := line[name_idx + 6:]
					if end_quote := strings.index(rest, "\""); end_quote >= 0 {
						name = rest[:end_quote]
					}
				}
				if fn_idx := strings.index(line, "filename=\""); fn_idx >= 0 {
					rest := line[fn_idx + 10:]
					if end_quote := strings.index(rest, "\""); end_quote >= 0 {
						filename = rest[:end_quote]
					}
				}
			} else if strings.has_prefix(lower_line, "content-type:") {
				part_content_type = strings.trim_space(line[13:])
			}
		}

		if len(name) > 0 {
			if len(filename) > 0 {
				append(&form.files, Multipart_File {
					field_name   = name,
					filename     = filename,
					content_type = part_content_type,
					data         = part_body,
				})
			} else {
				form.fields[name] = string(part_body)
			}
		}

		// Advance past part body and delimiter
		pos = body_start + next_delim + len(delim_bytes)
	}

	return form, true
}

// Get a text field value from a multipart form
multipart_field :: proc(form: ^Multipart_Form, name: string) -> (string, bool) {
	if val, ok := form.fields[name]; ok {
		return val, true
	}
	return "", false
}

// Get a file upload from a multipart form by field name
multipart_file :: proc(form: ^Multipart_Form, name: string) -> (^Multipart_File, bool) {
	for &f in form.files {
		if f.field_name == name {
			return &f, true
		}
	}
	return nil, false
}

// Find index of needle in haystack (byte-level search)
@(private = "file")
bytes_index :: proc(haystack: []byte, needle: []byte) -> int {
	if len(needle) == 0 do return 0
	if len(needle) > len(haystack) do return -1
	for i in 0 ..= len(haystack) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match do return i
	}
	return -1
}

// Parse request body as JSON into a struct.
// Returns false if the body is empty or parsing fails.
// String fields in the result reference the original req.body bytes (zero-copy),
// so the result is valid for the lifetime of the request.
request_json :: proc(req: ^Request, $T: typeid) -> (result: T, ok: bool) {
	if len(req.body) == 0 {
		return {}, false
	}

	err := json.unmarshal(req.body, &result)
	if err != nil {
		return {}, false
	}

	return result, true
}

request_destroy :: proc(req: ^Request) {
	delete(req.headers)
	delete(req.cookies)
	delete(req.params)
	delete(req.query)
	delete(req.body)
}

// ============================================================================
// Response Helpers
// ============================================================================

response_status :: proc(res: ^Response, status: Status) {
	res.status = status
}

response_header :: proc(res: ^Response, name, value: string) {
	// Prevent header injection — strip CR/LF from both name and value
	clean_name := name
	if strings.contains_any(name, "\r\n") {
		cn, _ := strings.replace_all(name, "\r", "", context.temp_allocator)
		clean_name, _ = strings.replace_all(cn, "\n", "", context.temp_allocator)
	}
	if strings.contains_any(value, "\r\n") {
		clean, _ := strings.replace_all(value, "\r", "", context.temp_allocator)
		clean2, _ := strings.replace_all(clean, "\n", "", context.temp_allocator)
		res.headers[clean_name] = clean2
	} else {
		res.headers[clean_name] = value
	}
}

response_write :: proc(res: ^Response, data: []byte) {
	append(&res.body, ..data)
}

response_write_string :: proc(res: ^Response, data: string) {
	append(&res.body, ..transmute([]byte)data)
}

response_html :: proc(res: ^Response, html: string) {
	res.headers["Content-Type"] = "text/html; charset=utf-8"
	append(&res.body, ..transmute([]byte)html)
}

response_text :: proc(res: ^Response, text: string) {
	res.headers["Content-Type"] = "text/plain; charset=utf-8"
	append(&res.body, ..transmute([]byte)text)
}

response_json :: proc(res: ^Response, data: $T) {
	res.headers["Content-Type"] = "application/json"

	// Try to marshal to JSON
	json_data, err := json.marshal(data, allocator = context.temp_allocator)
	if err == nil {
		append(&res.body, ..json_data)
	} else {
		append(&res.body, ..transmute([]byte)string("{\"error\": \"JSON serialization failed\"}"))
	}
}

response_json_string :: proc(res: ^Response, json_str: string) {
	res.headers["Content-Type"] = "application/json"
	append(&res.body, ..transmute([]byte)json_str)
}

response_redirect :: proc(res: ^Response, url: string, status: Status = .Found) {
	res.status = status
	response_header(res, "Location", url)
}

response_file :: proc(res: ^Response, path: string) -> Error {
	return serve_static_file(res, path)
}

// Send bytes as a downloadable file
// content_type examples: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" for .xlsx
//                        "text/csv" for .csv
//                        "application/pdf" for .pdf
response_download :: proc(res: ^Response, data: []byte, filename: string, content_type: string) {
	// Sanitize filename — strip quotes and path separators to prevent header injection
	clean_fn := filename
	if strings.contains_any(filename, "\"\\/:") {
		clean, _ := strings.replace_all(filename, "\"", "", context.temp_allocator)
		clean2, _ := strings.replace_all(clean, "\\", "", context.temp_allocator)
		clean3, _ := strings.replace_all(clean2, "/", "", context.temp_allocator)
		clean_fn, _ = strings.replace_all(clean3, ":", "", context.temp_allocator)
	}
	response_header(res, "Content-Type", content_type)
	response_header(res, "Content-Disposition", fmt.tprintf(`attachment; filename="%s"`, clean_fn))
	response_write(res, data)
}

// Convenience function for XLSX downloads
response_xlsx :: proc(res: ^Response, data: []byte, filename: string) {
	response_download(
		res,
		data,
		filename,
		"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	)
}

// Convenience function for CSV downloads
response_csv :: proc(res: ^Response, data: []byte, filename: string) {
	response_download(res, data, filename, "text/csv; charset=utf-8")
}

response_cookie :: proc(res: ^Response, cookie: Cookie) {
	append(&res.cookies, cookie)
}

response_send :: proc(res: ^Response) {
	if res.written do return
	res.written = true

	builder := strings.builder_make(context.temp_allocator)

	// Status line
	fmt.sbprintf(&builder, "HTTP/1.1 %d %s\r\n", int(res.status), status_text(res.status))

	// Content-Length header
	fmt.sbprintf(&builder, "Content-Length: %d\r\n", len(res.body))

	// Headers
	for name, value in res.headers {
		fmt.sbprintf(&builder, "%s: %s\r\n", name, value)
	}

	// Cookies (sanitize all string fields to prevent CRLF injection)
	cookie_sanitize :: proc(s: string) -> string {
		if strings.contains_any(s, "\r\n;") {
			clean, _ := strings.replace_all(s, "\r", "", context.temp_allocator)
			clean2, _ := strings.replace_all(clean, "\n", "", context.temp_allocator)
			clean3, _ := strings.replace_all(clean2, ";", "", context.temp_allocator)
			return clean3
		}
		return s
	}
	for cookie in res.cookies {
		fmt.sbprintf(&builder, "Set-Cookie: %s=%s", cookie_sanitize(cookie.name), cookie_sanitize(cookie.value))
		if cookie.path != "" {
			fmt.sbprintf(&builder, "; Path=%s", cookie_sanitize(cookie.path))
		}
		if cookie.domain != "" {
			fmt.sbprintf(&builder, "; Domain=%s", cookie_sanitize(cookie.domain))
		}
		if cookie.max_age > 0 {
			fmt.sbprintf(&builder, "; Max-Age=%d", cookie.max_age)
		}
		if cookie.secure {
			fmt.sbprint(&builder, "; Secure")
		}
		if cookie.http_only {
			fmt.sbprint(&builder, "; HttpOnly")
		}
		switch cookie.same_site {
		case .Strict:
			fmt.sbprint(&builder, "; SameSite=Strict")
		case .Lax:
			fmt.sbprint(&builder, "; SameSite=Lax")
		case .None:
			fmt.sbprint(&builder, "; SameSite=None")
		case .Default:
		// Don't add SameSite
		}
		fmt.sbprint(&builder, "\r\n")
	}

	// End of headers
	fmt.sbprint(&builder, "\r\n")

	// Append body to the same buffer and send everything in one syscall
	if len(res.body) > 0 {
		strings.write_bytes(&builder, res.body[:])
	}
	full_response := transmute([]byte)strings.to_string(builder)
	_send_all(res.socket, full_response)
}

// Send all bytes to socket, retrying partial writes. Returns false on failure.
@(private)
_send_all :: proc(socket: net.TCP_Socket, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		sent, send_err := net.send_tcp(socket, remaining)
		if send_err != nil {
			return false
		}
		if sent <= 0 {
			return false
		}
		remaining = remaining[sent:]
	}
	return true
}

// ============================================================================
// Server-Sent Events (SSE)
// ============================================================================

// Start an SSE stream. Sets required headers, flushes them to the socket,
// and marks the response as streaming. After calling this, use sse_event()
// to send events. The connection stays open until the handler returns.
// Returns false if the header flush failed (client already disconnected).
sse_start :: proc(res: ^Response) -> bool {
	if res.written do return false

	// Disable Nagle's algorithm so each event is sent immediately
	net.set_option(res.socket, .TCP_Nodelay, true)

	res.headers["Content-Type"] = "text/event-stream"
	res.headers["Cache-Control"] = "no-cache"
	res.headers["Connection"] = "keep-alive"

	// Flush headers to socket
	if !_sse_flush_headers(res) {
		return false
	}

	res.streaming = true
	res.headers_sent = true
	res.written = true // Prevent response_send() from firing
	return true
}

// Send an SSE event to the client. Returns false if the send failed
// (client disconnected), so the handler knows to stop.
sse_event :: proc(res: ^Response, data: string, event: string = "", id: string = "") -> bool {
	if !res.streaming do return false

	// Stack-local arena so nothing leaks into temp_allocator across a long-lived stream.
	// 64KB covers any realistic SSE event; if exceeded the arena returns nil
	// and the payload will be truncated — log a warning so it doesn't go unnoticed.
	buf: [64 * 1024]byte
	local_arena: mem.Arena
	mem.arena_init(&local_arena, buf[:])
	alloc := mem.arena_allocator(&local_arena)

	builder := strings.builder_make(alloc)

	if len(id) > 0 {
		fmt.sbprintf(&builder, "id: %s\n", id)
	}
	if len(event) > 0 {
		fmt.sbprintf(&builder, "event: %s\n", event)
	}

	// Split data on newlines — SSE spec requires each line prefixed with "data: "
	lines := strings.split(data, "\n", alloc)
	for line in lines {
		fmt.sbprintf(&builder, "data: %s\n", line)
	}

	// Empty line terminates the event
	fmt.sbprint(&builder, "\n")

	payload := transmute([]byte)strings.to_string(builder)
	if len(payload) == 0 && len(data) > 0 {
		fmt.eprintln("[HTTP/SSE] WARNING: arena exhausted — SSE event truncated. Data length:", len(data))
	}
	return _send_all(res.socket, payload)
}

// Send an SSE comment (keep-alive ping). Returns false on send failure.
sse_comment :: proc(res: ^Response, text: string = "") -> bool {
	if !res.streaming do return false

	// Stack-local arena so nothing leaks into temp_allocator
	buf: [1024]byte
	local_arena: mem.Arena
	mem.arena_init(&local_arena, buf[:])
	alloc := mem.arena_allocator(&local_arena)

	builder := strings.builder_make(alloc)
	if len(text) > 0 {
		fmt.sbprintf(&builder, ": %s\n\n", text)
	} else {
		fmt.sbprint(&builder, ":\n\n")
	}

	payload := transmute([]byte)strings.to_string(builder)
	return _send_all(res.socket, payload)
}

// Internal: flush response headers to the socket for SSE
_sse_flush_headers :: proc(res: ^Response) -> bool {
	builder := strings.builder_make(context.temp_allocator)

	fmt.sbprintf(&builder, "HTTP/1.1 %d %s\r\n", int(res.status), status_text(res.status))

	for name, value in res.headers {
		fmt.sbprintf(&builder, "%s: %s\r\n", name, value)
	}

	// Reuse same cookie sanitizer as response_send
	sse_cookie_sanitize :: proc(s: string) -> string {
		if strings.contains_any(s, "\r\n;") {
			clean, _ := strings.replace_all(s, "\r", "", context.temp_allocator)
			clean2, _ := strings.replace_all(clean, "\n", "", context.temp_allocator)
			clean3, _ := strings.replace_all(clean2, ";", "", context.temp_allocator)
			return clean3
		}
		return s
	}
	for cookie in res.cookies {
		fmt.sbprintf(&builder, "Set-Cookie: %s=%s", sse_cookie_sanitize(cookie.name), sse_cookie_sanitize(cookie.value))
		if cookie.path != "" {
			fmt.sbprintf(&builder, "; Path=%s", sse_cookie_sanitize(cookie.path))
		}
		if cookie.domain != "" {
			fmt.sbprintf(&builder, "; Domain=%s", sse_cookie_sanitize(cookie.domain))
		}
		if cookie.max_age > 0 {
			fmt.sbprintf(&builder, "; Max-Age=%d", cookie.max_age)
		}
		if cookie.secure {
			fmt.sbprint(&builder, "; Secure")
		}
		if cookie.http_only {
			fmt.sbprint(&builder, "; HttpOnly")
		}
		switch cookie.same_site {
		case .Strict:
			fmt.sbprint(&builder, "; SameSite=Strict")
		case .Lax:
			fmt.sbprint(&builder, "; SameSite=Lax")
		case .None:
			fmt.sbprint(&builder, "; SameSite=None")
		case .Default:
		}
		fmt.sbprint(&builder, "\r\n")
	}

	fmt.sbprint(&builder, "\r\n")

	header_data := transmute([]byte)strings.to_string(builder)
	return _send_all(res.socket, header_data)
}

// ============================================================================
// Session API
// ============================================================================

session_store_create :: proc(
	ttl: time.Duration = time.Hour,
	cookie_name: string = "session_id",
	secure: bool = true,
	allocator := context.allocator,
) -> ^Session_Store {
	store := new(Session_Store, allocator)
	store.sessions = make(map[string]^Session, 64, allocator)
	store.ttl = ttl
	store.cookie_name = strings.clone(cookie_name, allocator)
	store.secure = secure
	store.allocator = allocator
	return store
}

session_store_destroy :: proc(store: ^Session_Store) {
	if store == nil do return

	sync.mutex_lock(&store.mutex)

	for _, session in store.sessions {
		for k, v in session.data {
			delete(k, store.allocator)
			delete(v, store.allocator)
		}
		delete(session.data)
		delete(session.id, store.allocator)
		free(session, store.allocator)
	}
	delete(store.sessions)
	delete(store.cookie_name, store.allocator)

	// Unlock before freeing the store — defer would use-after-free on the mutex
	sync.mutex_unlock(&store.mutex)
	free(store, store.allocator)
}

session_count :: proc(store: ^Session_Store) -> int {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	return len(store.sessions)
}

// Look up an existing valid session without creating one or setting cookies.
session_get_existing :: proc(store: ^Session_Store, req: ^Request) -> (^Session, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	if session_id, ok := request_cookie(req, store.cookie_name); ok {
		if session, found := store.sessions[session_id]; found {
			if time.diff(time.now(), session.expires_at) > 0 {
				return session, true
			}
			session_destroy_internal(store, session)
		}
	}
	return nil, false
}

session_get :: proc(store: ^Session_Store, req: ^Request, res: ^Response) -> ^Session {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	// Check for existing session cookie
	if session_id, ok := request_cookie(req, store.cookie_name); ok {
		if session, found := store.sessions[session_id]; found {
			// Check if expired
			if time.diff(time.now(), session.expires_at) > 0 {
				return session
			}
			// Session expired, remove it
			session_destroy_internal(store, session)
		}
	}

	// Create new session
	session := new(Session, store.allocator)
	session.id = generate_session_id(store.allocator)
	session.data = make(map[string]string, 16, store.allocator)
	session.created_at = time.now()
	session.expires_at = time.time_add(time.now(), store.ttl)
	session.allocator = store.allocator

	store.sessions[session.id] = session

	// Set session cookie (secure defaults)
	response_cookie(
		res,
		Cookie {
			name      = store.cookie_name,
			value     = session.id,
			path      = "/",
			http_only = true,
			secure    = store.secure,
			same_site = .Strict,
			max_age   = int(time.duration_seconds(store.ttl)),
		},
	)

	return session
}

session_set :: proc(session: ^Session, key, value: string) {
	sync.mutex_lock(&session.mutex)
	defer sync.mutex_unlock(&session.mutex)
	if old_val, exists := session.data[key]; exists {
		delete(old_val, session.allocator)
		session.data[key] = strings.clone(value, session.allocator)
	} else {
		session.data[strings.clone(key, session.allocator)] = strings.clone(
			value,
			session.allocator,
		)
	}
}

session_value :: proc(session: ^Session, key: string) -> (string, bool) {
	sync.mutex_lock(&session.mutex)
	defer sync.mutex_unlock(&session.mutex)
	if val, ok := session.data[key]; ok {
		return val, true
	}
	return "", false
}

session_delete :: proc(session: ^Session, key: string) {
	sync.mutex_lock(&session.mutex)
	defer sync.mutex_unlock(&session.mutex)
	if val, ok := session.data[key]; ok {
		// Save the stored key so we can free it after removal
		stored_key: string
		for k, _ in session.data {
			if k == key {
				stored_key = k
				break
			}
		}
		delete_key(&session.data, key)
		delete(stored_key, session.allocator)
		delete(val, session.allocator)
	}
}

// Regenerate session ID to prevent session fixation attacks.
// Keeps all existing session data but issues a new ID and cookie.
session_regenerate :: proc(store: ^Session_Store, session: ^Session, res: ^Response) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	// Remove old ID from store
	delete_key(&store.sessions, session.id)
	delete(session.id, store.allocator)

	// Assign new ID
	session.id = generate_session_id(store.allocator)
	session.created_at = time.now()
	session.expires_at = time.time_add(time.now(), store.ttl)
	store.sessions[session.id] = session

	// Set new cookie
	response_cookie(
		res,
		Cookie {
			name      = store.cookie_name,
			value     = session.id,
			path      = "/",
			http_only = true,
			secure    = store.secure,
			same_site = .Strict,
			max_age   = int(time.duration_seconds(store.ttl)),
		},
	)
}

session_destroy :: proc(store: ^Session_Store, session: ^Session, res: ^Response) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	session_destroy_internal(store, session)

	// Clear the cookie
	response_cookie(
		res,
		Cookie {
			name      = store.cookie_name,
			value     = "",
			path      = "/",
			max_age   = -1,
			http_only = true,
			secure    = store.secure,
			same_site = .Strict,
		},
	)
}

session_destroy_internal :: proc(store: ^Session_Store, session: ^Session) {
	delete_key(&store.sessions, session.id)
	for k, v in session.data {
		delete(k, store.allocator)
		delete(v, store.allocator)
	}
	delete(session.data)
	delete(session.id, store.allocator)
	free(session, store.allocator)
}

// Destroy all sessions for a given user ID. Useful for forcing logout
// on password change or when an admin revokes access.
// Returns the number of sessions destroyed.
session_destroy_by_value :: proc(store: ^Session_Store, key: string, value: string) -> int {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	to_remove: [dynamic]string
	defer delete(to_remove)

	for id, session in store.sessions {
		sync.mutex_lock(&session.mutex)
		val, has := session.data[key]
		match := has && val == value
		sync.mutex_unlock(&session.mutex)
		if match {
			append(&to_remove, id)
		}
	}

	for id in to_remove {
		if session, ok := store.sessions[id]; ok {
			session_destroy_internal(store, session)
		}
	}

	return len(to_remove)
}

// Clean up expired sessions (call periodically)
session_cleanup :: proc(store: ^Session_Store) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	now := time.now()
	expired: [dynamic]string
	defer delete(expired)

	for id, session in store.sessions {
		if time.diff(now, session.expires_at) <= 0 {
			append(&expired, id)
		}
	}

	for id in expired {
		if session, ok := store.sessions[id]; ok {
			session_destroy_internal(store, session)
		}
	}
}

// Generate secure session ID
generate_session_id :: proc(allocator: mem.Allocator) -> string {
	// Use cryptographically secure random bytes from system entropy source
	random_bytes: [32]byte
	crypto.rand_bytes(random_bytes[:])

	// Hex encode — always cookie-safe (no +, /, = characters)
	HEX := "0123456789abcdef"
	buf := make([]byte, 64, allocator)
	for i in 0 ..< 32 {
		buf[i * 2] = HEX[random_bytes[i] >> 4]
		buf[i * 2 + 1] = HEX[random_bytes[i] & 0xf]
	}
	return string(buf)
}

// ============================================================================
// Session Persistence
// ============================================================================

// Intermediate struct used for JSON serialisation only.
Session_File_Entry :: struct {
	id:         string,
	data:       map[string]string,
	created_ns: i64, // time.Time._nsec (nanoseconds since internal epoch)
	expires_ns: i64,
}

// Write all live (non-expired) sessions to a JSON file.
session_save_to_file :: proc(store: ^Session_Store, filename: string) -> bool {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	entries := make([dynamic]Session_File_Entry)
	defer delete(entries)

	now := time.now()
	for _, session in store.sessions {
		if time.diff(now, session.expires_at) <= 0 do continue // skip already-expired
		sync.mutex_lock(&session.mutex)
		has_user := "user_id" in session.data
		if has_user {
			append(
				&entries,
				Session_File_Entry {
					id = session.id,
					data = session.data,
					created_ns = transmute(i64)session.created_at,
					expires_ns = transmute(i64)session.expires_at,
				},
			)
		}
		sync.mutex_unlock(&session.mutex)
	}

	data, err := json.marshal(entries[:])
	if err != nil do return false
	defer delete(data)

	// Atomic write: write to temp file then rename, so a crash mid-write
	// doesn't corrupt the session file and invalidate all sessions on restart.
	tmp_filename := strings.concatenate({filename, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp_filename, data) != nil do return false
	if os.rename(tmp_filename, filename) != nil {
		os.remove(tmp_filename)
		return false
	}
	return true
}

// Load sessions from a JSON file into the store, skipping any that are expired.
// Existing sessions with the same ID are overwritten.
session_load_from_file :: proc(store: ^Session_Store, filename: string) -> bool {
	raw, err := os.read_entire_file(filename, context.allocator)
	if err != nil do return false
	defer delete(raw)

	entries: [dynamic]Session_File_Entry
	if err := json.unmarshal(raw, &entries); err != nil do return false
	defer {
		for &e in entries {
			delete(e.id)
			for k, v in e.data {
				delete(k)
				delete(v)
			}
			delete(e.data)
		}
		delete(entries)
	}

	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)

	now := time.now()
	for e in entries {
		expires_at := transmute(time.Time)e.expires_ns
		if time.diff(now, expires_at) <= 0 do continue // skip expired

		session := new(Session, store.allocator)
		session.id = strings.clone(e.id, store.allocator)
		session.data = make(map[string]string, 16, store.allocator)
		session.created_at = transmute(time.Time)e.created_ns
		session.expires_at = expires_at
		session.allocator = store.allocator

		for k, v in e.data {
			session.data[strings.clone(k, store.allocator)] = strings.clone(v, store.allocator)
		}

		store.sessions[session.id] = session
	}

	return true
}

// ============================================================================
// Template System
// ============================================================================

Template :: struct {
	content:   string,
	nodes:     [dynamic]Template_Node,
	allocator: mem.Allocator,
}

Partial_Node :: struct {
	name: string, // Template name to include, e.g. "header.ohtml"
}

Template_Node :: union {
	Text_Node,
	Variable_Node,
	If_Node,
	Each_Node,
	Unless_Node,
	Partial_Node,
}

Text_Node :: struct {
	text: string,
}

// Filter for template variables: {{name | upper}} or {{due | date}}
Template_Filter :: struct {
	name: string, // e.g., "date", "time", "upper", "lower", "raw"
	arg:  string, // optional argument for format filters
}

Variable_Node :: struct {
	name:    string,
	filters: [dynamic]Template_Filter, // chain of filters
}

// Condition for if/elseif: supports "var", "var == value", "var != value", "var > 5", etc.
Template_Condition :: struct {
	left:     string, // variable name
	operator: string, // "", "==", "!=", ">", "<", ">=", "<="
	right:    string, // comparison value (empty for boolean check)
}

// Elseif branch
Elseif_Branch :: struct {
	condition: Template_Condition,
	body:      [dynamic]Template_Node,
}

If_Node :: struct {
	condition:       Template_Condition,
	body:            [dynamic]Template_Node,
	elseif_branches: [dynamic]Elseif_Branch,
	else_body:       [dynamic]Template_Node,
}

Each_Node :: struct {
	list_name: string,
	body:      [dynamic]Template_Node,
}

Unless_Node :: struct {
	condition: string,
	body:      [dynamic]Template_Node,
}

Template_Context :: struct {
	values:     map[string]string,
	lists:      map[string][]^Template_Context,
	bools:      map[string]bool,
	raw_values: map[string]any, // Original values for filters (e.g., pg.Timestamp)
}

Template_Set :: struct {
	templates: map[string]^Template,
	allocator: mem.Allocator,
}

path_contains_unsafe_chars :: proc(path: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.contains(path, "\x00")
	} else {
		return strings.contains(path, "\\") || strings.contains(path, "\x00")
	}
}

path_is_within_root_resolved :: proc(root_path, target_path: string) -> bool {
	root_info, root_err := os.stat(root_path, context.temp_allocator)
	if root_err != os.ERROR_NONE {
		return false
	}
	defer os.file_info_delete(root_info, context.temp_allocator)
	if root_info.type != .Directory {
		return false
	}

	target_info, target_err := os.stat(target_path, context.temp_allocator)
	if target_err != os.ERROR_NONE {
		return false
	}
	defer os.file_info_delete(target_info, context.temp_allocator)

	root_clean, root_clean_err := filepath.clean(root_info.fullpath, context.temp_allocator)
	target_clean, target_clean_err := filepath.clean(target_info.fullpath, context.temp_allocator)
	if root_clean_err != nil || target_clean_err != nil {
		return false
	}

	sep := "/" when ODIN_OS != .Windows else "\\"
	if root_clean == "/" || root_clean == "\\" {
		return strings.has_prefix(target_clean, root_clean)
	}

	root_prefix := strings.concatenate({root_clean, sep}, context.temp_allocator)
	return target_clean == root_clean || strings.has_prefix(target_clean, root_prefix)
}

// Load a single template from file
template_load :: proc(path: string, allocator := context.allocator) -> (^Template, Error) {
	if path_contains_unsafe_chars(path) {
		return nil, .File_Not_Found
	}

	clean_path, clean_err := filepath.clean(path, context.temp_allocator)
	if clean_err != nil || !path_is_within_root_resolved(".", clean_path) {
		return nil, .File_Not_Found
	}

	content, err := os.read_entire_file(clean_path, context.temp_allocator)
	if err != nil {
		return nil, .File_Not_Found
	}

	return template_parse(string(content), allocator)
}

// Parse template from string
template_parse :: proc(content: string, allocator := context.allocator) -> (^Template, Error) {
	tpl := new(Template, allocator)
	tpl.content = strings.clone(content, allocator)
	tpl.nodes = make([dynamic]Template_Node, allocator)
	tpl.allocator = allocator

	parse_template_nodes(content, &tpl.nodes, allocator)

	return tpl, .None
}

// Parse a condition string like "var", "var == value", "status != 'active'"
parse_condition :: proc(cond_str: string, allocator: mem.Allocator) -> Template_Condition {
	cond := strings.trim_space(cond_str)

	// Try each operator (longest first to match >= before >)
	operators := []string{"==", "!=", ">=", "<=", ">", "<"}
	for op in operators {
		if idx := strings.index(cond, op); idx != -1 {
			left := strings.trim_space(cond[:idx])
			right := strings.trim_space(cond[idx + len(op):])
			// Remove quotes from right side if present
			if len(right) >= 2 {
				if (right[0] == '"' && right[len(right) - 1] == '"') ||
				   (right[0] == '\'' && right[len(right) - 1] == '\'') {
					right = right[1:len(right) - 1]
				}
			}
			return Template_Condition {
				left = strings.clone(left, allocator),
				operator = op,
				right = strings.clone(right, allocator),
			}
		}
	}

	// No operator, just a boolean check
	return Template_Condition{left = strings.clone(cond, allocator), operator = "", right = ""}
}

// Parse a variable with optional filters: "name | upper | truncate 50"
parse_variable_with_filters :: proc(expr: string, allocator: mem.Allocator) -> Variable_Node {
	parts := strings.split(expr, "|")
	defer delete(parts)

	node := Variable_Node {
		name    = strings.clone(strings.trim_space(parts[0]), allocator),
		filters = make([dynamic]Template_Filter, allocator),
	}

	// Parse each filter
	for i := 1; i < len(parts); i += 1 {
		filter_str := strings.trim_space(parts[i])
		if len(filter_str) == 0 do continue

		// Split filter name and argument
		space_idx := strings.index(filter_str, " ")
		filter := Template_Filter{}
		if space_idx != -1 {
			filter.name = strings.clone(filter_str[:space_idx], allocator)
			arg := strings.trim_space(filter_str[space_idx + 1:])
			// Remove quotes if present
			if len(arg) >= 2 {
				if (arg[0] == '"' && arg[len(arg) - 1] == '"') ||
				   (arg[0] == '\'' && arg[len(arg) - 1] == '\'') {
					arg = arg[1:len(arg) - 1]
				}
			}
			filter.arg = strings.clone(arg, allocator)
		} else {
			filter.name = strings.clone(filter_str, allocator)
			filter.arg = ""
		}
		append(&node.filters, filter)
	}

	return node
}

// Parse the body of an if block, handling elseif and else
parse_if_body :: proc(content: string, if_node: ^If_Node, allocator: mem.Allocator) {
	// Split content at elseif and else boundaries (respecting nesting)
	// Returns slices of content for: main body, [elseif bodies...], else body

	sections := make([dynamic]string, context.temp_allocator)
	section_types := make([dynamic]int, context.temp_allocator) // 0=main, 1=elseif, 2=else
	elseif_conditions := make([dynamic]string, context.temp_allocator)

	append(&sections, "")
	append(&section_types, 0) // main body

	pos := 0
	section_start := 0
	depth := 0

	for pos < len(content) {
		// Find next tag
		tag_start := strings.index(content[pos:], "{{")
		if tag_start == -1 do break

		abs_pos := pos + tag_start
		tag_end := strings.index(content[abs_pos:], "}}")
		if tag_end == -1 do break

		tag_content := strings.trim_space(content[abs_pos + 2:abs_pos + tag_end])

		// Track nesting depth
		if strings.has_prefix(tag_content, "#if ") {
			depth += 1
			pos = abs_pos + tag_end + 2
			continue
		} else if tag_content == "/if" {
			if depth > 0 {
				depth -= 1
			}
			pos = abs_pos + tag_end + 2
			continue
		}

		// Only process elseif/else at depth 0
		if depth == 0 {
			if strings.has_prefix(tag_content, "#elseif ") {
				// Save current section
				sections[len(sections) - 1] = content[section_start:abs_pos]

				// Start new elseif section
				condition_str := strings.trim_space(tag_content[8:])
				append(&elseif_conditions, condition_str)
				append(&sections, "")
				append(&section_types, 1)

				section_start = abs_pos + tag_end + 2
				pos = section_start
				continue

			} else if tag_content == "else" {
				// Save current section
				sections[len(sections) - 1] = content[section_start:abs_pos]

				// Start else section
				append(&sections, "")
				append(&section_types, 2)

				section_start = abs_pos + tag_end + 2
				pos = section_start
				continue
			}
		}

		pos = abs_pos + tag_end + 2
	}

	// Save final section
	sections[len(sections) - 1] = content[section_start:]

	// Now parse each section into the appropriate body
	elseif_idx := 0
	for i in 0 ..< len(sections) {
		section := sections[i]
		section_type := section_types[i]

		switch section_type {
		case 0:
			// main body
			parse_template_nodes(section, &if_node.body, allocator)
		case 1:
			// elseif
			branch := Elseif_Branch {
				condition = parse_condition(elseif_conditions[elseif_idx], allocator),
				body      = make([dynamic]Template_Node, allocator),
			}
			parse_template_nodes(section, &branch.body, allocator)
			append(&if_node.elseif_branches, branch)
			elseif_idx += 1
		case 2:
			// else
			parse_template_nodes(section, &if_node.else_body, allocator)
		}
	}
}

// Parse template nodes recursively
parse_template_nodes :: proc(
	content: string,
	nodes: ^[dynamic]Template_Node,
	allocator: mem.Allocator,
) {
	pos := 0

	for pos < len(content) {
		// Find next tag
		start := strings.index(content[pos:], "{{")
		if start == -1 {
			// No more tags, rest is text
			if pos < len(content) {
				append(
					nodes,
					Template_Node(Text_Node{text = strings.clone(content[pos:], allocator)}),
				)
			}
			break
		}

		// Text before tag
		if start > 0 {
			append(
				nodes,
				Template_Node(
					Text_Node{text = strings.clone(content[pos:pos + start], allocator)},
				),
			)
		}

		pos += start

		// Find end of tag
		end := strings.index(content[pos:], "}}")
		if end == -1 {
			// Malformed, treat rest as text
			append(nodes, Template_Node(Text_Node{text = strings.clone(content[pos:], allocator)}))
			break
		}

		tag_content := strings.trim_space(content[pos + 2:pos + end])
		pos += end + 2

		// Parse tag
		if strings.has_prefix(tag_content, "#if ") {
			condition_str := strings.trim_space(tag_content[4:])
			// Find matching {{/if}}
			body_end, _ := find_block_end(content[pos:], "if")
			if body_end == -1 {
				continue
			}

			if_node := If_Node {
				condition       = parse_condition(condition_str, allocator),
				body            = make([dynamic]Template_Node, allocator),
				elseif_branches = make([dynamic]Elseif_Branch, allocator),
				else_body       = make([dynamic]Template_Node, allocator),
			}

			// Parse body, looking for elseif and else
			block_content := content[pos:pos + body_end]
			parse_if_body(block_content, &if_node, allocator)

			append(nodes, Template_Node(if_node))
			pos += body_end + block_end_tag_len("if")
		} else if strings.has_prefix(tag_content, "#each ") {
			list_name := strings.trim_space(tag_content[6:])
			body_end, _ := find_block_end(content[pos:], "each")
			if body_end == -1 {
				continue
			}

			each_node := Each_Node {
				list_name = strings.clone(list_name, allocator),
				body      = make([dynamic]Template_Node, allocator),
			}
			parse_template_nodes(content[pos:pos + body_end], &each_node.body, allocator)

			append(nodes, Template_Node(each_node))
			pos += body_end + block_end_tag_len("each")
		} else if strings.has_prefix(tag_content, "#unless ") {
			condition := strings.trim_space(tag_content[8:])
			body_end, _ := find_block_end(content[pos:], "unless")
			if body_end == -1 {
				continue
			}

			unless_node := Unless_Node {
				condition = strings.clone(condition, allocator),
				body      = make([dynamic]Template_Node, allocator),
			}
			parse_template_nodes(content[pos:pos + body_end], &unless_node.body, allocator)

			append(nodes, Template_Node(unless_node))
			pos += body_end + block_end_tag_len("unless")
		} else if strings.has_prefix(tag_content, "> ") {
			// Partial include: {{> filename.ohtml}}
			partial_name := strings.trim_space(tag_content[2:])
			if len(partial_name) > 0 {
				append(nodes, Template_Node(Partial_Node{name = strings.clone(partial_name, allocator)}))
			}
		} else {
			// Variable (possibly with filters)
			var_node := parse_variable_with_filters(tag_content, allocator)
			append(nodes, Template_Node(var_node))
		}
	}
}

// Find the end of a block (e.g., {{/if}})
// Returns: position of closing tag start, position of {{else}} if present
find_block_end :: proc(content: string, block_type: string) -> (end_pos: int, else_pos: int) {
	depth := 1
	search_pos := 0
	else_pos = -1

	// Build tag strings - NOTE: Can't use fmt.tprintf with {{ because it escapes braces
	// {{#TYPE becomes {#TYPE with fmt, so we build strings manually
	start_tag_prefix := strings.concatenate({"{{#", block_type}, context.temp_allocator)
	end_tag := strings.concatenate({"{{/", block_type, "}}"}, context.temp_allocator)
	end_tag_len := len(end_tag)
	else_tag :: "{{else}}"

	for search_pos < len(content) {
		remaining := content[search_pos:]

		// Find positions of relevant tags in remaining content
		start_idx := strings.index(remaining, start_tag_prefix)
		end_idx := strings.index(remaining, end_tag)

		// No end tag found
		if end_idx == -1 {
			break
		}

		// Check for nested block start (must come before end tag)
		if start_idx != -1 && start_idx < end_idx {
			depth += 1
			search_pos += start_idx + len(start_tag_prefix)
			continue
		}

		// Check for else at current depth (must come before end tag)
		if depth == 1 && else_pos == -1 {
			else_idx := strings.index(remaining, else_tag)
			if else_idx != -1 && else_idx < end_idx {
				else_pos = search_pos + else_idx
			}
		}

		// Process end tag
		depth -= 1
		if depth == 0 {
			return search_pos + end_idx, else_pos
		}
		search_pos += end_idx + end_tag_len
	}

	return -1, -1
}

// Get the length of a closing tag for a block type
// {{/TYPE}} = 2 + 1 + len(TYPE) + 2 = 5 + len(TYPE)
block_end_tag_len :: proc(block_type: string) -> int {
	return 5 + len(block_type)
}

// Render template to string
template_render :: proc(
	tpl: ^Template,
	ctx: ^Template_Context,
	allocator := context.allocator,
	set: ^Template_Set = nil,
) -> string {
	builder := strings.builder_make(allocator)
	render_nodes(&tpl.nodes, ctx, &builder, set)
	return strings.to_string(builder)
}

// Render nodes
render_nodes :: proc(
	nodes: ^[dynamic]Template_Node,
	ctx: ^Template_Context,
	builder: ^strings.Builder,
	set: ^Template_Set = nil,
	depth: int = 0,
) {
	// Guard against infinite partial recursion
	MAX_PARTIAL_DEPTH :: 16
	if depth > MAX_PARTIAL_DEPTH do return
	for node in nodes {
		switch n in node {
		case Text_Node:
			strings.write_string(builder, n.text)

		case Variable_Node:
			value := ""
			raw_value: any = nil
			has_value := false

			// Get the value (check raw_values first for filters, then values)
			if rv, ok := ctx.raw_values[n.name]; ok {
				raw_value = rv
				has_value = true
				// Also get string representation
				if sv, sok := ctx.values[n.name]; sok {
					value = sv
				}
			} else if val, ok := ctx.values[n.name]; ok {
				value = val
				has_value = true
			}

			if has_value {
				// Apply filters
				result := value
				skip_escape := false

				for filter in n.filters {
					result, skip_escape = apply_filter(result, raw_value, filter)
				}

				if skip_escape {
					strings.write_string(builder, result)
				} else {
					strings.write_string(builder, html_escape(result))
				}
			}

		case If_Node:
			// Evaluate main condition
			if evaluate_condition(n.condition, ctx) {
				body := n.body
				render_nodes(&body, ctx, builder, set, depth)
			} else {
				// Try elseif branches
				branch_matched := false
				for idx in 0 ..< len(n.elseif_branches) {
					branch := n.elseif_branches[idx]
					if evaluate_condition(branch.condition, ctx) {
						body := branch.body
						render_nodes(&body, ctx, builder, set, depth)
						branch_matched = true
						break
					}
				}

				// Fall through to else if no branch matched
				if !branch_matched {
					else_body := n.else_body
					render_nodes(&else_body, ctx, builder, set, depth)
				}
			}

		case Each_Node:
			if list, ok := ctx.lists[n.list_name]; ok {
				body := n.body
				list_len := len(list)
				for item_ctx, idx in list {
					// Inject @index, @first, @last into each item context
					item_ctx.values["@index"] = fmt.tprintf("%d", idx)
					item_ctx.bools["@first"] = idx == 0
					item_ctx.bools["@last"] = idx == list_len - 1
					render_nodes(&body, item_ctx, builder, set, depth)
				}
			}

		case Unless_Node:
			condition_true := false
			if val, ok := ctx.bools[n.condition]; ok {
				condition_true = val
			} else if val, ok := ctx.values[n.condition]; ok {
				condition_true = len(val) > 0
			} else if list, ok := ctx.lists[n.condition]; ok {
				// List is considered "true" if it has items
				condition_true = len(list) > 0
			}

			body := n.body
			if !condition_true {
				render_nodes(&body, ctx, builder, set, depth)
			}

		case Partial_Node:
			// Include another template by name from the Template_Set
			if set != nil {
				if partial_tpl, ok := set.templates[n.name]; ok {
					render_nodes(&partial_tpl.nodes, ctx, builder, set, depth + 1)
				}
			}
		}
	}
}

// Evaluate a template condition
evaluate_condition :: proc(cond: Template_Condition, ctx: ^Template_Context) -> bool {
	// Simple boolean check (no operator)
	if cond.operator == "" {
		if val, ok := ctx.bools[cond.left]; ok {
			return val
		}
		if val, ok := ctx.values[cond.left]; ok {
			return len(val) > 0 && val != "false" && val != "0"
		}
		return false
	}

	// Get left value
	left_val := ""
	if val, ok := ctx.values[cond.left]; ok {
		left_val = val
	} else if val, ok := ctx.bools[cond.left]; ok {
		left_val = "true" if val else "false"
	}

	right_val := cond.right

	// String comparison
	switch cond.operator {
	case "==":
		return left_val == right_val
	case "!=":
		return left_val != right_val
	case ">", "<", ">=", "<=":
		// Try numeric comparison
		left_num, left_ok := strconv.parse_f64(left_val)
		right_num, right_ok := strconv.parse_f64(right_val)
		if left_ok && right_ok {
			switch cond.operator {
			case ">":
				return left_num > right_num
			case "<":
				return left_num < right_num
			case ">=":
				return left_num >= right_num
			case "<=":
				return left_num <= right_num
			}
		}
		// Fall back to string comparison
		switch cond.operator {
		case ">":
			return left_val > right_val
		case "<":
			return left_val < right_val
		case ">=":
			return left_val >= right_val
		case "<=":
			return left_val <= right_val
		}
	}

	return false
}

// Apply a filter to a value
// Returns: (result string, skip_html_escape)
apply_filter :: proc(value: string, raw_value: any, filter: Template_Filter) -> (string, bool) {
	switch filter.name {
	case "raw":
		// Don't escape HTML
		return value, true

	case "upper":
		return strings.to_upper(value, context.temp_allocator), false

	case "lower":
		return strings.to_lower(value, context.temp_allocator), false

	case "date":
		// Format as date only
		if ts, ok := get_timestamp_from_any(raw_value); ok {
			return format_timestamp(ts, "DD/MM/YYYY"), false
		}
		return value, false

	case "time":
		// Format as time only
		if ts, ok := get_timestamp_from_any(raw_value); ok {
			return format_timestamp(ts, "HH:mm"), false
		}
		return value, false

	case "datetime":
		// Format as date and time
		if ts, ok := get_timestamp_from_any(raw_value); ok {
			return format_timestamp(ts, "DD/MM/YYYY HH:mm"), false
		}
		return value, false

	case "format":
		// Custom format with argument
		if filter.arg != "" {
			if ts, ok := get_timestamp_from_any(raw_value); ok {
				return format_timestamp(ts, filter.arg), false
			}
		}
		return value, false

	case "truncate":
		// Truncate to length
		if filter.arg != "" {
			if length, ok := strconv.parse_int(filter.arg); ok {
				if len(value) > length {
					return strings.concatenate({value[:length], "..."}, context.temp_allocator),
						false
				}
			}
		}
		return value, false
	}

	return value, false
}

// Helper to extract timestamp from any value
// This checks if the value looks like our Timestamp struct
get_timestamp_from_any :: proc(value: any) -> (ts: Timestamp_Data, ok: bool) {
	if value == nil do return {}, false

	ti := reflect.type_info_base(type_info_of(value.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Struct:
		// Check if it has timestamp-like fields: year, month, day
		has_year, has_month, has_day := false, false, false
		for name in info.names[:info.field_count] {
			if name == "year" do has_year = true
			if name == "month" do has_month = true
			if name == "day" do has_day = true
		}

		if has_year && has_month && has_day {
			// Extract fields
			ts_data := Timestamp_Data{}
			for name, i in info.names[:info.field_count] {
				field_ptr := rawptr(uintptr(value.data) + info.offsets[i])
				field_type := info.types[i]
				field_any := any{field_ptr, field_type.id}

				switch name {
				case "year":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.year = v
				case "month":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.month = i8(v)
				case "day":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.day = i8(v)
				case "hour":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.hour = i8(v)
				case "minute":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.minute = i8(v)
				case "second":
					if v, vok := reflect.as_i64(field_any); vok do ts_data.second = i8(v)
				}
			}
			return ts_data, true
		}
	}
	return {}, false
}

// Internal timestamp data for template formatting (doesn't depend on postgres package)
Timestamp_Data :: struct {
	year:   i64,
	month:  i8,
	day:    i8,
	hour:   i8,
	minute: i8,
	second: i8,
}

// Format timestamp data using pattern
format_timestamp :: proc(ts: Timestamp_Data, pattern: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	i := 0
	for i < len(pattern) {
		matched := false

		// 4-char tokens
		if !matched && i + 4 <= len(pattern) {
			token := pattern[i:i + 4]
			if token == "YYYY" {
				fmt.sbprintf(&builder, "%04d", ts.year)
				i += 4
				matched = true
			}
		}

		// 2-char tokens
		if !matched && i + 2 <= len(pattern) {
			token := pattern[i:i + 2]
			switch token {
			case "YY":
				fmt.sbprintf(&builder, "%02d", ts.year % 100)
				i += 2
				matched = true
			case "MM":
				fmt.sbprintf(&builder, "%02d", ts.month)
				i += 2
				matched = true
			case "DD":
				fmt.sbprintf(&builder, "%02d", ts.day)
				i += 2
				matched = true
			case "HH":
				fmt.sbprintf(&builder, "%02d", ts.hour)
				i += 2
				matched = true
			case "hh":
				hour12 := ts.hour % 12
				if hour12 == 0 do hour12 = 12
				fmt.sbprintf(&builder, "%02d", hour12)
				i += 2
				matched = true
			case "mm":
				fmt.sbprintf(&builder, "%02d", ts.minute)
				i += 2
				matched = true
			case "ss":
				fmt.sbprintf(&builder, "%02d", ts.second)
				i += 2
				matched = true
			case "AM", "PM":
				is_pm := ts.hour >= 12
				strings.write_string(&builder, is_pm ? "PM" : "AM")
				i += 2
				matched = true
			case "am", "pm":
				is_pm := ts.hour >= 12
				strings.write_string(&builder, is_pm ? "pm" : "am")
				i += 2
				matched = true
			}
		}

		// No token matched, copy character as-is
		if !matched {
			strings.write_byte(&builder, pattern[i])
			i += 1
		}
	}

	return strings.to_string(builder)
}

// Render template directly to response
template_respond :: proc(res: ^Response, tpl: ^Template, ctx: ^Template_Context, set: ^Template_Set = nil) {
	res.headers["Content-Type"] = "text/html; charset=utf-8"
	result := template_render(tpl, ctx, context.temp_allocator, set)
	append(&res.body, ..transmute([]byte)result)
}

// Load all templates from directory
_template_scan_dir :: proc(
	set: ^Template_Set,
	root_dir: string,
	dir: string,
	pattern: string,
	allocator: mem.Allocator,
) {
	handle, err := os.open(dir)
	if err != os.ERROR_NONE do return
	defer os.close(handle)

	files, _ := os.read_dir(handle, -1, context.temp_allocator)
	for file in files {
		entry_info, entry_err := os.lstat(file.fullpath, context.temp_allocator)
		if entry_err != os.ERROR_NONE {
			continue
		}
		entry_type := entry_info.type
		os.file_info_delete(entry_info, context.temp_allocator)

		// Never follow symlinks while scanning templates.
		if entry_type == .Symlink {
			continue
		}

		if entry_type == .Directory {
			_template_scan_dir(set, root_dir, file.fullpath, pattern, allocator)
			continue
		}

		// Simple pattern matching: extract extension from pattern (e.g. "*.ohtml" → ".ohtml")
		if len(pattern) > 1 && pattern[0] == '*' {
			ext := pattern[1:]
			if !strings.has_suffix(file.name, ext) do continue
		}

		if !path_is_within_root_resolved(root_dir, file.fullpath) {
			continue
		}

		tpl, load_err := template_load(file.fullpath, allocator)
		if load_err == .None {
			set.templates[file.name] = tpl
		}
	}
}

template_load_dir :: proc(
	dir: string,
	pattern := "*.html",
	allocator := context.allocator,
) -> (
	^Template_Set,
	Error,
) {
	set := new(Template_Set, allocator)
	set.templates = make(map[string]^Template, 16, allocator)
	set.allocator = allocator

	// Verify the root directory exists
	handle, err := os.open(dir)
	if err != os.ERROR_NONE {
		free(set, allocator)
		return nil, .File_Not_Found
	}
	os.close(handle)

	_template_scan_dir(set, dir, dir, pattern, allocator)

	return set, .None
}

template_set_render :: proc(
	set: ^Template_Set,
	name: string,
	ctx: ^Template_Context,
	allocator := context.allocator,
) -> (
	string,
	Error,
) {
	if tpl, ok := set.templates[name]; ok {
		return template_render(tpl, ctx, allocator, set), .None
	}
	return "", .Template_Error
}

template_set_respond :: proc(
	res: ^Response,
	set: ^Template_Set,
	name: string,
	ctx: ^Template_Context,
) -> Error {
	if tpl, ok := set.templates[name]; ok {
		template_respond(res, tpl, ctx, set)
		return .None
	}
	return .Template_Error
}

template_destroy :: proc(tpl: ^Template) {
	if tpl == nil do return
	delete(tpl.content, tpl.allocator)
	destroy_nodes(&tpl.nodes, tpl.allocator)
	delete(tpl.nodes)
	free(tpl, tpl.allocator)
}

template_set_destroy :: proc(set: ^Template_Set) {
	if set == nil do return
	for _, tpl in set.templates {
		template_destroy(tpl)
	}
	delete(set.templates)
	free(set, set.allocator)
}

destroy_nodes :: proc(nodes: ^[dynamic]Template_Node, allocator: mem.Allocator) {
	for node in nodes {
		switch n in node {
		case Text_Node:
			delete(n.text, allocator)
		case Variable_Node:
			delete(n.name, allocator)
			for filter in n.filters {
				delete(filter.name, allocator)
				if len(filter.arg) > 0 do delete(filter.arg, allocator)
			}
			delete(n.filters)
		case If_Node:
			delete(n.condition.left, allocator)
			if len(n.condition.right) > 0 do delete(n.condition.right, allocator)
			body := n.body
			destroy_nodes(&body, allocator)
			delete(n.body)
			// Destroy elseif branches
			for branch in n.elseif_branches {
				delete(branch.condition.left, allocator)
				if len(branch.condition.right) > 0 do delete(branch.condition.right, allocator)
				branch_body := branch.body
				destroy_nodes(&branch_body, allocator)
				delete(branch.body)
			}
			delete(n.elseif_branches)
			else_body := n.else_body
			destroy_nodes(&else_body, allocator)
			delete(n.else_body)
		case Each_Node:
			delete(n.list_name, allocator)
			body := n.body
			destroy_nodes(&body, allocator)
			delete(n.body)
		case Unless_Node:
			delete(n.condition, allocator)
			body := n.body
			destroy_nodes(&body, allocator)
			delete(n.body)
		case Partial_Node:
			delete(n.name, allocator)
		}
	}
}

// Create a template context
template_context_create :: proc(allocator := context.allocator) -> ^Template_Context {
	ctx := new(Template_Context, allocator)
	ctx.values = make(map[string]string, 16, allocator)
	ctx.lists = make(map[string][]^Template_Context, 8, allocator)
	ctx.bools = make(map[string]bool, 8, allocator)
	ctx.raw_values = make(map[string]any, 16, allocator)
	return ctx
}

template_context_destroy :: proc(ctx: ^Template_Context, allocator := context.allocator) {
	if ctx == nil do return
	delete(ctx.values)
	delete(ctx.lists)
	delete(ctx.bools)
	delete(ctx.raw_values)
	free(ctx, allocator)
}

// ============================================================================
// Direct Struct Rendering (Go-like)
// ============================================================================

// Convert any struct to a Template_Context for rendering
// Usage: ctx := template_context_from(my_struct)
template_context_from :: proc(data: any, allocator := context.allocator) -> ^Template_Context {
	ctx := template_context_create(allocator)
	populate_context_from_any(ctx, data, allocator)
	return ctx
}

// Populate context from any value (struct, map, etc.)
populate_context_from_any :: proc(ctx: ^Template_Context, data: any, allocator: mem.Allocator) {
	if data == nil do return

	ti := reflect.type_info_base(type_info_of(data.id))

	#partial switch info in ti.variant {
	case reflect.Type_Info_Struct:
		// Iterate struct fields
		for name, i in info.names[:info.field_count] {
			field_ptr := rawptr(uintptr(data.data) + info.offsets[i])
			field_type := info.types[i]
			field_any := any{field_ptr, field_type.id}

			add_field_to_context(ctx, name, field_any, allocator)
		}
	}
}

// Add a single field to the context based on its type
add_field_to_context :: proc(
	ctx: ^Template_Context,
	name: string,
	field: any,
	allocator: mem.Allocator,
) {
	if field == nil do return

	ti := reflect.type_info_base(type_info_of(field.id))

	#partial switch info in ti.variant {
	case reflect.Type_Info_String:
		if str, ok := reflect.as_string(field); ok {
			ctx.values[name] = str
		}

	case reflect.Type_Info_Boolean:
		if b, ok := reflect.as_bool(field); ok {
			ctx.bools[name] = b
		}

	case reflect.Type_Info_Integer:
		if i, ok := reflect.as_i64(field); ok {
			ctx.values[name] = fmt.tprintf("%d", i)
		}

	case reflect.Type_Info_Float:
		if f, ok := reflect.as_f64(field); ok {
			// Format with up to 2 decimal places, trimming trailing zeros
			rounded := f64(i64(f * 100 + 0.5 if f >= 0 else f * 100 - 0.5)) / 100.0
			if rounded == f64(i64(rounded)) {
				ctx.values[name] = fmt.tprintf("%d", i64(rounded))
			} else {
				s := fmt.tprintf("%.2f", rounded)
				// Trim single trailing zero: "1.50" -> "1.5"
				if len(s) > 1 && s[len(s)-1] == '0' && s[len(s)-2] != '.' {
					ctx.values[name] = s[:len(s)-1]
				} else {
					ctx.values[name] = s
				}
			}
		}

	case reflect.Type_Info_Slice:
		// Handle slices of structs for {{#each}}
		elem_ti := info.elem
		if elem_ti != nil {
			slice_len := reflect.length(field)
			if slice_len > 0 {
				list := make([]^Template_Context, slice_len, allocator)
				for i in 0 ..< slice_len {
					item := reflect.index(field, i)
					item_ctx := template_context_create(allocator)
					populate_context_from_any(item_ctx, item, allocator)
					list[i] = item_ctx
				}
				ctx.lists[name] = list
			}
		}

	case reflect.Type_Info_Dynamic_Array:
		// Handle dynamic arrays of structs for {{#each}}
		arr_len := reflect.length(field)
		if arr_len > 0 {
			list := make([]^Template_Context, arr_len, allocator)
			for i in 0 ..< arr_len {
				item := reflect.index(field, i)
				item_ctx := template_context_create(allocator)
				populate_context_from_any(item_ctx, item, allocator)
				list[i] = item_ctx
			}
			ctx.lists[name] = list
		}

	case reflect.Type_Info_Struct:
		// Check if this looks like a timestamp (has year, month, day fields)
		has_year, has_month, has_day := false, false, false
		for field_name in info.names[:info.field_count] {
			if field_name == "year" do has_year = true
			if field_name == "month" do has_month = true
			if field_name == "day" do has_day = true
		}

		if has_year && has_month && has_day {
			// Timestamp-like struct - store raw value for filters
			ctx.raw_values[name] = field

			// Also create a default string representation
			ts_data, _ := get_timestamp_from_any(field)
			ctx.values[name] = format_timestamp(ts_data, "YYYY-MM-DD HH:mm:ss")
		} else {
			// Regular nested struct - flatten into context with same name
			nested_ctx := template_context_create(allocator)
			populate_context_from_any(nested_ctx, field, allocator)
			// Merge nested values with prefix (clone keys to proper allocator)
			for key, val in nested_ctx.values {
				prefixed_key := fmt.aprintf("%s.%s", name, key, allocator = allocator)
				ctx.values[prefixed_key] = val
			}
			for key, val in nested_ctx.bools {
				prefixed_key := fmt.aprintf("%s.%s", name, key, allocator = allocator)
				ctx.bools[prefixed_key] = val
			}
			// Also merge raw_values
			for key, val in nested_ctx.raw_values {
				prefixed_key := fmt.aprintf("%s.%s", name, key, allocator = allocator)
				ctx.raw_values[prefixed_key] = val
			}
			// Also merge lists (for {{#each nested.field}})
			for key, val in nested_ctx.lists {
				prefixed_key := fmt.aprintf("%s.%s", name, key, allocator = allocator)
				ctx.lists[prefixed_key] = val
			}
			template_context_destroy(nested_ctx, allocator)
		}
	}
}

// Render template directly with a struct (Go-like API)
// Usage: template_respond_with(res, tpl, my_struct)
template_respond_with :: proc(res: ^Response, tpl: ^Template, data: any, set: ^Template_Set = nil) {
	ctx := template_context_from(data, context.temp_allocator)
	template_respond(res, tpl, ctx, set)
}

// Render from template set with struct (Go-like API)
// Usage: template_set_respond_with(res, templates, "user.html", my_struct)
template_set_respond_with :: proc(
	res: ^Response,
	set: ^Template_Set,
	name: string,
	data: any,
) -> Error {
	if tpl, ok := set.templates[name]; ok {
		template_respond_with(res, tpl, data, set)
		return .None
	}
	return .Template_Error
}

// Render from template set with struct to string (for emails, etc.)
// Usage: html := template_set_render_with(templates, "email.ohtml", my_struct)
template_set_render_with :: proc(
	set: ^Template_Set,
	name: string,
	data: any,
	allocator := context.allocator,
) -> (string, Error) {
	if tpl, ok := set.templates[name]; ok {
		ctx := template_context_from(data, context.temp_allocator)
		return template_render(tpl, ctx, allocator, set), .None
	}
	return "", .Template_Error
}

// ============================================================================
// Internal Helpers
// ============================================================================

// Parse HTTP request
parse_request :: proc(
	socket: net.TCP_Socket,
	addr: net.Endpoint,
	max_body_size: int,
	allocator: mem.Allocator,
) -> (
	Request,
	Error,
) {
	req := Request {
		headers   = make(map[string]string, 32, allocator),
		cookies   = make(map[string]string, 16, allocator),
		params    = make(map[string]string, 8, allocator),
		query     = make(map[string]string, 16, allocator),
		allocator = allocator,
	}

	// Format remote address
	switch a in addr.address {
	case net.IP4_Address:
		req.remote_addr = fmt.aprintf(
			"%d.%d.%d.%d:%d",
			a[0],
			a[1],
			a[2],
			a[3],
			addr.port,
			allocator = allocator,
		)
	case net.IP6_Address:
		req.remote_addr = fmt.aprintf("[%x]:%d", a, addr.port, allocator = allocator)
	}

	// Read request data
	buffer: [8192]byte
	total_read := 0
	headers_end := -1

	read_loop: for total_read < len(buffer) {
		n, err := net.recv_tcp(socket, buffer[total_read:])
		if err != nil || n == 0 {
			if total_read == 0 {
				return req, .Socket_Error
			}
			break
		}
		total_read += n

		// Check for end of headers
		data := string(buffer[:total_read])
		if idx := strings.index(data, "\r\n\r\n"); idx != -1 {
			headers_end = idx
			break read_loop
		}
	}

	if headers_end == -1 {
		return req, .Invalid_Request
	}

	data := string(buffer[:total_read])
	header_section := data[:headers_end]
	body_start := headers_end + 4

	// Parse request line
	lines := strings.split(header_section, "\r\n", context.temp_allocator)
	if len(lines) == 0 {
		return req, .Invalid_Request
	}

	// Parse "GET /path HTTP/1.1"
	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) < 3 {
		return req, .Invalid_Request
	}

	// Method
	switch parts[0] {
	case "GET":
		req.method = .GET
	case "POST":
		req.method = .POST
	case "PUT":
		req.method = .PUT
	case "DELETE":
		req.method = .DELETE
	case "PATCH":
		req.method = .PATCH
	case "HEAD":
		req.method = .HEAD
	case "OPTIONS":
		req.method = .OPTIONS
	case:
		return req, .Invalid_Method
	}

	// Path and query string
	path_query := parts[1]
	if qidx := strings.index(path_query, "?"); qidx != -1 {
		req.path = strings.clone(path_query[:qidx], allocator)
		req.query_string = strings.clone(path_query[qidx + 1:], allocator)
		req.query = parse_query_string(req.query_string, allocator)
	} else {
		req.path = strings.clone(path_query, allocator)
	}

	// URL decode path
	req.path = url_decode(req.path, allocator)

	req.version = strings.clone(parts[2], allocator)

	// Parse headers (normalize names to lowercase for case-insensitive lookup)
	// Track content-length count to reject duplicates (HTTP smuggling prevention)
	content_length_count := 0
	for i in 1 ..< len(lines) {
		if colon := strings.index(lines[i], ":"); colon != -1 {
			name := strings.trim_space(lines[i][:colon])
			value := strings.trim_space(lines[i][colon + 1:])
			lower_name := strings.to_lower(name, allocator)
			if lower_name == "content-length" {
				content_length_count += 1
			}
			req.headers[lower_name] = strings.clone(value, allocator)
		}
	}

	// Reject duplicate Content-Length headers (HTTP request smuggling vector)
	if content_length_count > 1 {
		return req, .Invalid_Request
	}

	// Parse cookies
	if cookie_header, ok := req.headers["cookie"]; ok {
		parse_cookies(cookie_header, &req.cookies, allocator)
	}

	// Reject Transfer-Encoding to prevent HTTP smuggling
	// We only support Content-Length; chunked encoding is not implemented
	if "transfer-encoding" in req.headers {
		return req, .Invalid_Request
	}

	// Read body if Content-Length specified
	content_length_str: string
	have_content_length: bool
	content_length_str, have_content_length = req.headers["content-length"]
	if have_content_length {
		if content_length, ok := strconv.parse_int(content_length_str); ok && content_length > 0 {
			if max_body_size > 0 && content_length > max_body_size {
				return req, .Request_Too_Large
			}
			req.body = make([]byte, content_length)
			copied := copy(req.body, buffer[body_start:total_read])

			// Read remaining body if needed
			for copied < content_length {
				n, err := net.recv_tcp(socket, req.body[copied:])
				if err != nil || n == 0 {
					break
				}
				copied += n
			}
			// Reject incomplete body
			if copied < content_length {
				delete(req.body)
				req.body = nil
				return req, .Invalid_Request
			}
		}
	}

	return req, .None
}

// Parse query string into map
parse_query_string :: proc(qs: string, allocator: mem.Allocator) -> map[string]string {
	result := make(map[string]string, 16, allocator)

	pairs := strings.split(qs, "&", context.temp_allocator)
	for pair in pairs {
		if eq := strings.index(pair, "="); eq != -1 {
			key := url_decode(pair[:eq], allocator)
			value := url_decode(pair[eq + 1:], allocator)
			result[key] = value
		} else if len(pair) > 0 {
			result[url_decode(pair, allocator)] = ""
		}
	}

	return result
}

// Parse cookies from header
parse_cookies :: proc(header: string, cookies: ^map[string]string, allocator: mem.Allocator) {
	pairs := strings.split(header, ";", context.temp_allocator)
	for pair in pairs {
		trimmed := strings.trim_space(pair)
		if eq := strings.index(trimmed, "="); eq != -1 {
			name := strings.trim_space(trimmed[:eq])
			value := strings.trim_space(trimmed[eq + 1:])
			cookies[strings.clone(name, allocator)] = strings.clone(value, allocator)
		}
	}
}

// URL decode
url_decode :: proc(s: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)

	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			// Hex decode
			high := hex_digit(s[i + 1])
			low := hex_digit(s[i + 2])
			if high >= 0 && low >= 0 {
				strings.write_byte(&builder, byte(high * 16 + low))
				i += 3
				continue
			}
		} else if s[i] == '+' {
			strings.write_byte(&builder, ' ')
			i += 1
			continue
		}
		strings.write_byte(&builder, s[i])
		i += 1
	}

	return strings.to_string(builder)
}

hex_digit :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

// HTML escape for template output
html_escape :: proc(s: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	for c in s {
		switch c {
		case '<':
			strings.write_string(&builder, "&lt;")
		case '>':
			strings.write_string(&builder, "&gt;")
		case '&':
			strings.write_string(&builder, "&amp;")
		case '"':
			strings.write_string(&builder, "&quot;")
		case '\'':
			strings.write_string(&builder, "&#39;")
		case:
			strings.write_rune(&builder, c)
		}
	}

	return strings.to_string(builder)
}

// Method to string
method_to_string :: proc(m: Method) -> string {
	switch m {
	case .GET:
		return "GET"
	case .POST:
		return "POST"
	case .PUT:
		return "PUT"
	case .DELETE:
		return "DELETE"
	case .PATCH:
		return "PATCH"
	case .HEAD:
		return "HEAD"
	case .OPTIONS:
		return "OPTIONS"
	}
	return "UNKNOWN"
}

// Send error response
send_error_response :: proc(socket: net.TCP_Socket, status: Status) {
	response := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: text/html\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		int(status),
		status_text(status),
	)
	_send_all(socket, transmute([]byte)response)
}

// Serve static file with path traversal and symlink escape protection
serve_static_file :: proc(res: ^Response, path: string, root_dir: string = ".") -> Error {
	if path_contains_unsafe_chars(path) {
		return .File_Not_Found
	}

	clean_path, clean_err := filepath.clean(path, context.temp_allocator)
	if clean_err != nil || !path_is_within_root_resolved(root_dir, clean_path) {
		return .File_Not_Found
	}

	// Check file exists and is not a directory
	info, err := os.stat(clean_path, context.temp_allocator)
	if err != os.ERROR_NONE {
		return .File_Not_Found
	}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type == .Directory {
		return .File_Not_Found
	}

	content, read_err := os.read_entire_file(clean_path, context.temp_allocator)
	if read_err != nil {
		return .File_Not_Found
	}

	// Set content type based on extension
	ext := filepath.ext(clean_path)
	res.headers["Content-Type"] = mime_type(ext)

	// Cache static assets — CSS, JS, images, fonts
	lower_ext := strings.to_lower(ext, context.temp_allocator)
	switch lower_ext {
	case ".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".eot":
		res.headers["Cache-Control"] = "public, max-age=86400"
	}

	append(&res.body, ..content)
	return .None
}

// Get MIME type from extension
mime_type :: proc(ext: string) -> string {
	switch strings.to_lower(ext, context.temp_allocator) {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "application/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".xml":
		return "application/xml"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".svg":
		return "image/svg+xml"
	case ".ico":
		return "image/x-icon"
	case ".webp":
		return "image/webp"
	case ".woff":
		return "font/woff"
	case ".woff2":
		return "font/woff2"
	case ".ttf":
		return "font/ttf"
	case ".otf":
		return "font/otf"
	case ".eot":
		return "application/vnd.ms-fontobject"
	case ".pdf":
		return "application/pdf"
	case ".zip":
		return "application/zip"
	case ".mp3":
		return "audio/mpeg"
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".ogg":
		return "audio/ogg"
	case ".wav":
		return "audio/wav"
	}
	return "application/octet-stream"
}
