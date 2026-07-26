#+build windows
package ui

// Windows spellcheck backend: ISpellChecker COM API (Windows 8+).
//
// The interfaces are declared manually because core:sys/windows does not ship
// spellcheck.h bindings. Any HRESULT failure (Windows 7, N editions without
// the feature, broken COM state) degrades to spell_available() == false.

import "core:strings"
import win "core:sys/windows"

@(private = "file")
CLSID_SpellCheckerFactory := win.CLSID {
	0x7AB36653,
	0x1796,
	0x484B,
	{0xBD, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC},
}
@(private = "file")
IID_ISpellCheckerFactory := win.IID {
	0x8E018A9D,
	0x2415,
	0x4677,
	{0xBF, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB},
}

// Vtable declarations mirror spellcheck.h IDL order exactly. The IUnknown
// methods are redeclared with typed `this` pointers so `->` calls type-check.

ISpellCheckerFactory :: struct {
	using _vtbl: ^ISpellCheckerFactory_VTable,
}
ISpellCheckerFactory_VTable :: struct {
	QueryInterface:         proc "system" (
		this: ^ISpellCheckerFactory,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:                 proc "system" (this: ^ISpellCheckerFactory) -> win.ULONG,
	Release:                proc "system" (this: ^ISpellCheckerFactory) -> win.ULONG,
	get_SupportedLanguages: proc "system" (
		this: ^ISpellCheckerFactory,
		value: ^^win.IEnumString,
	) -> win.HRESULT,
	IsSupported:            proc "system" (
		this: ^ISpellCheckerFactory,
		languageTag: win.LPCWSTR,
		value: ^win.BOOL,
	) -> win.HRESULT,
	CreateSpellChecker:     proc "system" (
		this: ^ISpellCheckerFactory,
		languageTag: win.LPCWSTR,
		value: ^^ISpellChecker,
	) -> win.HRESULT,
}

ISpellChecker :: struct {
	using _vtbl: ^ISpellChecker_VTable,
}
ISpellChecker_VTable :: struct {
	QueryInterface:             proc "system" (
		this: ^ISpellChecker,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:                     proc "system" (this: ^ISpellChecker) -> win.ULONG,
	Release:                    proc "system" (this: ^ISpellChecker) -> win.ULONG,
	get_LanguageTag:            proc "system" (
		this: ^ISpellChecker,
		value: ^win.LPWSTR,
	) -> win.HRESULT,
	Check:                      proc "system" (
		this: ^ISpellChecker,
		text: win.LPCWSTR,
		value: ^^IEnumSpellingError,
	) -> win.HRESULT,
	Suggest:                    proc "system" (
		this: ^ISpellChecker,
		word: win.LPCWSTR,
		value: ^^win.IEnumString,
	) -> win.HRESULT,
	Add:                        proc "system" (
		this: ^ISpellChecker,
		word: win.LPCWSTR,
	) -> win.HRESULT,
	Ignore:                     proc "system" (
		this: ^ISpellChecker,
		word: win.LPCWSTR,
	) -> win.HRESULT,
	AutoCorrect:                proc "system" (
		this: ^ISpellChecker,
		from, to: win.LPCWSTR,
	) -> win.HRESULT,
	GetOptionValue:             proc "system" (
		this: ^ISpellChecker,
		optionId: win.LPCWSTR,
		value: ^win.BYTE,
	) -> win.HRESULT,
	get_OptionIds:              proc "system" (
		this: ^ISpellChecker,
		value: ^^win.IEnumString,
	) -> win.HRESULT,
	get_Id:                     proc "system" (
		this: ^ISpellChecker,
		value: ^win.LPWSTR,
	) -> win.HRESULT,
	ComprehensiveCheck:         proc "system" (
		this: ^ISpellChecker,
		text: win.LPCWSTR,
		value: ^^IEnumSpellingError,
	) -> win.HRESULT,
	add_SpellCheckerChanged:    proc "system" (
		this: ^ISpellChecker,
		handler: rawptr,
		eventCookie: ^win.DWORD,
	) -> win.HRESULT,
	remove_SpellCheckerChanged: proc "system" (
		this: ^ISpellChecker,
		eventCookie: win.DWORD,
	) -> win.HRESULT,
}

IEnumSpellingError :: struct {
	using _vtbl: ^IEnumSpellingError_VTable,
}
IEnumSpellingError_VTable :: struct {
	QueryInterface: proc "system" (
		this: ^IEnumSpellingError,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IEnumSpellingError) -> win.ULONG,
	Release:        proc "system" (this: ^IEnumSpellingError) -> win.ULONG,
	Next:           proc "system" (
		this: ^IEnumSpellingError,
		value: ^^ISpellingError,
	) -> win.HRESULT,
}

ISpellingError :: struct {
	using _vtbl: ^ISpellingError_VTable,
}
ISpellingError_VTable :: struct {
	QueryInterface:       proc "system" (
		this: ^ISpellingError,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:               proc "system" (this: ^ISpellingError) -> win.ULONG,
	Release:              proc "system" (this: ^ISpellingError) -> win.ULONG,
	get_StartIndex:       proc "system" (this: ^ISpellingError, value: ^win.ULONG) -> win.HRESULT,
	get_Length:           proc "system" (this: ^ISpellingError, value: ^win.ULONG) -> win.HRESULT,
	get_CorrectiveAction: proc "system" (this: ^ISpellingError, value: ^win.DWORD) -> win.HRESULT,
	get_Replacement:      proc "system" (this: ^ISpellingError, value: ^win.LPWSTR) -> win.HRESULT,
}

@(private = "file")
LOCALE_NAME_MAX_LENGTH :: 85

foreign import kernel32_spell "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_spell {
	GetUserDefaultLocaleName :: proc(
		lpLocaleName: win.LPWSTR,
		cchLocaleName: win.c_int,
	) -> win.c_int ---
}

// Windows exposes a process COM spell-check adapter. Runtime-owned Spell_System
// values retain independent caches, ignored words, and generations.
@(private = "file")
g_checker: ^ISpellChecker

_spell_backend_init :: proc() -> bool {
	// S_FALSE / RPC_E_CHANGED_MODE mean COM is already initialised — proceed.
	win.CoInitializeEx(nil, .APARTMENTTHREADED)

	factory: ^ISpellCheckerFactory
	hr := win.CoCreateInstance(
		&CLSID_SpellCheckerFactory,
		nil,
		win.CLSCTX_INPROC_SERVER,
		&IID_ISpellCheckerFactory,
		(^win.LPVOID)(&factory),
	)
	if hr < 0 || factory == nil do return false
	defer factory->Release()

	// Prefer the user's locale; fall back to en-US when unsupported.
	locale_buf: [LOCALE_NAME_MAX_LENGTH]win.WCHAR
	locale: win.LPCWSTR = win.L("en-US")
	if GetUserDefaultLocaleName(win.LPWSTR(&locale_buf[0]), LOCALE_NAME_MAX_LENGTH) > 0 {
		supported: win.BOOL
		if factory->IsSupported(win.LPCWSTR(&locale_buf[0]), &supported) >= 0 && supported {
			locale = win.LPCWSTR(&locale_buf[0])
		}
	}

	if factory->CreateSpellChecker(locale, &g_checker) < 0 || g_checker == nil {
		// Locale-specific checker failed: try en-US before giving up.
		g_checker = nil
		if factory->CreateSpellChecker(win.L("en-US"), &g_checker) < 0 {
			g_checker = nil
		}
	}
	return g_checker != nil
}

_spell_backend_check :: proc(word: string) -> bool {
	if g_checker == nil do return true
	wword := win.utf8_to_wstring(word, context.temp_allocator)
	if wword == nil do return true
	errs: ^IEnumSpellingError
	if g_checker->Check(wword, &errs) < 0 || errs == nil do return true
	defer errs->Release()
	err: ^ISpellingError
	if errs->Next(&err) == 0 && err != nil { 	// S_OK: at least one error item
		err->Release()
		return false
	}
	return true
}

_spell_backend_suggest :: proc(word: string, allocator := context.allocator) -> []string {
	if g_checker == nil do return nil
	wword := win.utf8_to_wstring(word, context.temp_allocator)
	if wword == nil do return nil
	en: ^win.IEnumString
	if g_checker->Suggest(wword, &en) < 0 || en == nil do return nil
	defer (^win.IUnknown)(en)->Release()

	out := make([dynamic]string, 0, SPELL_MAX_SUGGESTIONS, allocator)
	for len(out) < SPELL_MAX_SUGGESTIONS {
		pstr: win.LPOLESTR
		fetched: win.ULONG
		if en->Next(1, &pstr, &fetched) != 0 || fetched == 0 || pstr == nil do break
		s, err := win.wstring_to_utf8(pstr, -1, allocator)
		win.CoTaskMemFree(rawptr(pstr))
		if err != nil do break
		append(&out, s)
	}
	return out[:]
}

_spell_backend_learn :: proc(word: string) {
	if g_checker == nil do return
	wword := win.utf8_to_wstring(word, context.temp_allocator)
	if wword == nil do return
	g_checker->Add(wword)
}
