package sys

import "core:strings"

OPEN_URL_MAX_BYTES :: 8192

Open_URL_Status :: enum u8 {
	Opened,
	Invalid,
	Blocked_Scheme,
	Unsupported,
	Failed,
}

Open_URL_Options :: struct {
	allow_http:   bool,
	allow_https:  bool,
	allow_mailto: bool,
}

@(private)
_validate_external_url :: proc(
	url: string,
	options: Open_URL_Options,
) -> (
	string,
	Open_URL_Status,
) {
	if len(url) == 0 ||
	   len(url) > OPEN_URL_MAX_BYTES ||
	   strings.contains(url, "\x00") ||
	   strings.contains(url, "\r") ||
	   strings.contains(url, "\n") {
		return "", .Invalid
	}
	colon := strings.index(url, ":")
	if colon <= 0 do return "", .Invalid
	scheme := strings.to_lower(url[:colon], context.temp_allocator)
	if scheme == "http" && options.allow_http do return url, .Opened
	if scheme == "https" && options.allow_https do return url, .Opened
	if scheme == "mailto" && options.allow_mailto do return url, .Opened
	return "", .Blocked_Scheme
}
