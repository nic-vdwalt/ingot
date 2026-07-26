#+build !js
package ingotnet

import "core:c"

when ODIN_OS == .Windows {
	@(export, extra_linker_flags = "/NODEFAULTLIB:msvcrt")
	foreign import ws_curl_lib {"vendor:curl/lib/libcurl.lib", "system:Advapi32.lib", "system:Crypt32.lib", "system:Normaliz.lib", "system:Secur32.lib", "system:Wldap32.lib", "system:Ws2_32.lib", "system:iphlpapi.lib"}
} else when ODIN_OS == .Darwin {
	foreign import ws_curl_lib {"system:curl", "system:SystemConfiguration.framework"}
} else {
	foreign import ws_curl_lib "system:curl"
}

Ws_Curl :: struct {}

Ws_Curl_Code :: enum c.int {
	OK                 = 0,
	OPERATION_TIMEDOUT = 28,
	AGAIN              = 81,
}

WS_CURL_GLOBAL_ALL :: c.long(3)
WS_CURL_URL :: c.int(10002)
WS_CURL_SSL_VERIFYPEER :: c.int(64)
WS_CURL_SSL_VERIFYHOST :: c.int(81)
WS_CURL_CONNECT_ONLY :: c.int(141)
WS_CURL_CONNECTTIMEOUT_MS :: c.int(156)
WS_CURL_CAINFO :: c.int(10065)
WS_CURL_DISALLOW_USERNAME_IN_URL :: c.int(234)

@(default_calling_convention = "c")
foreign ws_curl_lib {
	@(link_name = "curl_global_init")
	ws_curl_global_init :: proc(flags: c.long) -> Ws_Curl_Code ---
	@(link_name = "curl_easy_init")
	ws_curl_easy_init :: proc() -> ^Ws_Curl ---
	@(link_name = "curl_easy_setopt")
	ws_curl_easy_setopt :: proc(handle: ^Ws_Curl, option: c.int, #c_vararg args: ..any) -> Ws_Curl_Code ---
	@(link_name = "curl_easy_perform")
	ws_curl_easy_perform :: proc(handle: ^Ws_Curl) -> Ws_Curl_Code ---
	@(link_name = "curl_easy_cleanup")
	ws_curl_easy_cleanup :: proc(handle: ^Ws_Curl) ---
	@(link_name = "curl_easy_send")
	ws_curl_easy_send :: proc(handle: ^Ws_Curl, buffer: rawptr, length: c.size_t, written: ^c.size_t) -> Ws_Curl_Code ---
	@(link_name = "curl_easy_recv")
	ws_curl_easy_recv :: proc(handle: ^Ws_Curl, buffer: rawptr, length: c.size_t, read: ^c.size_t) -> Ws_Curl_Code ---
}
