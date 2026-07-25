package ingotnet

import "core:strconv"
import "core:strings"
import "core:time"

Http_Scheme :: enum u8 {
	Http,
	Https,
}

Http_Error :: enum u8 {
	None,
	Invalid_URL,
	Invalid_Request,
	Resolve,
	Connect,
	TLS,
	Timeout,
	Cancelled,
	Protocol,
	Body_Too_Large,
	Redirect,
	Allocation,
	Unsupported,
}

Http_URL :: struct {
	scheme:         Http_Scheme,
	host:           string,
	port:           u16,
	explicit_port:  bool,
	request_target: string,
}

Http_Timeouts :: struct {
	resolve:       time.Duration,
	connect:       time.Duration,
	tls_handshake: time.Duration,
	write:         time.Duration,
	read:          time.Duration,
	total:         time.Duration,
}

Http_Parser_Limits :: struct {
	maximum_status_line_bytes: u64,
	maximum_header_bytes:      u64,
	maximum_header_count:      int,
	maximum_header_line_bytes: u64,
	maximum_body_bytes:        u64,
	maximum_chunk_line_bytes:  u64,
	maximum_trailer_bytes:     u64,
	maximum_trailer_count:     int,
}

Http_Redirect_Policy :: struct {
	maximum_redirects:     int,
	allow_https_downgrade: bool,
}

Http_Request_Options :: struct {
	limits:    Http_Parser_Limits,
	timeouts:  Http_Timeouts,
	redirects: Http_Redirect_Policy,
}

http_url_parse :: proc(raw: string) -> (url: Http_URL, err: Http_Error) {
	if len(raw) == 0 ||
	   strings.contains(raw, "\r") ||
	   strings.contains(raw, "\n") ||
	   strings.contains(raw, "\x00") {
		return {}, .Invalid_URL
	}
	rest := raw
	if strings.has_prefix(rest, "http://") {
		url.scheme = .Http
		url.port = 80
		rest = rest[7:]
	} else if strings.has_prefix(rest, "https://") {
		url.scheme = .Https
		url.port = 443
		rest = rest[8:]
	} else {
		return {}, .Invalid_URL
	}
	if fragment := strings.index(rest, "#"); fragment >= 0 do return {}, .Invalid_URL
	target_index := strings.index(rest, "/")
	query_index := strings.index(rest, "?")
	if target_index < 0 || (query_index >= 0 && query_index < target_index) do target_index = query_index
	authority := rest
	url.request_target = "/"
	if target_index >= 0 {
		authority = rest[:target_index]
		url.request_target = rest[target_index:]
		if url.request_target[0] == '?' do url.request_target = strings.concatenate({"/", url.request_target}, context.temp_allocator)
	}
	if len(authority) == 0 || strings.contains(authority, "@") do return {}, .Invalid_URL
	if authority[0] == '[' {
		closing := strings.index(authority, "]")
		if closing <= 1 do return {}, .Invalid_URL
		url.host = authority[1:closing]
		if closing + 1 < len(authority) {
			if authority[closing + 1] != ':' do return {}, .Invalid_URL
			port, ok := strconv.parse_u64(authority[closing + 2:])
			if !ok || port == 0 || port > 65535 do return {}, .Invalid_URL
			url.port = u16(port)
			url.explicit_port = true
		}
	} else {
		colon := strings.last_index(authority, ":")
		if colon >= 0 {
			if strings.index(authority[:colon], ":") >= 0 do return {}, .Invalid_URL
			port, ok := strconv.parse_u64(authority[colon + 1:])
			if !ok || port == 0 || port > 65535 do return {}, .Invalid_URL
			url.host = authority[:colon]
			url.port = u16(port)
			url.explicit_port = true
		} else {
			url.host = authority
		}
	}
	if len(url.host) == 0 || strings.contains(url.host, " ") do return {}, .Invalid_URL
	return url, .None
}

http_url_resolve :: proc(base: Http_URL, location: string) -> (Http_URL, Http_Error) {
	if strings.has_prefix(location, "http://") || strings.has_prefix(location, "https://") {
		resolved, err := http_url_parse(location)
		if err != .None do return {}, err
		if base.scheme == .Https && resolved.scheme == .Http do return {}, .Redirect
		return resolved, .None
	}
	if len(location) == 0 || location[0] != '/' do return {}, .Invalid_URL
	resolved := base
	resolved.request_target = location
	return resolved, .None
}

query_component_encode :: proc(value: string, allocator := context.temp_allocator) -> string {
	if len(value) == 0 do return ""
	hex := "0123456789ABCDEF"
	builder := strings.builder_make(allocator)
	for byte in transmute([]u8)value {
		unreserved :=
			(byte >= 'a' && byte <= 'z') ||
			(byte >= 'A' && byte <= 'Z') ||
			(byte >= '0' && byte <= '9') ||
			byte == '-' ||
			byte == '.' ||
			byte == '_' ||
			byte == '~'
		if unreserved {
			strings.write_byte(&builder, byte)
		} else {
			strings.write_byte(&builder, '%')
			strings.write_byte(&builder, hex[byte >> 4])
			strings.write_byte(&builder, hex[byte & 15])
		}
	}
	return strings.to_string(builder)
}
