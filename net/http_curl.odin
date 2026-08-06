#+build !js
package ingotnet

import "core:c"

when ODIN_OS == .Windows {
	@(export, extra_linker_flags = "/NODEFAULTLIB:msvcrt")
	foreign import http_curl_lib {"vendor:curl/lib/libcurl.lib", "system:Advapi32.lib", "system:Crypt32.lib", "system:Normaliz.lib", "system:Secur32.lib", "system:Wldap32.lib", "system:Ws2_32.lib", "system:iphlpapi.lib"}
} else when ODIN_OS == .Darwin {
	foreign import http_curl_lib {"system:curl", "system:SystemConfiguration.framework"}
} else {
	foreign import http_curl_lib "system:curl"
}

Http_Curl :: struct {}
Http_Curl_Slist :: struct {
	data: cstring,
	next: ^Http_Curl_Slist,
}

Http_Curl_Code :: enum c.int {
	OK = 0,
}

HTTP_CURL_GLOBAL_ALL :: c.long(3)
HTTP_CURL_URL :: c.int(10002)
HTTP_CURL_SSL_VERIFYPEER :: c.int(64)
HTTP_CURL_SSL_VERIFYHOST :: c.int(81)
HTTP_CURL_CAINFO :: c.int(10065)
HTTP_CURL_DISALLOW_USERNAME_IN_URL :: c.int(234)
HTTP_CURL_WRITEFUNCTION :: c.int(20011)
HTTP_CURL_WRITEDATA :: c.int(10001)
HTTP_CURL_FOLLOWLOCATION :: c.int(52)
HTTP_CURL_MAXREDIRS :: c.int(68)
HTTP_CURL_CONNECTTIMEOUT_MS :: c.int(156)
HTTP_CURL_TIMEOUT_MS :: c.int(155)
HTTP_CURL_CUSTOMREQUEST :: c.int(10036)
HTTP_CURL_POSTFIELDS :: c.int(10015)
HTTP_CURL_POSTFIELDSIZE :: c.int(60)
HTTP_CURL_RESPONSE_CODE :: c.int(0x200002)
HTTP_CURL_HTTPHEADER :: c.int(10023)

@(default_calling_convention = "c")
foreign http_curl_lib {
	@(link_name = "curl_global_init")
	http_curl_global_init :: proc(flags: c.long) -> Http_Curl_Code ---
	@(link_name = "curl_easy_init")
	http_curl_easy_init :: proc() -> ^Http_Curl ---
	@(link_name = "curl_easy_setopt")
	http_curl_easy_setopt :: proc(handle: ^Http_Curl, option: c.int, #c_vararg args: ..any) -> Http_Curl_Code ---
	@(link_name = "curl_easy_perform")
	http_curl_easy_perform :: proc(handle: ^Http_Curl) -> Http_Curl_Code ---
	@(link_name = "curl_easy_cleanup")
	http_curl_easy_cleanup :: proc(handle: ^Http_Curl) ---
	@(link_name = "curl_easy_getinfo")
	http_curl_easy_getinfo :: proc(handle: ^Http_Curl, info: c.int, #c_vararg args: ..any) -> Http_Curl_Code ---
	@(link_name = "curl_slist_append")
	http_curl_slist_append :: proc(list: ^Http_Curl_Slist, data: cstring) -> ^Http_Curl_Slist ---
	@(link_name = "curl_slist_free_all")
	http_curl_slist_free_all :: proc(list: ^Http_Curl_Slist) ---
}
