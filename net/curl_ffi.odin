#+build !js
package ingotnet

import "core:c"

when ODIN_OS == .Windows {
	@(export, extra_linker_flags = "/NODEFAULTLIB:msvcrt")
	foreign import curl_lib {"vendor:curl/lib/libcurl.lib", "system:Advapi32.lib", "system:Crypt32.lib", "system:Normaliz.lib", "system:Secur32.lib", "system:Wldap32.lib", "system:Ws2_32.lib", "system:iphlpapi.lib"}
} else when ODIN_OS == .Darwin {
	foreign import curl_lib {"system:curl", "system:SystemConfiguration.framework"}
} else {
	foreign import curl_lib "system:curl"
}

Curl :: struct {}
Curl_Slist :: struct {
	data: cstring,
	next: ^Curl_Slist,
}
Curl_Blob :: struct {
	data:  rawptr,
	len:   c.size_t,
	flags: c.uint,
}

Curl_Code :: enum c.int {
	OK                 = 0,
	OPERATION_TIMEDOUT = 28,
	AGAIN              = 81,
}

CURL_BLOB_COPY :: c.uint(1)
CURL_GLOBAL_ALL :: c.long(3)
CURL_URL :: c.int(10002)
CURL_SSL_VERIFYPEER :: c.int(64)
CURL_SSL_VERIFYHOST :: c.int(81)
CURL_CAINFO :: c.int(10065)
CURL_DISALLOW_USERNAME_IN_URL :: c.int(234)
CURL_WRITEFUNCTION :: c.int(20011)
CURL_WRITEDATA :: c.int(10001)
CURL_FOLLOWLOCATION :: c.int(52)
CURL_MAXREDIRS :: c.int(68)
CURL_CONNECT_ONLY :: c.int(141)
CURL_CONNECTTIMEOUT_MS :: c.int(156)
CURL_TIMEOUT_MS :: c.int(155)
CURL_CUSTOMREQUEST :: c.int(10036)
CURL_POSTFIELDS :: c.int(10015)
CURL_POSTFIELDSIZE :: c.int(60)
CURL_RESPONSE_CODE :: c.int(0x200002)
CURL_HTTPHEADER :: c.int(10023)
CURL_SSL_OPTIONS :: c.int(216)
CURL_CAINFO_BLOB :: c.int(40309)
CURL_REVOKE_BEST_EFFORT :: c.long(1 << 3)

@(default_calling_convention = "c")
foreign curl_lib {
	curl_global_init :: proc(flags: c.long) -> Curl_Code ---
	curl_easy_init :: proc() -> ^Curl ---
	curl_easy_setopt :: proc(handle: ^Curl, option: c.int, #c_vararg args: ..any) -> Curl_Code ---
	curl_easy_perform :: proc(handle: ^Curl) -> Curl_Code ---
	curl_easy_cleanup :: proc(handle: ^Curl) ---
	curl_easy_getinfo :: proc(handle: ^Curl, info: c.int, #c_vararg args: ..any) -> Curl_Code ---
	curl_slist_append :: proc(list: ^Curl_Slist, data: cstring) -> ^Curl_Slist ---
	curl_slist_free_all :: proc(list: ^Curl_Slist) ---
	curl_easy_send :: proc(handle: ^Curl, buffer: rawptr, length: c.size_t, written: ^c.size_t) -> Curl_Code ---
	curl_easy_recv :: proc(handle: ^Curl, buffer: rawptr, length: c.size_t, read: ^c.size_t) -> Curl_Code ---
}
