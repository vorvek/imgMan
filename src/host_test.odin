#+build windows
package imgman

import "core:testing"
import "core:bytes"
import "core:fmt"
import win "core:sys/windows"

@(test)
export_leaf_names :: proc(t: ^testing.T) {
	valid := [?]string{"README.TXT", "DOS", "GAME~1.EXE", "AUXILIAR", "COM10.TXT", "NULFILE", "NIÑO.TXT", "foo.bar.baz"}
	for name in valid { testing.expect(t, host_safe_leaf(name), name) }
	invalid := [?]string{
		"", ".", "..", "../FILE", "A\\..\\FILE", "A/B", "C:FILE", "FILE:STREAM",
		"A\x00B", "A\nB", "A\x1fB", "A\x7fB", "FILE.", "FILE ",
		"A?B", "A*B", "A\"B", "A<B", "A>B", "A|B", "\xff.TXT",
		"CON", "con.txt", "PRN", "AUX.EXE", "NUL", "COM1", "com9.sys", "LPT1.DAT", "LPT9",
		"CON .TXT", "CONIN$", "CONOUT$.TXT", "COM¹", "LPT².TXT", "COM³",
	}
	for name in invalid { testing.expect(t, !host_safe_leaf(name), name) }
}

@(test)
export_directory_paths :: proc(t: ^testing.T) {
	testing.expect(t, host_safe_export_dir(".") == "")
	testing.expect(t, host_safe_export_dir("") != "")
	testing.expect(t, host_safe_export_dir(".\x00\\elsewhere") != "")
	testing.expect(t, host_safe_export_dir("\\\\.\\C:\\") != "")
	testing.expect(t, host_safe_export_dir("src\\host.odin") != "")
	testing.expect(t, host_safe_export_dir("imgman-missing-export-directory-2468") != "")
}

@(test)
atomic_save_preserves_existing_files :: proc(t: ^testing.T) {
	counter: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&counter)
	directory := fmt.aprintf("bin\\host-test-%d-%d", win.GetCurrentProcessId(), counter)
	defer delete(directory)
	path := fmt.aprintf("%s\\disk-ñ-日本.img", directory)
	defer delete(path)
	wdir := win.utf8_to_utf16(directory, context.allocator)
	defer delete(wdir)
	wpath := win.utf8_to_utf16(path, context.allocator)
	defer delete(wpath)
	win.CreateDirectoryW(win.L("bin"), nil)
	if !testing.expect(t, bool(win.CreateDirectoryW(cast(win.LPCWSTR)raw_data(wdir), nil))) { return }
	defer {
		if host_exists(path) {
			win.SetFileAttributesW(cast(win.LPCWSTR)raw_data(wpath), win.FILE_ATTRIBUTE_NORMAL)
			testing.expect(t, bool(win.DeleteFileW(cast(win.LPCWSTR)raw_data(wpath))))
		}
		testing.expect(t, bool(win.RemoveDirectoryW(cast(win.LPCWSTR)raw_data(wdir))))
	}
	testing.expect(t, host_safe_export_dir(directory) == "")
	original := []u8{0, 1, 127, 128, 255}
	replacement := []u8{9, 8, 7, 6, 5, 4, 3}
	if !testing.expect_value(t, host_save(path, original), "") { return }
	data, err := host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, bytes.equal(data, original))
	delete(data)

	testing.expect(t, host_save(path, replacement, false) != "")
	data, err = host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, bytes.equal(data, original))
	delete(data)

	testing.expect_value(t, host_save(path, replacement), "")
	data, err = host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, bytes.equal(data, replacement))
	delete(data)

	if !testing.expect(t, bool(win.SetFileAttributesW(cast(win.LPCWSTR)raw_data(wpath), win.FILE_ATTRIBUTE_READONLY))) { return }
	testing.expect(t, host_save(path, original) != "")
	data, err = host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, bytes.equal(data, replacement))
	delete(data)
	if !testing.expect(t, bool(win.SetFileAttributesW(cast(win.LPCWSTR)raw_data(wpath), win.FILE_ATTRIBUTE_NORMAL))) { return }

	locked := win.CreateFileW(cast(win.LPCWSTR)raw_data(wpath), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if !testing.expect(t, locked != win.INVALID_HANDLE_VALUE) { return }
	testing.expect(t, host_save(path, original) != "")
	win.CloseHandle(locked)
	data, err = host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, bytes.equal(data, replacement))
	delete(data)

	testing.expect_value(t, host_save(path, nil), "")
	data, err = host_read(path)
	testing.expect_value(t, err, "")
	testing.expect(t, len(data) == 0)
	delete(data)
	entries, list_err := host_children(directory)
	defer host_release_children(entries)
	testing.expect_value(t, list_err, "")
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 { testing.expect_value(t, entries[0].name, "disk-ñ-日本.img") }
}
