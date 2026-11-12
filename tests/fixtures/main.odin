package main

import "core:fmt"
import "core:os"
import fat12 "../../fat12"

check :: proc(error: string) {
    if error != "" {
        fmt.eprintln(error)
        os.exit(1)
    }
}

bytes :: proc(value: string) -> []u8 { return transmute([]u8)value }

find_entry :: proc(image: ^fat12.Image, directory: u16, name: string) -> fat12.Entry {
    entries, error := fat12.list(image, directory)
    check(error)
    for entry in entries {
        if entry.name == name {
            result := entry
            result.name = name
            fat12.entries_free(entries)
            return result
        }
    }
    fat12.entries_free(entries)
    fmt.eprintln("Missing fixture entry:", name)
    os.exit(1)
}

main :: proc() {
    if error := os.make_directory_all("bin/fixtures"); error != nil {
        fmt.eprintln(error)
        os.exit(1)
    }
    formats := [?]fat12.Format{.KB360, .KB720, .MB144, .MB288}
    names := [?]string{"360", "720", "1440", "2880"}
    payload := make([]u8, 6001)
    defer delete(payload)
    for &byte, i in payload { byte = u8((i * 73 + 19) % 256) }
    for format, i in formats {
        image, error := fat12.create(format)
        check(error)
        check(fat12.put_file(&image, 0, "README.TXT", bytes("To be replaced.\r\n")))
        check(fat12.put_file(&image, 0, "EMPTY.BIN", nil))
        check(fat12.put_file(&image, 0, "DATA.BIN", payload))
        check(fat12.mkdir(&image, 0, "DOCS"))
        directory := find_entry(&image, 0, "DOCS")
        check(fat12.put_file(&image, directory.cluster, "NOTE.TXT", bytes("A file in a subdirectory.\r\n")))
        check(fat12.put_file(&image, 0, "README.TXT", bytes("Created and edited by imgMan.\r\n"), true))
        check(fat12.put_file(&image, 0, "ORIGINAL.TXT", bytes("Renamed successfully.\r\n")))
        entry := find_entry(&image, 0, "ORIGINAL.TXT")
        check(fat12.rename(&image, entry, "RENAMED.TXT"))
        check(fat12.mkdir(&image, 0, "REMOVED"))
        removed := find_entry(&image, 0, "REMOVED")
        check(fat12.put_file(&image, removed.cluster, "DELETE.BIN", payload))
        check(fat12.remove(&image, removed))
        filename := fmt.aprintf("bin/fixtures/%s.img", names[i])
        if error := os.write_entire_file(filename, image.data); error != nil {
            fmt.eprintln(error)
            os.exit(1)
        }
        fmt.println("Wrote", filename)
        delete(filename)
        fat12.destroy(&image)
    }
}
