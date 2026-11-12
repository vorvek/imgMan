package fat12

import "core:strings"
import "core:time"

Format :: enum { KB360, KB720, MB144, MB288 }

Image :: struct {
    data: []u8,
    format: Format,
    cluster_bytes: int,
    cluster_count: int,
    fat_offset: int,
    fat_bytes: int,
    root_offset: int,
    root_entries: int,
    data_offset: int,
}

Entry :: struct {
    name: string,
    directory: bool,
    size: u32,
    cluster: u16,
    offset: int,
    attributes: u8,
    modified_date: u16,
    modified_time: u16,
}

Geometry :: struct { sectors, spc, roots, fat_sectors, tracks, spt: int, media: u8 }
geometries := [Format]Geometry {
    .KB360 = {720, 2, 112, 2, 40, 9, 0xfd},
    .KB720 = {1440, 2, 112, 3, 80, 9, 0xf9},
    .MB144 = {2880, 1, 224, 9, 80, 18, 0xf0},
    .MB288 = {5760, 2, 240, 9, 80, 36, 0xf0},
}

u16_at :: proc(data: []u8, off: int) -> u16 { return u16(data[off]) | u16(data[off+1])<<8 }
u32_at :: proc(data: []u8, off: int) -> u32 { return u32(u16_at(data, off)) | u32(u16_at(data, off+2))<<16 }
write16 :: proc(data: []u8, off: int, v: u16) { data[off] = u8(v&255); data[off+1] = u8(v>>8) }
write32 :: proc(data: []u8, off: int, v: u32) { write16(data,off,u16(v&65535)); write16(data,off+2,u16(v>>16)) }

format_name :: proc(img: ^Image) -> string {
    switch img.format {
    case .KB360: return "360 KB"
    case .KB720: return "720 KB"
    case .MB144: return "1.44 MB"
    case .MB288: return "2.88 MB"
    }
    return "Unknown"
}

create :: proc(format: Format) -> (Image, string) {
    if format < .KB360 || format > .MB288 { return {}, "Unsupported floppy format." }
    g := geometries[format]
    data := make([]u8, g.sectors*512)
    data[0], data[1], data[2] = 0xeb, 0x3c, 0x90
    copy(data[3:11], "imgMan  ")
    write16(data,11,512)
    data[13] = u8(g.spc)
    write16(data,14,1)
    data[16] = 2
    write16(data,17,u16(g.roots))
    write16(data,19,u16(g.sectors))
    data[21] = g.media
    write16(data,22,u16(g.fat_sectors))
    write16(data,24,u16(g.spt))
    write16(data,26,2)
    data[38] = 0x29
    write32(data,39,u32(time.now()._nsec & 0xffffffff))
    copy(data[43:54], "NO NAME    ")
    copy(data[54:62], "FAT12   ")
    // A non-system disk prints a message and waits for a key before rebooting.
    boot := [?]u8{0xfa,0x31,0xc0,0x8e,0xd8,0x8e,0xc0,0x8e,0xd0,0xbc,0x00,0x7c,0xfb,0xfc,0xbe,0x65,0x7c,0xac,0x84,0xc0,0x74,0x09,0xb4,0x0e,0xbb,0x07,0x00,0xcd,0x10,0xeb,0xf2,0x31,0xc0,0xcd,0x16,0xcd,0x19,0xeb,0xfe}
    copy(data[62:],boot[:])
    copy(data[101:],"Non-system disk. Remove disk and press a key.\r\n\x00")
    data[510], data[511] = 0x55, 0xaa
    for f in 0..<2 {
        off := 512+f*g.fat_sectors*512
        data[off], data[off+1], data[off+2] = g.media,0xff,0xff
    }
    img, err := parse(data)
    if err != "" { delete(data); return {},err }
    return img,""
}

parse :: proc(data: []u8) -> (Image, string) {
    if len(data)<512 { return {},"The image is shorter than a boot sector." }
    format: Format
    found := false
    for g, f in geometries { if len(data)==g.sectors*512 { format=f; found=true; break } }
    if !found { return {},"Unsupported image size. Use a raw 360 KB, 720 KB, 1.44 MB or 2.88 MB floppy image." }
    if u16_at(data,11)!=512 || data[13]==0 || (data[13]&(data[13]-1))!=0 || data[16]!=2 || u16_at(data,14)==0 || u16_at(data,17)==0 || u16_at(data,22)==0 {
        return {},"Invalid or unsupported FAT12 BIOS parameter block."
    }
    if int(u16_at(data,19))*512!=len(data) || u32_at(data,28)!=0 || u16_at(data,26)!=2 || int(u16_at(data,24))!=geometries[format].spt {
        return {},"The FAT12 geometry does not match this floppy image."
    }
    roots := int(u16_at(data,17))
    root_sectors := (roots*32+511)/512
    fat_off := int(u16_at(data,14))*512
    fat_bytes := int(u16_at(data,22))*512
    root_off := fat_off+fat_bytes*2
    data_off := root_off+root_sectors*512
    if data_off >= len(data) { return {},"The filesystem metadata extends beyond the image." }
    cluster_bytes := int(data[13])*512
    clusters := (len(data)-data_off)/cluster_bytes
    if clusters<1 || clusters>=4085 || (clusters+2)*3+1 > fat_bytes*2 { return {},"The image does not contain a valid FAT12 allocation table." }
    if data[fat_off]!=data[21] || data[fat_off+1]!=255 || data[fat_off+2]!=255 { return {},"Invalid reserved FAT12 entries." }
    for i in 0..<fat_bytes { if data[fat_off+i]!=data[fat_off+fat_bytes+i] { return {},"The two FAT copies disagree. Repair the image before editing it." } }
    return Image{data,format,cluster_bytes,clusters,fat_off,fat_bytes,root_off,roots,data_off},""
}

open :: proc(data: []u8) -> (Image, string) {
    img, err := parse(data)
    if err!="" { return {},err }
    if err=validate(&img); err!="" { return {},err }
    img.data=make([]u8,len(data)); copy(img.data,data)
    return img,""
}

destroy :: proc(img: ^Image) { delete(img.data); img^={} }

fat_get :: proc(img: ^Image, cluster: u16) -> u16 {
    off:=img.fat_offset+int(cluster)*3/2
    v:=u16_at(img.data,off)
    if cluster&1!=0 { return v>>4 }
    return v&0xfff
}

fat_set :: proc(img: ^Image, cluster, value: u16) {
    for f in 0..<2 {
        off:=img.fat_offset+f*img.fat_bytes+int(cluster)*3/2
        v:=u16_at(img.data,off)
        if cluster&1!=0 { v=(v&0x000f)|(value<<4) } else { v=(v&0xf000)|(value&0x0fff) }
        write16(img.data,off,v)
    }
}

cluster_offset :: proc(img: ^Image,c:u16)->int { return img.data_offset+(int(c)-2)*img.cluster_bytes }

chain :: proc(img: ^Image, first: u16) -> ([]u16,string) {
    if first==0 { return nil,"" }
    result:=make([dynamic]u16)
    current:=first
    for len(result)<=img.cluster_count {
        if current<2 || int(current)>=img.cluster_count+2 { delete(result); return nil,"A cluster chain points outside the image." }
        for c in result { if c==current { delete(result); return nil,"A cluster chain contains a loop." } }
        append(&result,current)
        next:=fat_get(img,current)
        if next>=0xff8 { return result[:],"" }
        if next<2 || next>=0xff0 { delete(result); return nil,"A cluster chain contains a free, bad or reserved cluster." }
        current=next
    }
    delete(result)
    return nil,"A cluster chain is too long."
}

directory_offsets :: proc(img: ^Image, directory: u16)->([]int,string) {
    if directory==0 {
        result:=make([]int,img.root_entries)
        for &off,i in result { off=img.root_offset+i*32 }
        return result,""
    }
    clusters,err:=chain(img,directory)
    if err!="" { return nil,err }
    defer delete(clusters)
    result:=make([]int,len(clusters)*img.cluster_bytes/32)
    i:=0
    for c in clusters { for j in 0..<img.cluster_bytes/32 { result[i]=cluster_offset(img,c)+j*32; i+=1 } }
    return result,""
}

decode_name :: proc(data: []u8,off:int)->string {
    name:[12]u8
    n:=0
    for i in 0..<8 { if data[off+i]!=32 { name[n]=data[off+i]; if n==0&&name[n]==5 { name[n]=0xe5 }; n+=1 } }
    if data[off+8]!=32 { name[n]='.'; n+=1; for i in 8..<11 { if data[off+i]!=32 { name[n]=data[off+i];n+=1 } } }
    cp437 :: "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "
    builder:=strings.builder_make()
    for c in name[:n] {
        r:=rune(c)
        if c>=128 { index:=0;for mapped in cp437 { if index==int(c)-128 { r=mapped;break };index+=1 } }
        strings.write_rune(&builder,r)
    }
    return strings.to_string(builder)
}

entry_at :: proc(img:^Image,off:int)->Entry {
    d:=img.data
    return Entry{decode_name(d,off),d[off+11]&0x10!=0,u32_at(d,off+28),u16_at(d,off+26),off,d[off+11],u16_at(d,off+24),u16_at(d,off+22)}
}

list :: proc(img: ^Image, directory:u16=0)->([]Entry,string) {
    offsets,err:=directory_offsets(img,directory)
    if err!="" { return nil,err }
    defer delete(offsets)
    result:=make([dynamic]Entry)
    for off in offsets {
        d:=img.data
        if d[off]==0 { break }
        if d[off]==0xe5 || d[off+11]&0x08!=0 || d[off]=='.' { continue }
        append(&result,entry_at(img,off))
    }
    return result[:],""
}

entries_free :: proc(entries:[]Entry) { for e in entries { delete(e.name) }; delete(entries) }

validate_directory :: proc(img:^Image,directory,parent:u16,used:[]bool,depth:int)->string {
    if depth>128 { return "The image has too many nested directories." }
    offsets,err:=directory_offsets(img,directory)
    if err!="" { return err }; defer delete(offsets)
    if directory!=0 {
        off:=offsets[0]
        if img.data[off]!='.' || img.data[off+1]!=' ' || img.data[off+11]&0x10==0 || u16_at(img.data,off+26)!=directory || img.data[off+32]!='.' || img.data[off+33]!='.' || img.data[off+43]&0x10==0 || u16_at(img.data,off+58)!=parent { return "A directory has invalid parent links." }
    }
    names:=make(map[[11]u8]bool); defer delete(names)
    for off,i in offsets {
        d:=img.data
        if d[off]==0 { break }
        if d[off]==0xe5 || d[off+11]&0x08!=0 { continue }
        if d[off]=='.' { if directory!=0 && i<2 { continue };return "A directory contains an invalid DOS filename." }
        if !valid_raw_name(d[off:off+11]) { return "A directory contains an invalid DOS filename." }
        name:[11]u8;copy(name[:],d[off:off+11])
        for &c in name { c=upper(c) }
        if names[name] { return "A directory contains duplicate DOS filenames." }; names[name]=true
        if u16_at(d,off+20)!=0 { return "A FAT12 directory entry has an invalid high cluster number." }
        first:=u16_at(d,off+26)
        isdir:=d[off+11]&0x10!=0
        size:=u32_at(d,off+28)
        if first==0 && (isdir||size!=0) { return "A file or directory is missing its cluster chain." }
        clusters,chain_err:=chain(img,first)
        if chain_err!="" { return chain_err }
        for c in clusters {
            if used[c] { delete(clusters); return "Files or directories share a cluster. Repair the image before editing it." }
            used[c]=true
        }
        bytes:=len(clusters)*img.cluster_bytes
        delete(clusters)
        if !isdir && u64(size)>u64(bytes) { return "A file is larger than its allocated cluster chain." }
        if isdir { if e:=validate_directory(img,first,directory,used,depth+1); e!="" { return e } }
    }
    return ""
}

validate :: proc(img:^Image)->string {
    for i in 2..<img.cluster_count+2 {
        value:=fat_get(img,u16(i))
        if value==0 || value==0xff7 || value>=0xff8 { continue }
        if value<2 || int(value)>=img.cluster_count+2 { return "The allocation table contains an invalid cluster reference." }
    }
    used:=make([]bool,img.cluster_count+2);defer delete(used)
    if err:=validate_directory(img,0,0,used,0);err!="" { return err }
    for i in 2..<img.cluster_count+2 {
        value:=fat_get(img,u16(i))
        if value!=0 && value!=0xff7 && !used[i] { return "The image contains lost cluster chains. Repair the image before editing it." }
    }
    return ""
}

entry_valid :: proc(img:^Image,e:Entry)->bool {
    if e.offset<img.root_offset || e.offset+32>len(img.data) || e.offset%32!=0 { return false }
    if img.data[e.offset]==0 || img.data[e.offset]==0xe5 || img.data[e.offset+11]&8!=0 { return false }
    n:=decode_name(img.data,e.offset);defer delete(n)
    return n==e.name && u16_at(img.data,e.offset+26)==e.cluster && u32_at(img.data,e.offset+28)==e.size && img.data[e.offset+11]==e.attributes && e.directory==(e.attributes&0x10!=0)
}

read_file :: proc(img:^Image,e:Entry)->([]u8,string) {
    if !entry_valid(img,e) { return nil,"The file entry is no longer valid." }
    if e.directory { return nil,"Select a file, not a directory." }
    clusters,err:=chain(img,e.cluster)
    if err!="" { return nil,err };defer delete(clusters)
    if u64(e.size)>u64(len(clusters)*img.cluster_bytes) { return nil,"The file is larger than its cluster chain." }
    result:=make([]u8,int(e.size));cursor:=0
    for c in clusters {
        count:=min(img.cluster_bytes,len(result)-cursor)
        if count<=0 { break }
        off:=cluster_offset(img,c);copy(result[cursor:cursor+count],img.data[off:off+count]);cursor+=count
    }
    return result,""
}

usage :: proc(img:^Image)->(used,total:int) {
    if len(img.data)==0 { return }
    total=img.cluster_count*img.cluster_bytes
    for i in 2..<img.cluster_count+2 { if fat_get(img,u16(i))!=0 { used+=img.cluster_bytes } }
    return
}

dos_char :: proc(c:u8)->bool {
    if c>='A'&&c<='Z' || c>='0'&&c<='9' { return true }
    for v in "!#$%&'()-@^_`{}~" { if c==u8(v) { return true } }
    return false
}
upper :: proc(c:u8)->u8 { if c>='a'&&c<='z' { return c-32 };return c }

valid_raw_name :: proc(name:[]u8)->bool {
    if name[0]==' ' { return false }
    gap:=false
    for c,i in name {
        if i==8 { gap=false }
        if c==' ' { gap=true;continue }
        if gap { return false }
        if c>=128 || i==0&&c==5 { continue }
        if !dos_char(upper(c)) { return false }
    }
    return true
}

find_raw :: proc(img:^Image,directory:u16,name:[11]u8,except:int=-1)->(int,string) {
    offsets,err:=directory_offsets(img,directory);if err!="" { return -1,err };defer delete(offsets)
    for off in offsets {
        if img.data[off]==0 { break }
        if off==except || img.data[off]==0xe5 || img.data[off+11]&8!=0 { continue }
        match:=true
        for i in 0..<11 { if upper(img.data[off+i])!=upper(name[i]) { match=false;break } }
        if match { return off,"" }
    }
    return -1,""
}

make_name :: proc(img:^Image,directory:u16,name:string,except:int=-1)->([11]u8,string) {
    out:[11]u8;for &c in out { c=' ' }
    if name=="" || name=="." || name==".." { return out,"Enter a filename." }
    for c in name { if c=='/'||c=='\\'||c==':'||c==0 { return out,"Use a filename without path separators." } }
    dot:=-1
    for c,i in name { if c=='.' { dot=i } }
    base,ext:=name,""
    if dot>=0 { base=name[:dot];ext=name[dot+1:] }
    valid:=len(base)>0 && len(base)<=8 && len(ext)<=3
    for c in base { if c>127 || !dos_char(upper(u8(c))) { valid=false } }
    for c in ext { if c>127 || !dos_char(upper(u8(c))) { valid=false } }
    if valid {
        for c,i in base { out[i]=upper(u8(c)) };for c,i in ext { out[8+i]=upper(u8(c)) }
        return out,""
    }
    clean:[8]u8;count:=0
    for c in base {
        if count>=6 { break };if c==' '||c=='.' { continue }
        v:=u8('_');if c<128&&dos_char(upper(u8(c))) { v=upper(u8(c)) }
        clean[count]=v;count+=1
    }
    if count==0 { clean[0]='_';count=1 }
    ecount:=0
    for c in ext { if ecount==3 { break };if c==' '||c=='.' { continue };v:=u8('_');if c<128&&dos_char(upper(u8(c))) { v=upper(u8(c)) };out[8+ecount]=v;ecount+=1 }
    for suffix in 1..<1000000 {
        digits:[6]u8;n:=suffix;dc:=0
        for n>0 { digits[dc]=u8(n%10)+'0';n/=10;dc+=1 }
        prefix:=min(count,7-dc)
        for i in 0..<8 { out[i]=' ' };copy(out[:prefix],clean[:prefix]);out[prefix]='~'
        for i in 0..<dc { out[prefix+1+i]=digits[dc-1-i] }
        existing,err:=find_raw(img,directory,out,except);if err!="" { return out,err };if existing<0 { return out,"" }
    }
    return out,"No free DOS alias is available for this filename."
}

stamp :: proc(img:^Image,off:int,created:bool=false) {
    date,clock:=local_timestamp()
    write16(img.data,off+22,clock);write16(img.data,off+24,date)
    if created { write16(img.data,off+14,clock);write16(img.data,off+16,date);write16(img.data,off+18,date) }
}

allocate :: proc(img:^Image,count:int)->([]u16,string) {
    result:=make([]u16,count);n:=0
    for i in 2..<img.cluster_count+2 { if n==count { break };if fat_get(img,u16(i))==0 { result[n]=u16(i);n+=1 } }
    if n!=count { delete(result);return nil,"There is not enough free space in the image." }
    for c,i in result {
        next:=u16(0xfff);if i+1<count { next=result[i+1] };fat_set(img,c,next)
        off:=cluster_offset(img,c);for &b in img.data[off:off+img.cluster_bytes] { b=0 }
    }
    return result,""
}

free_chain :: proc(img:^Image,first:u16)->string {
    clusters,err:=chain(img,first);if err!="" { return err };defer delete(clusters)
    for c in clusters { fat_set(img,c,0) }
    return ""
}

free_slot :: proc(img:^Image,directory:u16)->(int,string) {
    offsets,err:=directory_offsets(img,directory);if err!="" { return 0,err };defer delete(offsets)
    for off,i in offsets {
        if img.data[off]==0 { if i+1<len(offsets) { img.data[offsets[i+1]]=0 };return off,"" }
        if img.data[off]==0xe5 { return off,"" }
    }
    if directory==0 { return 0,"The root directory is full. Use a subdirectory or remove an entry." }
    clusters,chain_err:=chain(img,directory);if chain_err!="" { return 0,chain_err };defer delete(clusters)
    more,alloc_err:=allocate(img,1);if alloc_err!="" { return 0,alloc_err };defer delete(more)
    fat_set(img,clusters[len(clusters)-1],more[0])
    return cluster_offset(img,more[0]),""
}

begin_edit :: proc(img:^Image)->(Image,string) {
    fresh,err:=parse(img.data);if err!="" { return {},err }
    if err=validate(&fresh);err!="" { return {},err }
    fresh.data=make([]u8,len(img.data));copy(fresh.data,img.data)
    return fresh,""
}

commit_edit :: proc(img,work:^Image)->string {
    if err:=validate(work);err!="" { return err }
    delete(img.data);img^=work^;work.data=nil
    return ""
}

directory_exists :: proc(img:^Image,target:u16,directory:u16=0,depth:int=0)->bool {
    if target==directory { return true }
    if depth>128 { return false }
    entries,err:=list(img,directory);if err!="" { return false };defer entries_free(entries)
    for e in entries { if e.directory && directory_exists(img,target,e.cluster,depth+1) { return true } }
    return false
}

put_file :: proc(img:^Image,directory:u16,name:string,data:[]u8,replace:bool=false)->string {
    work,err:=begin_edit(img);if err!="" { return err };defer destroy(&work)
    if !directory_exists(&work,directory) { return "The destination directory does not exist." }
    raw,name_err:=make_name(&work,directory,name);if name_err!="" { return name_err }
    off,find_err:=find_raw(&work,directory,raw);if find_err!="" { return find_err }
    if off>=0 {
        if !replace { return "A file with this DOS name already exists." }
        if work.data[off+11]&0x10!=0 { return "A directory already has this name." }
        if e:=free_chain(&work,u16_at(work.data,off+26));e!="" { return e }
    } else {
        slot,slot_err:=free_slot(&work,directory);if slot_err!="" { return slot_err };off=slot
    }
    if u64(len(data))>0xffffffff { return "The file is too large." }
    clusters,alloc_err:=allocate(&work,(len(data)+work.cluster_bytes-1)/work.cluster_bytes)
    if alloc_err!="" { return alloc_err };defer delete(clusters)
    for c,i in clusters { start:=i*work.cluster_bytes;count:=min(work.cluster_bytes,len(data)-start);target:=cluster_offset(&work,c);copy(work.data[target:target+count],data[start:start+count]) }
    for &b in work.data[off:off+32] { b=0 };copy(work.data[off:off+11],raw[:]);work.data[off+11]=0x20
    if len(clusters)>0 { write16(work.data,off+26,clusters[0]) }
    write32(work.data,off+28,u32(len(data)));stamp(&work,off,true)
    return commit_edit(img,&work)
}

mkdir :: proc(img:^Image,directory:u16,name:string)->string {
    work,err:=begin_edit(img);if err!="" { return err };defer destroy(&work)
    if !directory_exists(&work,directory) { return "The destination directory does not exist." }
    raw,name_err:=make_name(&work,directory,name);if name_err!="" { return name_err }
    found,find_err:=find_raw(&work,directory,raw);if find_err!="" { return find_err };if found>=0 { return "An entry with this DOS name already exists." }
    off,slot_err:=free_slot(&work,directory);if slot_err!="" { return slot_err }
    clusters,alloc_err:=allocate(&work,1);if alloc_err!="" { return alloc_err };defer delete(clusters)
    for &b in work.data[off:off+32] { b=0 };copy(work.data[off:off+11],raw[:]);work.data[off+11]=0x10;write16(work.data,off+26,clusters[0]);stamp(&work,off,true)
    start:=cluster_offset(&work,clusters[0])
    copy(work.data[start:start+11],".          ");work.data[start+11]=0x10;write16(work.data,start+26,clusters[0]);stamp(&work,start,true)
    copy(work.data[start+32:start+43],"..         ");work.data[start+43]=0x10;write16(work.data,start+58,directory);stamp(&work,start+32,true)
    return commit_edit(img,&work)
}

find_parent :: proc(img:^Image,target:int,directory:u16=0,depth:int=0)->(u16,bool) {
    if depth>128 { return 0,false }
    offsets,err:=directory_offsets(img,directory);if err!="" { return 0,false };defer delete(offsets)
    for off in offsets { if off==target { return directory,true } }
    entries,list_err:=list(img,directory);if list_err!="" { return 0,false };defer entries_free(entries)
    for e in entries { if e.directory { if p,ok:=find_parent(img,target,e.cluster,depth+1);ok { return p,true } } }
    return 0,false
}

erase_lfn :: proc(img:^Image,directory:u16,target:int) {
    offsets,err:=directory_offsets(img,directory);if err!="" { return };defer delete(offsets)
    for off,i in offsets {
        if off==target {
            for j:=i-1;j>=0;j-=1 { prev:=offsets[j];if img.data[prev]==0||img.data[prev]==0xe5||img.data[prev+11]!=0x0f { break };img.data[prev]=0xe5 }
            return
        }
    }
}

remove_internal :: proc(img:^Image,e:Entry,directory:u16)->string {
    if e.directory {
        entries,err:=list(img,e.cluster);if err!="" { return err };defer entries_free(entries)
        for child in entries { if e2:=remove_internal(img,child,e.cluster);e2!="" { return e2 } }
    }
    if err:=free_chain(img,e.cluster);err!="" { return err }
    erase_lfn(img,directory,e.offset);img.data[e.offset]=0xe5
    return ""
}

remove :: proc(img:^Image,e:Entry)->string {
    if !entry_valid(img,e) { return "The entry is no longer valid." }
    work,err:=begin_edit(img);if err!="" { return err };defer destroy(&work)
    parent,found:=find_parent(&work,e.offset);if !found { return "The entry is not in a directory." }
    if err=remove_internal(&work,e,parent);err!="" { return err }
    return commit_edit(img,&work)
}

rename :: proc(img:^Image,e:Entry,name:string)->string {
    if !entry_valid(img,e) { return "The entry is no longer valid." }
    work,err:=begin_edit(img);if err!="" { return err };defer destroy(&work)
    parent,found:=find_parent(&work,e.offset);if !found { return "The entry is not in a directory." }
    raw,name_err:=make_name(&work,parent,name,e.offset);if name_err!="" { return name_err }
    exists,find_err:=find_raw(&work,parent,raw,e.offset);if find_err!="" { return find_err };if exists>=0 { return "An entry with this DOS name already exists." }
    erase_lfn(&work,parent,e.offset);copy(work.data[e.offset:e.offset+11],raw[:]);work.data[e.offset+12]=0
    return commit_edit(img,&work)
}
