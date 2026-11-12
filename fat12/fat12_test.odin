#+test
package fat12

import "core:testing"
import "core:fmt"
import "core:mem"
import win "core:sys/windows"

bytes :: proc(s:string)->[]u8 { return transmute([]u8)s }
same_bytes :: proc(a,b:[]u8)->bool { if len(a)!=len(b) { return false };for v,i in a { if v!=b[i] { return false } };return true }
snapshot :: proc(img:^Image)->[]u8 { result:=make([]u8,len(img.data));copy(result,img.data);return result }
get_entry :: proc(img:^Image,directory:u16,name:string)->Entry {
    entries,err:=list(img,directory);assert(err=="")
    result:Entry
    for e in entries { if e.name==name { result=e } else { delete(e.name) } }
    delete(entries)
    return result
}

@(test)
test_standard_geometry_roundtrip :: proc(t:^testing.T) {
    expected:= [Format]int{.KB360=362496,.KB720=730112,.MB144=1457664,.MB288=2931712}
    for g,f in geometries {
        img,err:=create(f);testing.expect_value(t,err,"");defer destroy(&img)
        testing.expect_value(t,len(img.data),g.sectors*512)
        testing.expect_value(t,u16_at(img.data,11),u16(512))
        testing.expect_value(t,u16_at(img.data,17),u16(g.roots))
        testing.expect_value(t,img.data[13],u8(g.spc))
        testing.expect_value(t,u16_at(img.data,22),u16(g.fat_sectors))
        testing.expect_value(t,u16_at(img.data,510),u16(0xaa55))
        used,total:=usage(&img);testing.expect_value(t,used,0);testing.expect_value(t,total,expected[f])
        loaded,load_err:=open(img.data);testing.expect_value(t,load_err,"");defer destroy(&loaded)
        testing.expect(t,same_bytes(img.data,loaded.data))
        loaded.data[100]=0
        testing.expect(t,img.data[100]!=0,"open must own a copy")
    }
}

@(test)
test_files_directories_and_recursive_delete :: proc(t:^testing.T) {
    img,err:=create(.MB144);testing.expect_value(t,err,"");defer destroy(&img)
    payload:=make([]u8,4097);defer delete(payload);for &b,i in payload { b=u8(i%251) }
    testing.expect_value(t,put_file(&img,0,"DATA.BIN",payload),"")
    testing.expect_value(t,put_file(&img,0,"EMPTY.TXT",nil),"")
    testing.expect_value(t,mkdir(&img,0,"DOCS"),"")
    folder:=get_entry(&img,0,"DOCS");defer delete(folder.name)
    testing.expect_value(t,mkdir(&img,folder.cluster,"SUB"),"")
    sub:=get_entry(&img,folder.cluster,"SUB");defer delete(sub.name)
    testing.expect_value(t,put_file(&img,sub.cluster,"NOTES.TXT",bytes("contents")),"")
    e:=get_entry(&img,0,"DATA.BIN");defer delete(e.name)
    data,read_err:=read_file(&img,e);defer delete(data)
    testing.expect_value(t,read_err,"");testing.expect(t,same_bytes(data,payload))
    testing.expect_value(t,remove(&img,folder),"")
    testing.expect_value(t,validate(&img),"")
    used,_:=usage(&img);testing.expect_value(t,used,4608)
    testing.expect_value(t,remove(&img,e),"")
    used,_=usage(&img);testing.expect_value(t,used,0)
}

@(test)
test_aliases_collision_rename :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,put_file(&img,0,"long filename.txt",nil),"")
    testing.expect_value(t,put_file(&img,0,"long filenames.txt",nil),"")
    a:=get_entry(&img,0,"LONGFI~1.TXT");defer delete(a.name)
    b:=get_entry(&img,0,"LONGFI~2.TXT");defer delete(b.name)
    testing.expect_value(t,a.name,"LONGFI~1.TXT");testing.expect_value(t,b.name,"LONGFI~2.TXT")
    before:=snapshot(&img);defer delete(before)
    testing.expect(t,rename(&img,a,"LONGFI~2.TXT")!="")
    testing.expect(t,same_bytes(before,img.data))
    testing.expect_value(t,rename(&img,a,"RENAMED.TXT"),"")
    testing.expect(t,put_file(&img,0,"renamed.txt",nil)!="")
    testing.expect_value(t,put_file(&img,0,"renamed.txt",bytes("new"),true),"")
    e:=get_entry(&img,0,"RENAMED.TXT");defer delete(e.name)
    data,err:=read_file(&img,e);defer delete(data);testing.expect_value(t,err,"");testing.expect_value(t,string(data),"new")
}

@(test)
test_disk_full_and_failed_replace_are_atomic :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    _,capacity:=usage(&img)
    data:=make([]u8,capacity);defer delete(data)
    testing.expect_value(t,put_file(&img,0,"FULL.BIN",data),"")
    original:=snapshot(&img);defer delete(original)
    testing.expect(t,put_file(&img,0,"EXTRA.BIN",bytes("x"))!="")
    testing.expect(t,same_bytes(original,img.data))
    oversized:=make([]u8,capacity+1);defer delete(oversized)
    testing.expect(t,put_file(&img,0,"FULL.BIN",oversized,true)!="")
    testing.expect(t,same_bytes(original,img.data))
    testing.expect_value(t,put_file(&img,0,"FULL.BIN",bytes("smaller"),true),"")
    used,_:=usage(&img);testing.expect_value(t,used,1024)
}

@(test)
test_full_root_and_directory_growth :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,mkdir(&img,0,"DIR"),"")
    dir:=get_entry(&img,0,"DIR");defer delete(dir.name)
    for i in 0..<img.root_entries-1 { name:=fmt.aprintf("F%07d",i);testing.expect_value(t,put_file(&img,0,name,nil),"");delete(name) }
    before:=snapshot(&img);defer delete(before)
    testing.expect(t,put_file(&img,0,"OVERFLOW",nil)!="");testing.expect(t,same_bytes(before,img.data))
    for i in 0..<40 { name:=fmt.aprintf("F%07d",i);testing.expect_value(t,put_file(&img,dir.cluster,name,nil),"");delete(name) }
    entries,err:=list(&img,dir.cluster);defer entries_free(entries);testing.expect_value(t,err,"");testing.expect_value(t,len(entries),40)
    testing.expect_value(t,validate(&img),"")
}

@(test)
test_malformed_geometry_and_fat_mismatch :: proc(t:^testing.T) {
    img,_:=create(.MB144);defer destroy(&img)
    bad:=snapshot(&img);defer delete(bad)
    bad[11]=0;bad[12]=0
    broken,err:=open(bad);testing.expect(t,err!="");destroy(&broken)
    copy(bad,img.data);bad[img.fat_offset+img.fat_bytes+3]=1
    broken,err=open(bad);testing.expect(t,err!="");destroy(&broken)
    copy(bad,img.data);write16(bad,22,1)
    broken,err=open(bad);testing.expect(t,err!="");destroy(&broken)
    broken,err=open(img.data[:len(img.data)-1]);testing.expect(t,err!="");destroy(&broken)
}

@(test)
test_loops_crosslinks_and_truncated_chains_rejected :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,put_file(&img,0,"A.BIN",bytes("aaa")),"")
    testing.expect_value(t,put_file(&img,0,"B.BIN",bytes("bbb")),"")
    a:=get_entry(&img,0,"A.BIN");defer delete(a.name)
    b:=get_entry(&img,0,"B.BIN");defer delete(b.name)
    original:=snapshot(&img);defer delete(original)
    fat_set(&img,a.cluster,a.cluster)
    _,err:=open(img.data);testing.expect(t,err!="")
    before:=snapshot(&img);defer delete(before)
    testing.expect(t,put_file(&img,0,"C.BIN",nil)!="");testing.expect(t,same_bytes(before,img.data))
    copy(img.data,original);write16(img.data,b.offset+26,a.cluster)
    _,err=open(img.data);testing.expect(t,err!="")
    copy(img.data,original);write32(img.data,a.offset+28,2000)
    _,err=open(img.data);testing.expect(t,err!="")
    copy(img.data,original);fat_set(&img,a.cluster,0xff7)
    _,err=open(img.data);testing.expect(t,err!="")
}

@(test)
test_invalid_destination_and_stale_entry :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,put_file(&img,0,"A.TXT",bytes("text")),"")
    a:=get_entry(&img,0,"A.TXT");defer delete(a.name)
    before:=snapshot(&img);defer delete(before)
    testing.expect(t,put_file(&img,a.cluster,"B.TXT",nil)!="")
    testing.expect(t,mkdir(&img,a.cluster,"DIR")!="")
    testing.expect(t,same_bytes(before,img.data))
    testing.expect_value(t,rename(&img,a,"NEW.TXT"),"")
    testing.expect(t,remove(&img,a)!="")
    data,err:=read_file(&img,a);delete(data);testing.expect(t,err!="")
}

@(test)
test_boot_sector_preserved_during_edits :: proc(t:^testing.T) {
    img,_:=create(.KB720);defer destroy(&img)
    for i in 62..<510 { img.data[i]=u8(i%251) }
    before:=snapshot(&img);defer delete(before)
    testing.expect_value(t,put_file(&img,0,"TEST.TXT",bytes("test")),"")
    testing.expect(t,same_bytes(before[:512],img.data[:512]))
    testing.expect(t,same_bytes(img.data[img.fat_offset:img.fat_offset+img.fat_bytes],img.data[img.fat_offset+img.fat_bytes:img.fat_offset+2*img.fat_bytes]))
}

@(test)
test_lfn_slots_removed_on_rename_and_delete :: proc(t:^testing.T) {
    img,_:=create(.MB144);defer destroy(&img)
    off:=img.root_offset
    img.data[off]=0x41;img.data[off+11]=0x0f
    copy(img.data[off+32:off+43],"SHORT   TXT");img.data[off+43]=0x20
    a:=get_entry(&img,0,"SHORT.TXT");defer delete(a.name)
    testing.expect_value(t,rename(&img,a,"OTHER.TXT"),"")
    testing.expect_value(t,img.data[off],u8(0xe5))
    img.data[off]=0x41
    b:=get_entry(&img,0,"OTHER.TXT");defer delete(b.name)
    testing.expect_value(t,remove(&img,b),"")
    testing.expect_value(t,img.data[off],u8(0xe5))
    testing.expect_value(t,img.data[off+32],u8(0xe5))
}

@(test)
test_owned_allocations_are_released :: proc(t:^testing.T) {
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    context.allocator=mem.tracking_allocator(&tracker)
    {
        img,_:=create(.KB360);defer destroy(&img)
        testing.expect_value(t,mkdir(&img,0,"DIR"),"")
        dir:=get_entry(&img,0,"DIR");defer delete(dir.name)
        testing.expect_value(t,put_file(&img,dir.cluster,"A.TXT",bytes("text")),"")
        entries,err:=list(&img,dir.cluster);defer entries_free(entries);testing.expect_value(t,err,"")
        data,read_err:=read_file(&img,entries[0]);defer delete(data);testing.expect_value(t,read_err,"")
        loaded,load_err:=open(img.data);defer destroy(&loaded);testing.expect_value(t,load_err,"")
        testing.expect_value(t,remove(&img,dir),"")
    }
    testing.expect_value(t,len(tracker.allocation_map),0)
}

@(test)
test_malformed_names_and_directory_terminator :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,put_file(&img,0,"FILE.TXT",bytes("text")),"")
    original:=snapshot(&img);defer delete(original)
    bad_names:=[?]string{"..      TXT","A/B     TXT","A\\B     TXT","A:B     TXT","A\x00B     TXT","A B     TXT","        TXT"}
    for name in bad_names {
        copy(img.data,original);copy(img.data[img.root_offset:img.root_offset+11],name)
        _,err:=open(img.data);testing.expect(t,err!="",name)
    }
    copy(img.data,original)
    end:=img.root_offset+32
    copy(img.data[end+32:end+43],"GARBAGE TXT")
    img.data[end+43]=0x20
    testing.expect_value(t,put_file(&img,0,"SECOND.TXT",nil),"")
    entries,err:=list(&img);defer entries_free(entries)
    testing.expect_value(t,err,"");testing.expect_value(t,len(entries),2)
    testing.expect_value(t,img.data[end+32],u8(0))
}

@(test)
test_oem_filename_is_decoded_as_utf8 :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    off:=img.root_offset
    copy(img.data[off:off+11],"A       TXT");img.data[off]=0x82;img.data[off+1]=0xe1;img.data[off+11]=0x20
    loaded,err:=open(img.data);defer destroy(&loaded);testing.expect_value(t,err,"")
    entries,list_err:=list(&loaded);defer entries_free(entries);testing.expect_value(t,list_err,"")
    testing.expect_value(t,len(entries),1);testing.expect_value(t,entries[0].name,"éß.TXT")
}

@(test)
test_lowercase_short_name_collisions :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    testing.expect_value(t,put_file(&img,0,"FILE.TXT",nil),"")
    off:=img.root_offset
    copy(img.data[off:off+11],"file    txt")
    before:=snapshot(&img);defer delete(before)
    testing.expect(t,put_file(&img,0,"FILE.TXT",nil)!="")
    testing.expect(t,same_bytes(before,img.data))
    testing.expect_value(t,put_file(&img,0,"FILE.TXT",bytes("replaced"),true),"")
    entries,err:=list(&img);defer entries_free(entries)
    testing.expect_value(t,err,"");testing.expect_value(t,len(entries),1)
    copy(img.data[off+32:off+64],img.data[off:off+32])
    copy(img.data[off+32:off+43],"file    txt")
    _,err=open(img.data);testing.expect(t,err!="")
}

@(test)
test_orphan_chains_rejected_and_bad_clusters_preserved :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    fat_set(&img,2,0xfff)
    _,err:=open(img.data);testing.expect(t,err!="")
    fat_set(&img,2,3);fat_set(&img,3,2)
    _,err=open(img.data);testing.expect(t,err!="")
    fat_set(&img,2,0xff7);fat_set(&img,3,0)
    loaded,load_err:=open(img.data);defer destroy(&loaded);testing.expect_value(t,load_err,"")
    testing.expect_value(t,put_file(&loaded,0,"FILE.TXT",bytes("contents")),"")
    testing.expect_value(t,fat_get(&loaded,2),u16(0xff7))
    used,_:=usage(&loaded);testing.expect_value(t,used,2048)
}

@(test)
test_file_timestamp_uses_windows_local_time :: proc(t:^testing.T) {
    img,_:=create(.KB360);defer destroy(&img)
    before,after:win.SYSTEMTIME
    GetLocalTime(&before)
    testing.expect_value(t,put_file(&img,0,"TIME.TXT",nil),"")
    GetLocalTime(&after)
    entry:=get_entry(&img,0,"TIME.TXT");defer delete(entry.name)
    observed:=[6]u16{1980+entry.modified_date>>9,entry.modified_date>>5&15,entry.modified_date&31,entry.modified_time>>11,entry.modified_time>>5&63,entry.modified_time&31}
    lower:=[6]u16{before.year,before.month,before.day,before.hour,before.minute,before.second/2}
    upper:=[6]u16{after.year,after.month,after.day,after.hour,after.minute,after.second/2}
    testing.expect(t,observed==lower || observed==upper)
    testing.expect_value(t,u16_at(img.data,entry.offset+14),entry.modified_time)
    testing.expect_value(t,u16_at(img.data,entry.offset+16),entry.modified_date)
    testing.expect_value(t,u16_at(img.data,entry.offset+18),entry.modified_date)
}
