"""Independent, standard-library-only validation of imgMan's FAT12 images."""

import argparse
from pathlib import Path
import struct
import sys


# total sectors: (sectors/cluster, root entries, sectors/FAT, sectors/track, media)
FORMATS = {
    720: (2, 112, 2, 9, 0xFD),
    1440: (2, 112, 3, 9, 0xF9),
    2880: (1, 224, 9, 18, 0xF0),
    5760: (2, 240, 9, 36, 0xF0),
}
EXPECTED_FILES = {
    "README.TXT": b"Created and edited by imgMan.\r\n",
    "EMPTY.BIN": b"",
    "DATA.BIN": bytes((i * 73 + 19) % 256 for i in range(6001)),
    "DOCS/NOTE.TXT": b"A file in a subdirectory.\r\n",
    "RENAMED.TXT": b"Renamed successfully.\r\n",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


class Disk:
    def __init__(self, data):
        self.data = data
        require(len(data) >= 512, "truncated boot sector")
        require(data[510:512] == b"\x55\xaa", "missing boot signature")
        require(u16(data, 11) == 512, "bytes per sector must be 512")
        require(u16(data, 14) == 1 and data[16] == 2, "invalid reserved/FAT count")
        require(u16(data, 26) == 2 and u32(data, 28) == 0, "invalid heads/hidden sectors")
        self.sectors = u16(data, 19)
        require(self.sectors in FORMATS, "unsupported image sector count")
        require(u32(data, 32) == 0, "unexpected 32-bit sector count")
        require(len(data) == self.sectors * 512, "image length differs from BPB")
        self.spc, self.root_count, self.spf, spt, media = FORMATS[self.sectors]
        require(data[13] == self.spc, "incorrect cluster size")
        require(u16(data, 17) == self.root_count, "incorrect root entry count")
        require(u16(data, 22) == self.spf, "incorrect sectors per FAT")
        require(u16(data, 24) == spt and data[21] == media, "incorrect geometry/media")
        self.fat = data[512 : (1 + self.spf) * 512]
        require(self.fat == data[(1 + self.spf) * 512 : (1 + 2 * self.spf) * 512],
                "FAT copies differ")
        require(self.fat[:3] == bytes((media, 0xFF, 0xFF)), "invalid FAT reserved entries")
        self.root_offset = (1 + 2 * self.spf) * 512
        self.data_offset = self.root_offset + self.root_count * 32
        self.cluster_bytes = self.spc * 512
        self.cluster_count = (len(data) - self.data_offset) // self.cluster_bytes
        require(self.cluster_count < 4085, "volume is not FAT12")
        require((self.cluster_count + 2) * 3 <= len(self.fat) * 2, "FAT too small")
        self.owners = {}
        self.files = {}
        self.directories = set()
        self.entry_offsets = {}

    def fat_entry(self, cluster):
        offset = cluster * 3 // 2
        pair = u16(self.fat, offset)
        return (pair >> 4) if cluster & 1 else (pair & 0xFFF)

    def chain(self, first, owner):
        if first == 0:
            return []
        result = []
        cluster = first
        while True:
            require(2 <= cluster < self.cluster_count + 2, f"{owner}: cluster out of range")
            require(cluster not in self.owners, f"{owner}: cyclic or cross-linked chain")
            self.owners[cluster] = owner
            result.append(cluster)
            value = self.fat_entry(cluster)
            if value >= 0xFF8:
                return result
            require(2 <= value < 0xFF0, f"{owner}: free, bad or reserved cluster in chain")
            cluster = value

    def cluster_offset(self, cluster):
        return self.data_offset + (cluster - 2) * self.cluster_bytes

    def directory(self, offsets, prefix, cluster, parent):
        seen = set()
        dots = set()
        for offset in offsets:
            entry = self.data[offset : offset + 32]
            if entry[0] == 0:
                break
            if entry[0] == 0xE5 or entry[11] == 0x0F:
                continue
            attr = entry[11]
            if attr & 0x08:
                continue
            base = entry[:8].decode("cp437").rstrip()
            extension = entry[8:11].decode("cp437").rstrip()
            name = base + ("." + extension if extension else "")
            require(name not in seen, f"{prefix}: duplicate short name {name}")
            seen.add(name)
            first, size = u16(entry, 26), u32(entry, 28)
            require(u16(entry, 20) == 0, f"{name}: FAT12 high cluster word must be zero")
            if name in (".", ".."):
                require(bool(prefix) and attr & 0x10 and size == 0, "invalid dot entry")
                require(first == (cluster if name == "." else parent), "incorrect dot cluster")
                dots.add(name)
                continue
            path = prefix + name
            self.entry_offsets[path] = offset
            chain = self.chain(first, path)
            if attr & 0x10:
                require(first != 0 and size == 0, f"{path}: invalid directory entry")
                self.directories.add(path)
                child_offsets = [self.cluster_offset(c) + i
                                 for c in chain for i in range(0, self.cluster_bytes, 32)]
                self.directory(child_offsets, path + "/", first, cluster)
            else:
                needed = (size + self.cluster_bytes - 1) // self.cluster_bytes
                require(len(chain) == needed, f"{path}: allocation does not match file size")
                content = b"".join(self.data[self.cluster_offset(c) :
                                             self.cluster_offset(c) + self.cluster_bytes]
                                   for c in chain)
                self.files[path] = content[:size]
        if prefix:
            require(dots == {".", ".."}, f"{prefix}: missing dot entries")

    def verify(self, fixtures=False):
        self.directory(range(self.root_offset, self.data_offset, 32), "", 0, 0)
        for cluster in range(2, self.cluster_count + 2):
            value = self.fat_entry(cluster)
            require(value in (0, 0xFF7) or cluster in self.owners,
                    f"unreferenced allocated cluster {cluster}")
        if fixtures:
            require(self.files == EXPECTED_FILES, "fixture file names or contents differ")
            require(self.directories == {"DOCS"}, "fixture directory names differ")
        return len(self.owners) * self.cluster_bytes, self.cluster_count * self.cluster_bytes


def set_fat(data, disk, cluster, value):
    for copy in range(2):
        offset = (1 + copy * disk.spf) * 512 + cluster * 3 // 2
        pair = u16(data, offset)
        pair = (pair & 0x000F) | (value << 4) if cluster & 1 else (pair & 0xF000) | value
        struct.pack_into("<H", data, offset, pair)


def corruption_checks(disk):
    mutations = []
    mutations.append(("truncated image", disk.data[:-512]))
    changed = bytearray(disk.data)
    changed[(1 + disk.spf) * 512 + 3] ^= 1
    mutations.append(("FAT mismatch", changed))
    file_offset = disk.entry_offsets["DATA.BIN"]
    first = u16(disk.data, file_offset + 26)
    changed = bytearray(disk.data)
    set_fat(changed, disk, first, first)
    mutations.append(("cyclic chain", changed))
    changed = bytearray(disk.data)
    struct.pack_into("<H", changed, disk.entry_offsets["README.TXT"] + 26, first)
    mutations.append(("cross-linked files", changed))
    changed = bytearray(disk.data)
    struct.pack_into("<I", changed, file_offset + 28, 0xFFFFFFFF)
    mutations.append(("oversized file", changed))
    changed = bytearray(disk.data)
    struct.pack_into("<H", changed, file_offset + 26, 0)
    mutations.append(("missing file chain", changed))
    changed = bytearray(disk.data)
    free = next(c for c in range(2, disk.cluster_count + 2) if disk.fat_entry(c) == 0)
    set_fat(changed, disk, free, 0xFFF)
    mutations.append(("orphan cluster", changed))
    for name, data in mutations:
        try:
            Disk(data).verify()
        except ValueError:
            continue
        raise ValueError(f"checker accepted {name}")
    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="*", type=Path)
    parser.add_argument("--fixtures", action="store_true", help="also verify known fixture contents")
    args = parser.parse_args()
    paths = args.images or sorted((Path(__file__).resolve().parents[1] / "bin/fixtures").glob("*.img"))
    require(bool(paths), "no image files found")
    if args.fixtures:
        require(len(paths) == 4, "expected four fixture images")
    checked_sectors = set()
    for path in paths:
        disk = Disk(path.read_bytes())
        used, total = disk.verify(args.fixtures)
        checks = corruption_checks(disk) if args.fixtures else 0
        checked_sectors.add(disk.sectors)
        print(f"PASS {path.name}: {len(disk.files)} files, {used}/{total} bytes, {checks} corruption checks")
    if args.fixtures:
        require(checked_sectors == set(FORMATS), "fixtures do not cover every supported size")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, struct.error) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
