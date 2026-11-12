# imgMan

A small Windows floppy image manager written in Odin. Create and edit ordinary IBM PC FAT12 disk images for retro PCs and emulators, including MiSTer's ao486 and z486 cores.

imgMan uses a native Win32 interface with a dark theme, classic text menus, a distinct icon toolbar, Windows system file icons, drag and drop, and a capacity bar showing used and total data bytes.

## Disk formats

| Format | Image bytes | Cylinders | Heads | Sectors per track |
| --- | ---: | ---: | ---: | ---: |
| 5.25-inch 360 KB | 368,640 | 40 | 2 | 9 |
| 3.5-inch 720 KB | 737,280 | 80 | 2 | 9 |
| 3.5-inch 1.44 MB | 1,474,560 | 80 | 2 | 18 |
| 3.5-inch 2.88 MB | 2,949,120 | 80 | 2 | 36 |

Images contain 512-byte sectors in a flat `.img` file, with a BIOS parameter block, two FAT copies, a root directory, and a data area. The layouts follow [Microsoft's standard floppy format table](https://ftp.zx.net.nz/pub/Patches/ftp.microsoft.com/MISC/KB/en-us/75/131.HTM). Filesystem metadata uses some space, so usable capacity is smaller than the image file.

New images are formatted data disks. They do not contain DOS system files. Existing boot sectors are preserved when editing an image.

## Build

Requires Windows 10 or 11, an x64 [Odin compiler](https://odin-lang.org/docs/install/) on `PATH`, and the MSVC toolchain and Windows SDK from Visual Studio's **Desktop development with C++** workload. No third-party GUI library is required.

```powershell
.\build.ps1
.\bin\imgMan.exe
```

`build.bat` is a wrapper for the same build. Use `-DebugBuild` for debug symbols.

## Use

Create a new image at the desired size, or open an existing `.img` file. Add files with the toolbar or drag files and folders from Windows Explorer into the current image folder. Double-click a folder to open it. Extract files back to Windows, rename entries, create folders, or delete entries from the image. Save writes the current image; Save As creates a separate image file.

DOS filenames use the 8.3 convention. Long host filenames receive a DOS-compatible short name during import. The capacity display measures allocated data clusters, including folder storage, against the data area's usable capacity.

Hover over a toolbar icon for its action and shortcut. Use Ctrl+N/O/S for New/Open/Save, Ctrl+Shift+S for Save As, Ctrl+I to import, Ctrl+E to extract, Ctrl+Shift+N for a folder, F2 to rename, Delete to remove, and Backspace to go up. An image path can also be passed on the command line.

Imports are transactional: if a batch does not fit, the image stays unchanged. Saves use a flushed temporary file before replacing the destination. Damaged or unsupported images are rejected before editing. Existing long filenames are shown by their DOS aliases; imported names are written as 8.3 entries.

## Verify

Python 3 is required only for the independent image checker.

```powershell
.\build.ps1 -Test
```

This runs the Odin FAT12 and Windows file-operation tests, generates sample images in all four sizes, then independently checks their BPBs, FAT mirrors, allocation chains, directory entries, and file contents with Python. Generated images and binaries stay in `bin/` and are not source files. These checks do not establish physical floppy drive or MiSTer hardware compatibility.

## License

Copyright (C) 2026 vorvek. Licensed under the [GNU General Public License, version 3](LICENSE).
