#+build windows
package imgman

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import win "core:sys/windows"

foreign import host_kernel "system:Kernel32.lib"
@(default_calling_convention="system")
foreign host_kernel {
	ReplaceFileW :: proc(target, replacement, backup: win.LPCWSTR, flags: win.DWORD, exclude, reserved: rawptr) -> win.BOOL ---
}

Host_Entry :: struct {
	name, path: string,
	directory: bool,
}

host_error :: proc(action: string, code: win.DWORD = max(win.DWORD)) -> string {
    code := code
    if code == max(win.DWORD) { code = win.GetLastError() }
	buffer: [1024]u16
	n := win.FormatMessageW(win.FORMAT_MESSAGE_FROM_SYSTEM | win.FORMAT_MESSAGE_IGNORE_INSERTS, nil, code, 0, raw_data(buffer[:]), len(buffer), nil)
	message, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)raw_data(buffer[:]), int(n))
	return fmt.tprintf("%s: %s (Windows error %d)", action, strings.trim_space(message), code)
}

host_exists :: proc(path: string) -> bool {
	w := win.utf8_to_utf16(path, context.allocator)
	defer delete(w)
	return len(w) > 0 && win.GetFileAttributesW(cast(win.LPCWSTR)raw_data(w)) != win.INVALID_FILE_ATTRIBUTES
}

host_safe_leaf :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." || !utf8.valid_string(name) { return false }
	if name[len(name)-1] == '.' || name[len(name)-1] == ' ' { return false }
	for c in name {
		if c < 32 || c == 127 || c == '/' || c == '\\' || c == ':' || c == '"' || c == '<' || c == '>' || c == '|' || c == '*' || c == '?' { return false }
	}
	stem := name
	for c, i in name { if c == '.' { stem = name[:i]; break } }
	stem = strings.trim_right(stem, " ")
	reserved := [?]string{"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
	for item in reserved { if strings.equal_fold(stem, item) { return false } }
	if len(stem) >= 4 && (strings.equal_fold(stem[:3], "COM") || strings.equal_fold(stem[:3], "LPT")) {
		suffix := stem[3:]
		if len(suffix) == 1 && suffix[0] >= '1' && suffix[0] <= '9' { return false }
		if suffix == "¹" || suffix == "²" || suffix == "³" { return false }
	}
	return true
}

host_safe_export_dir :: proc(path: string) -> string {
	if path == "" { return "Choose an export folder." }
	for c in path { if c == 0 { return "Invalid export folder path." } }
	wpath := win.utf8_to_utf16(path, context.allocator)
	defer delete(wpath)
	if len(wpath) == 0 { return "Invalid export folder path." }
	needed := win.GetFullPathNameW(cast(win.LPCWSTR)raw_data(wpath), 0, nil, nil)
	if needed == 0 { return host_error("Cannot resolve export folder") }
	full := make([]u16, int(needed)+1)
	defer delete(full)
	n := win.GetFullPathNameW(cast(win.LPCWSTR)raw_data(wpath), win.DWORD(len(full)), cast(win.LPCWSTR)raw_data(full), nil)
	if n == 0 || int(n) >= len(full) { return host_error("Cannot resolve export folder") }
	end := int(n)
	root := 0
	if end >= 3 && full[1] == ':' && full[2] == '\\' {
		root = 3
	} else if end >= 5 && full[0] == '\\' && full[1] == '\\' {
		if full[2] == '?' || full[2] == '.' { return "Device namespace paths cannot be used as export folders." }
		server_end := 2
		for server_end < end && full[server_end] != '\\' { server_end += 1 }
		if server_end == 2 || server_end+1 >= end { return "Choose a folder inside a network share." }
		root = server_end+1
		for root < end && full[root] != '\\' { root += 1 }
		if root == server_end+1 { return "Invalid network share path." }
	} else { return "Cannot resolve an absolute export folder path." }
	for end > root && full[end-1] == '\\' { end -= 1 }
	for {
		full[end] = 0
		attributes := win.GetFileAttributesW(cast(win.LPCWSTR)raw_data(full))
		if attributes == win.INVALID_FILE_ATTRIBUTES { return host_error("Cannot inspect export folder") }
		if attributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 { return "Export folders cannot be symbolic links, junctions, or inside reparse points." }
		if attributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 { return "The export destination is not a folder." }
		if end == root { break }
		for end > root && full[end-1] != '\\' { end -= 1 }
		for end > root && full[end-1] == '\\' { end -= 1 }
	}
	return ""
}

host_read :: proc(path: string) -> ([]u8, string) {
	w := win.utf8_to_utf16(path, context.allocator)
	defer delete(w)
	if len(w) == 0 { return nil, "Invalid file path." }
	h := win.CreateFileW(cast(win.LPCWSTR)raw_data(w), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil, host_error("Cannot open file") }
	defer win.CloseHandle(h)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(h, &size) { return nil, host_error("Cannot read file size") }
	if size < 0 || size > 16 * 1024 * 1024 { return nil, "The file is too large for a floppy image (over 16 MiB)." }
	data := make([]u8, int(size))
	pos := 0
	for pos < len(data) {
		count: win.DWORD
		if !win.ReadFile(h, raw_data(data[pos:]), win.DWORD(len(data)-pos), &count, nil) {
			err := host_error("Cannot read file")
			delete(data)
			return nil, err
		}
		if count == 0 {
			delete(data)
			return nil, "The file changed while it was being read."
		}
		pos += int(count)
	}
	return data, ""
}

host_save_counter: u64

host_save :: proc(path: string, data: []u8, overwrite := true) -> string {
	w := win.utf8_to_utf16(path, context.allocator)
	defer delete(w)
	if len(w) == 0 { return "Invalid destination path." }
	target := cast(win.LPCWSTR)raw_data(w)
	exists := win.GetFileAttributesW(target) != win.INVALID_FILE_ATTRIBUTES
	if exists && !overwrite { return "The destination already exists." }
	if exists && (win.GetFileAttributesW(target) & win.FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return "Cannot replace a symbolic link or reparse point." }
	h: win.HANDLE = win.INVALID_HANDLE_VALUE
	temporary: []u16
	for attempt in 0..<64 {
		host_save_counter += 1
		name := fmt.tprintf("%s.imgman-%d-%d.tmp", path, win.GetCurrentProcessId(), host_save_counter)
		temporary = win.utf8_to_utf16(name, context.allocator)
		h = win.CreateFileW(cast(win.LPCWSTR)raw_data(temporary), win.GENERIC_WRITE, 0, nil, win.CREATE_NEW, win.FILE_ATTRIBUTE_NORMAL, nil)
		if h != win.INVALID_HANDLE_VALUE { break }
		code := win.GetLastError()
		delete(temporary)
		temporary = nil
		if code != win.ERROR_FILE_EXISTS && code != win.ERROR_ALREADY_EXISTS { return host_error("Cannot create temporary image", code) }
	}
	if h == win.INVALID_HANDLE_VALUE { return "Cannot create a unique temporary image." }
	defer delete(temporary)
	temp_path := cast(win.LPCWSTR)raw_data(temporary)
	defer win.DeleteFileW(temp_path)
	closed := false
	defer if !closed { win.CloseHandle(h) }
	pos := 0
	for pos < len(data) {
		count: win.DWORD
		if !win.WriteFile(h, raw_data(data[pos:]), win.DWORD(min(len(data)-pos, 1024*1024)), &count, nil) { return host_error("Cannot write image") }
		if count == 0 { return "Cannot finish writing image." }
		pos += int(count)
	}
	if !win.FlushFileBuffers(h) { return host_error("Cannot flush image to disk") }
	if !win.CloseHandle(h) { return host_error("Cannot close image") }
	closed = true
	if exists {
		if !ReplaceFileW(target, temp_path, nil, 0, nil, nil) { return host_error("Cannot replace image") }
	} else {
		if !win.MoveFileExW(temp_path, target, win.MOVEFILE_WRITE_THROUGH) { return host_error("Cannot save image") }
	}
	return ""
}

host_choose_file :: proc(owner: win.HWND, save: bool, title: string, suggested := "") -> string {
	buffer: [32768]u16
	if suggested != "" { _ = win.utf8_to_utf16(buffer[:], suggested) }
	filter := win.utf8_to_utf16("Floppy images (*.img;*.ima)\x00*.img;*.ima\x00All files (*.*)\x00*.*\x00\x00", context.allocator)
	defer delete(filter)
	wtitle := win.utf8_to_utf16(title, context.allocator)
	defer delete(wtitle)
	ext := win.utf8_to_utf16("img", context.allocator)
	defer delete(ext)
	dialog := win.OPENFILENAMEW{
		lStructSize = size_of(win.OPENFILENAMEW), hwndOwner = owner,
		lpstrFilter = cast(win.LPCWSTR)raw_data(filter), nFilterIndex = 1,
		lpstrFile = raw_data(buffer[:]), nMaxFile = len(buffer),
		lpstrTitle = cast(win.LPCWSTR)raw_data(wtitle), lpstrDefExt = cast(win.LPCWSTR)raw_data(ext),
		Flags = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR | win.OFN_HIDEREADONLY,
	}
	ok: win.BOOL
	if save {
		dialog.Flags |= win.OFN_OVERWRITEPROMPT
		ok = win.GetSaveFileNameW(&dialog)
	} else {
		dialog.Flags |= win.OFN_FILEMUSTEXIST
		ok = win.GetOpenFileNameW(&dialog)
	}
	if !ok { return "" }
	result, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)raw_data(buffer[:]), allocator=context.allocator)
	return result
}

host_choose_import :: proc(owner: win.HWND) -> []string {
	buffer := make([]u16, 65536)
	defer delete(buffer)
	filter := win.utf8_to_utf16("All files (*.*)\x00*.*\x00\x00", context.allocator)
	defer delete(filter)
	title := win.utf8_to_utf16("Add files to image", context.allocator)
	defer delete(title)
	dialog := win.OPENFILENAMEW{
		lStructSize = size_of(win.OPENFILENAMEW), hwndOwner = owner,
		lpstrFilter = cast(win.LPCWSTR)raw_data(filter), nFilterIndex = 1,
		lpstrFile = raw_data(buffer), nMaxFile = win.DWORD(len(buffer)),
		lpstrTitle = cast(win.LPCWSTR)raw_data(title),
		Flags = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_FILEMUSTEXIST | win.OFN_ALLOWMULTISELECT | win.OFN_NOCHANGEDIR | win.OFN_HIDEREADONLY,
	}
	if !win.GetOpenFileNameW(&dialog) { return nil }
	end := 0
	for buffer[end] != 0 { end += 1 }
	base, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)raw_data(buffer), end, context.allocator)
	if buffer[end+1] == 0 {
		result := make([]string, 1)
		result[0] = base
		return result
	}
	defer delete(base)
	paths := make([dynamic]string)
	defer delete(paths)
	pos := end+1
	for pos < len(buffer) && buffer[pos] != 0 {
		end = pos
		for end < len(buffer) && buffer[end] != 0 { end += 1 }
		name, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)raw_data(buffer[pos:]), end-pos)
		append(&paths, fmt.aprintf("%s\\%s", base, name))
		pos = end+1
	}
	return slice.clone(paths[:])
}

host_choose_folder :: proc(owner: win.HWND, initial: string = "") -> string {
	dialog: ^win.IFileOpenDialog
	if win.CoCreateInstance(win.CLSID_FileOpenDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileOpenDialog, cast(^rawptr)&dialog) < 0 { return "" }
	defer dialog.Release(cast(^win.IUnknown)dialog)
	options: win.FILEOPENDIALOGOPTIONS
	if dialog.GetOptions(cast(^win.IFileDialog)dialog, &options) < 0 { return "" }
	options |= win.FOS_PICKFOLDERS | win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST
	if dialog.SetOptions(cast(^win.IFileDialog)dialog, options) < 0 { return "" }
	if initial != "" {
		wdir := win.utf8_to_utf16(initial, context.allocator)
		defer delete(wdir)
		if len(wdir) > 0 {
			attributes := win.GetFileAttributesW(cast(win.LPCWSTR)raw_data(wdir))
			if attributes != win.INVALID_FILE_ATTRIBUTES && attributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 {
				folder: ^win.IShellItem
				if win.SHCreateItemFromParsingName(cast(win.LPCWSTR)raw_data(wdir), nil, win.IID_IShellItem, cast(^rawptr)&folder) >= 0 {
					dialog.SetFolder(cast(^win.IFileDialog)dialog, folder)
					folder.Release(cast(^win.IUnknown)folder)
				}
			}
		}
	}
	if dialog.Show(cast(^win.IModalWindow)dialog, owner) < 0 { return "" }
	item: ^win.IShellItem
	if dialog.GetResult(cast(^win.IFileDialog)dialog, &item) < 0 { return "" }
	defer item.Release(cast(^win.IUnknown)item)
	name: win.LPWSTR
	if item.GetDisplayName(item, .FILESYSPATH, &name) < 0 { return "" }
	defer win.CoTaskMemFree(rawptr(name))
	result, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)name, allocator=context.allocator)
	return result
}

host_children :: proc(path: string) -> ([]Host_Entry, string) {
	wpath := win.utf8_to_utf16(path, context.allocator)
	defer delete(wpath)
	if len(wpath) == 0 { return nil, "Invalid folder path." }
	attributes := win.GetFileAttributesW(cast(win.LPCWSTR)raw_data(wpath))
	if attributes == win.INVALID_FILE_ATTRIBUTES { return nil, host_error("Cannot inspect folder") }
	if attributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 { return nil, "Symbolic links and reparse points cannot be imported." }
	pattern := win.utf8_to_utf16(fmt.tprintf("%s\\*", path), context.allocator)
	defer delete(pattern)
	data: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(cast(win.LPCWSTR)raw_data(pattern), &data)
	if h == win.INVALID_HANDLE_VALUE {
		code := win.GetLastError()
		if code == win.ERROR_FILE_NOT_FOUND { return nil, "" }
		return nil, host_error("Cannot read folder", code)
	}
	defer win.FindClose(h)
	entries := make([dynamic]Host_Entry)
	defer delete(entries)
	for {
		name, _ := win.wstring_to_utf8_alloc(cast(win.LPCWSTR)raw_data(data.cFileName[:]), allocator=context.allocator)
		if name != "." && name != ".." {
			if data.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
				delete(name)
				for entry in entries { delete(entry.name); delete(entry.path) }
				return nil, "A folder contains a symbolic link or reparse point; import was cancelled."
			}
			append(&entries, Host_Entry{name=name, path=fmt.aprintf("%s\\%s", path, name), directory=(data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0})
		} else { delete(name) }
		if !win.FindNextFileW(h, &data) {
			code := win.GetLastError()
			if code != win.ERROR_NO_MORE_FILES {
				for entry in entries { delete(entry.name); delete(entry.path) }
				return nil, host_error("Cannot finish reading folder", code)
			}
			break
		}
	}
	return slice.clone(entries[:]), ""
}

host_release_children :: proc(entries: []Host_Entry) {
	for entry in entries { delete(entry.name); delete(entry.path) }
	delete(entries)
}

host_release_paths :: proc(paths: []string) {
	for path in paths { delete(path) }
	delete(paths)
}
