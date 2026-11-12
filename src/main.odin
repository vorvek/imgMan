#+build windows
package imgman

import "core:fmt"
import "core:strings"
import "base:runtime"
import "core:os"
import win "core:sys/windows"
import fat "../fat12"

foreign import shell "system:Shell32.lib"
Stock_Icon :: struct { size: u32, icon: win.HICON, system_index, index: i32, path: [260]u16 }
foreign shell { SHGetStockIconInfo :: proc "system" (id, flags: u32, info: ^Stock_Icon) -> i32 --- }
foreign import user "system:User32.lib"
foreign user {
    DrawIconEx :: proc "system" (dc: win.HDC, x,y: i32, icon: win.HICON, width,height: i32, step: u32, brush: win.HBRUSH, flags: u32) -> win.BOOL ---
    DrawFocusRect :: proc "system" (dc: win.HDC, rect: ^win.RECT) -> win.BOOL ---
}

BG :: win.COLORREF(0x202020)
PANEL :: win.COLORREF(0x292929)
TEXT :: win.COLORREF(0xeeeeee)
MUTED :: win.COLORREF(0xaaaaaa)
ACCENT :: win.COLORREF(0x906030)
ID_NEW :: 101
ID_OPEN :: 102
ID_SAVE :: 103
ID_SAVE_AS :: 104
ID_ADD :: 105
ID_ADD_FOLDER :: 106
ID_EXTRACT :: 107
ID_UP :: 108
ID_MKDIR :: 109
ID_RENAME :: 110
ID_DELETE :: 111

Button :: struct { handle: win.HWND, id: int, label: string, icon: win.HICON, width: i32 }
Location :: struct { cluster: u16, name: string }
App :: struct {
    window, view, breadcrumb: win.HWND,
    instance: win.HINSTANCE,
    font: win.HFONT,
    background, panel: win.HBRUSH,
    icons: win.HIMAGELIST,
    buttons: [dynamic]Button,
    disk: fat.Image,
    entries: []fat.Entry,
    locations: [dynamic]Location,
    path: string,
    dirty: bool,
    scale: f32,
    status: string,
}
app: App

w :: proc(s: string) -> [^]u16 { return raw_data(win.utf8_to_utf16(s)) }
px :: proc(n: i32) -> i32 { return i32(f32(n)*app.scale) }
stock_icon :: proc(id: u32) -> win.HICON {
    info := Stock_Icon{size=size_of(Stock_Icon)}
    SHGetStockIconInfo(id, 0x100 | 0x1, &info)
    return info.icon
}
dark_window :: proc(hwnd: win.HWND) {
    enabled: win.BOOL = true
    win.DwmSetWindowAttribute(hwnd, 20, &enabled, size_of(enabled))
    win.SetWindowTheme(hwnd, win.L("DarkMode_Explorer"), nil)
}
set_text :: proc(hwnd: win.HWND, text: string) { win.SetWindowTextW(hwnd, cast(win.LPCWSTR)w(text)) }
fill :: proc(dc: win.HDC, rect: win.RECT, color: win.COLORREF) {
    brush := win.CreateSolidBrush(color)
    r := rect
    win.FillRect(dc, &r, brush)
    win.DeleteObject(cast(win.HGDIOBJ)brush)
}
draw_text :: proc(dc: win.HDC, text: string, rect: win.RECT, color:=TEXT, flags: win.DrawTextFormat = (.DT_LEFT | .DT_VCENTER | .DT_SINGLELINE)) {
    r := rect
    win.SetBkMode(dc, .TRANSPARENT)
    win.SetTextColor(dc, color)
    win.SelectObject(dc, cast(win.HGDIOBJ)app.font)
    win.DrawTextW(dc, cast(win.LPCWSTR)w(text), -1, &r, flags)
}
control :: proc(parent: win.HWND, class, text: string, style: u32, id: int) -> win.HWND {
    h := win.CreateWindowExW(0, cast(win.LPCWSTR)w(class), cast(win.LPCWSTR)w(text), win.WS_CHILD | win.WS_VISIBLE | style,
        0,0,0,0,parent,cast(win.HMENU)uintptr(id),app.instance,nil)
    win.SendMessageW(h, win.WM_SETFONT, cast(win.WPARAM)app.font, 1)
    dark_window(h)
    return h
}
add_button :: proc(id: int, label: string) {
    b := Button{id=id,label=label,width=36}
    b.handle = control(app.window,"BUTTON",label,win.BS_OWNERDRAW | win.WS_TABSTOP,id)
    append(&app.buttons,b)
    add_tooltip(b.handle,label)
}
Draw_Item :: struct { kind, id, item, action, state: u32, hwnd: win.HWND, dc: win.HDC, rect: win.RECT, data: uintptr }
draw_button :: proc(item: ^Draw_Item) {
    if item.kind==1 { draw_menu_item(item); return }
    if item.kind==3 {
        fill(item.dc,item.rect,PANEL)
        formats:=[?]string{"360 KB  -  5.25 inch","720 KB  -  3.5 inch","1.44 MB  -  3.5 inch","2.88 MB  -  3.5 inch"}
        if item.item<4 {
            if item.state & 1 != 0 { fill(item.dc,item.rect,ACCENT) }
            r:=item.rect; r.left+=px(8)
            draw_text(item.dc,formats[item.item],r)
        }
        return
    }
    color := PANEL
    if item.state & 1 != 0 { color = ACCENT }
    fill(item.dc,item.rect,color)
    r := item.rect
    r.left += px(10)
    if item.id>=ID_NEW && item.id<=ID_DELETE {
        draw_toolbar_icon(item.dc,int(item.id),(r.right-px(24))/2,(r.bottom-px(24))/2,px(24),item.state & 4!=0)
        if item.state & 0x10 != 0 { DrawFocusRect(item.dc,&item.rect) }
        return
    }
    color = TEXT
    if item.state & 4 != 0 { color=MUTED }
    buffer: [128]u16
    n := win.GetWindowTextW(item.hwnd,&buffer[0],len(buffer))
    text := win.utf16_to_utf8(buffer[:n]) or_else ""
    draw_text(item.dc,text,r,color)
    if item.state & 0x10 != 0 { DrawFocusRect(item.dc,&item.rect) }
}

Prompt :: struct { window, edit, combo: win.HWND, done: bool, result: int, text: string, initial: string, kind: int }
prompt: Prompt
prompt_proc :: proc "system" (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
    context = runtime.default_context()
    switch msg {
    case win.WM_CLOSE: prompt.done=true; return 0
    case win.WM_COMMAND:
        id:=int(wp & 0xffff)
        if id==1 || id==2 || id==3 { prompt.result=id; prompt.done=true }
    case win.WM_DRAWITEM: draw_button(cast(^Draw_Item)uintptr(lp)); return 1
    case win.WM_CTLCOLORSTATIC,win.WM_CTLCOLOREDIT,win.WM_CTLCOLORLISTBOX:
        win.SetTextColor(cast(win.HDC)wp,TEXT); win.SetBkColor(cast(win.HDC)wp,PANEL)
        return cast(win.LRESULT)uintptr(app.panel)
    case win.WM_ERASEBKGND:
        r: win.RECT; win.GetClientRect(hwnd,&r); win.FillRect(cast(win.HDC)wp,&r,app.panel); return 1
    case win.WM_PAINT:
        ps: win.PAINTSTRUCT; dc:=win.BeginPaint(hwnd,&ps)
        r:=win.RECT{px(22),px(16),px(538),px(104)}
        draw_text(dc,prompt.text,r,TEXT,(.DT_LEFT | .DT_WORDBREAK))
        win.EndPaint(hwnd,&ps); return 0
    }
    return win.DefWindowProcW(hwnd,msg,wp,lp)
}
ask :: proc(title, text: string, kind: int=0, initial: string="") -> (int,string) {
    prompt=Prompt{text=text,kind=kind,initial=initial}
    r: win.RECT; win.GetWindowRect(app.window,&r)
    height:=i32(200) if kind==2 else i32(250)
    prompt.window=win.CreateWindowExW(win.WS_EX_DLGMODALFRAME,win.L("imgManPrompt"),cast(win.LPCWSTR)w(title),
        win.WS_CAPTION | win.WS_SYSMENU,(r.left+r.right-px(560))/2,(r.top+r.bottom-px(height))/2,px(560),px(height),app.window,nil,app.instance,nil)
    dark_window(prompt.window)
    if kind==1 {
        prompt.edit=control(prompt.window,"EDIT",initial,win.WS_TABSTOP | win.ES_AUTOHSCROLL | win.WS_BORDER,10)
        win.MoveWindow(prompt.edit,px(22),px(106),px(500),px(28),true)
        win.SendMessageW(prompt.edit,win.EM_SETSEL,0,-1)
    }
    if kind==2 {
        prompt.combo=control(prompt.window,"COMBOBOX","",win.WS_TABSTOP | win.CBS_DROPDOWNLIST | win.CBS_OWNERDRAWFIXED | win.CBS_HASSTRINGS | win.WS_VSCROLL,11)
        win.SendMessageW(prompt.combo,win.CB_SETITEMHEIGHT,~uintptr(0),win.LPARAM(px(24)))
        win.SendMessageW(prompt.combo,win.CB_SETITEMHEIGHT,0,win.LPARAM(px(24)))
        win.MoveWindow(prompt.combo,px(22),px(46),px(500),px(180),true)
        formats := [?]string{"360 KB  -  5.25 inch","720 KB  -  3.5 inch","1.44 MB  -  3.5 inch","2.88 MB  -  3.5 inch"}
        for label in formats {
            win.SendMessageW(prompt.combo,win.CB_ADDSTRING,0,cast(win.LPARAM)uintptr(w(label)))
        }
        win.SendMessageW(prompt.combo,win.CB_SETCURSEL,2,0)
    }
    yes_label := "OK"
    if kind==3 { yes_label="Save" }
    if kind==4 { yes_label="Continue" }
    if kind==2 { yes_label="Create" }
    ok:=control(prompt.window,"BUTTON",yes_label,win.BS_OWNERDRAW | win.WS_TABSTOP,1)
    button_y:=px(114) if kind==2 else px(164)
    win.MoveWindow(ok,px(316),button_y,px(96),px(30),true)
    if kind!=0 {
        cancel:=control(prompt.window,"BUTTON","Cancel",win.BS_OWNERDRAW | win.WS_TABSTOP,2)
        win.MoveWindow(cancel,px(426),button_y,px(96),px(30),true)
    }
    if kind==3 {
        discard:=control(prompt.window,"BUTTON","Discard",win.BS_OWNERDRAW | win.WS_TABSTOP,3)
        win.MoveWindow(discard,px(22),px(164),px(96),px(30),true)
    }
    win.EnableWindow(app.window,false)
    win.ShowWindow(prompt.window,win.SW_SHOW)
    win.SetFocus(prompt.edit if kind==1 else (prompt.combo if kind==2 else ok))
    message: win.MSG
    for !prompt.done && win.GetMessageW(&message,nil,0,0)>0 {
        if message.message==win.WM_KEYDOWN && message.wParam==win.VK_ESCAPE { prompt.done=true; break }
        if message.message==win.WM_KEYDOWN && message.wParam==win.VK_RETURN { prompt.result=1; break }
        if !win.IsDialogMessageW(prompt.window,&message) { win.TranslateMessage(&message); win.DispatchMessageW(&message) }
    }
    value: string
    if prompt.result==1 && kind==1 {
        buf: [260]u16; n:=win.GetWindowTextW(prompt.edit,&buf[0],len(buf))
        value=win.utf16_to_utf8(buf[:n],context.allocator) or_else ""
    }
    result:=prompt.result
    if prompt.result==1 && kind==2 { result=10+int(win.SendMessageW(prompt.combo,win.CB_GETCURSEL,0,0)) }
    win.EnableWindow(app.window,true)
    win.DestroyWindow(prompt.window)
    win.SetForegroundWindow(app.window)
    win.SetFocus(app.view)
    return result,value
}
report :: proc(error: string) -> bool {
    if error=="" { return false }
    ask("imgMan",error)
    return true
}
directory :: proc() -> u16 { if len(app.locations)==0 { return 0 }; return app.locations[len(app.locations)-1].cluster }
set_status :: proc(text: string) { delete(app.status); app.status=strings.clone(text); win.InvalidateRect(app.window,nil,false) }
clear_locations :: proc() { for loc in app.locations { delete(loc.name) }; clear(&app.locations) }
selected :: proc() -> [dynamic]int {
    result:=make([dynamic]int)
    index:i32=-1
    for { index=win.ListView_GetNextItem(app.view,index,win.LVNI_SELECTED); if index<0 { break }; append(&result,int(index)) }
    return result
}
refresh :: proc() {
    fat.entries_free(app.entries)
    error: string
    app.entries,error=fat.list(&app.disk,directory())
    if report(error) { return }
    win.SendMessageW(app.view,win.WM_SETREDRAW,0,0)
    win.ListView_DeleteAllItems(app.view)
    for entry,i in app.entries {
        item:=win.LVITEMW{mask=win.LVIF_TEXT | win.LVIF_IMAGE,iItem=i32(i),pszText=w(entry.name),iImage=0 if entry.directory else 1}
        win.ListView_InsertItem(app.view,&item)
        size := "" if entry.directory else fmt.tprintf("%d bytes",entry.size)
        kind := "File folder" if entry.directory else "File"
        date := ""
        if entry.modified_date!=0 {
            d,t:=entry.modified_date,entry.modified_time
            date=fmt.tprintf("%04d-%02d-%02d  %02d:%02d",1980+(d>>9),(d>>5)&15,d&31,t>>11,(t>>5)&63)
        }
        values := [?]string{size,kind,date}
        for value,j in values {
            sub:=win.LVITEMW{iSubItem=i32(j+1),pszText=w(value)}
            win.SendMessageW(app.view,win.LVM_SETITEMTEXTW,win.WPARAM(i),cast(win.LPARAM)uintptr(&sub))
        }
    }
    win.SendMessageW(app.view,win.WM_SETREDRAW,1,0)
    win.InvalidateRect(app.view,nil,true)
    path:="A:\\"
    for loc in app.locations { path=fmt.tprintf("%s%s\\",path,loc.name) }
    set_text(app.breadcrumb,path)
    title:=app.path
    if title=="" { title="Untitled.img" }
    set_text(app.window,fmt.tprintf("%s%s - imgMan","*" if app.dirty else "",title))
    win.InvalidateRect(app.window,nil,false)
}
save_image :: proc(save_as: bool=false) -> bool {
    path:=app.path
    chosen: string
    if save_as || path=="" {
        chosen=host_choose_file(app.window,true,"Save floppy image","Untitled.img" if path=="" else path)
        defer delete(chosen)
        if chosen=="" { return false }
        path=chosen
        if report(host_save(path,app.disk.data)) { return false }
        delete(app.path); app.path=strings.clone(path)
    } else if report(host_save(path,app.disk.data)) { return false }
    app.dirty=false
    set_status("Image saved")
    refresh()
    return true
}
can_replace :: proc() -> bool {
    if !app.dirty { return true }
    result,_:=ask("Unsaved image","Save changes to this image before continuing?",3)
    if result==3 { return true }
    if result==1 { return save_image() }
    return false
}
new_image :: proc(format: fat.Format) {
    disk,error:=fat.create(format)
    if report(error) { return }
    fat.destroy(&app.disk); app.disk=disk
    delete(app.path); app.path=""
    clear_locations(); app.dirty=true
    set_status("Drop files or folders here to add them")
    refresh()
}
open_image :: proc(path: string) {
    bytes,error:=host_read(path)
    if report(error) { return }; defer delete(bytes)
    disk,err:=fat.open(bytes)
    if report(err) { return }
    if !can_replace() { fat.destroy(&disk); return }
    fat.destroy(&app.disk); app.disk=disk
    delete(app.path); app.path=strings.clone(path)
    clear_locations(); app.dirty=false
    set_status("Image opened")
    refresh()
}
base_name :: proc(path: string) -> string {
    start:=0
    for c,i in path { if c=='\\' || c=='/' { start=i+1 } }
    return path[start:]
}
parent_name :: proc(path: string) -> string {
    for i:=len(path)-1; i>=0; i-=1 { if path[i]=='\\' || path[i]=='/' { return path[:i+1] } }
    return ""
}

import_path :: proc(path: string, dir: u16, depth: int=0) -> string {
    if depth>64 { return "Folder nesting is too deep." }
    attributes:=win.GetFileAttributesW(cast(win.LPCWSTR)w(path))
    if attributes==win.INVALID_FILE_ATTRIBUTES { return fmt.tprintf("Cannot read %s",path) }
    if attributes & win.FILE_ATTRIBUTE_REPARSE_POINT!=0 { return "Symbolic links and junctions cannot be imported." }
    name:=base_name(path)
    if attributes & win.FILE_ATTRIBUTE_DIRECTORY!=0 {
        before,error:=fat.list(&app.disk,dir); if error!="" { return error }; defer fat.entries_free(before)
        error=fat.mkdir(&app.disk,dir,name); if error!="" { return error }
        after,err:=fat.list(&app.disk,dir); if err!="" { return err }; defer fat.entries_free(after)
        cluster:u16
        for entry in after {
            found:=false
            for old in before { if old.offset==entry.offset { found=true; break } }
            if !found { cluster=entry.cluster; break }
        }
        if cluster==0 { return "Could not locate the imported folder." }
        children,e:=host_children(path); if e!="" { return e }; defer host_release_children(children)
        for child in children { if e:=import_path(child.path,cluster,depth+1); e!="" { return e } }
    } else {
        data,error:=host_read(path); if error!="" { return error }; defer delete(data)
        error=fat.put_file(&app.disk,dir,name,data)
        if error!="" {
            entries,e:=fat.list(&app.disk,dir); if e!="" { return e }; defer fat.entries_free(entries)
            for entry in entries {
                if !entry.directory && strings.equal_fold(entry.name,name) {
                    result,_:=ask("Replace file",fmt.tprintf("Replace %s in the image?",entry.name),4)
                    if result!=1 { return "Import cancelled. No files were added." }
                    return fat.put_file(&app.disk,dir,name,data,true)
                }
            }
            return error
        }
    }
    return ""
}
import_paths :: proc(paths: []string) {
    if len(paths)==0 { return }
    backup:=make([]u8,len(app.disk.data)); copy(backup,app.disk.data); defer delete(backup)
    for path in paths {
        if error:=import_path(path,directory()); error!="" {
            copy(app.disk.data,backup)
            report(error); refresh(); return
        }
    }
    app.dirty=true
    set_status("Files added. Names use DOS 8.3 aliases.")
    refresh()
}
extract_entry :: proc(entry: fat.Entry, parent: string, depth: int=0) -> string {
    if depth>64 { return "Folder nesting is too deep." }
    if !host_safe_leaf(entry.name) { return fmt.tprintf("This DOS name cannot be safely exported to Windows: %s",entry.name) }
    if error:=host_safe_export_dir(parent); error!="" { return error }
    path:=fmt.tprintf("%s\\%s",parent,entry.name)
    if entry.directory {
        if host_exists(path) { return fmt.tprintf("The output folder already exists: %s",path) }
        if !win.CreateDirectoryW(cast(win.LPCWSTR)w(path),nil) { return fmt.tprintf("Could not create %s",path) }
        children,error:=fat.list(&app.disk,entry.cluster); if error!="" { return error }; defer fat.entries_free(children)
        for child in children { if err:=extract_entry(child,path,depth+1); err!="" { return err } }
    } else {
        data,error:=fat.read_file(&app.disk,entry); if error!="" { return error }; defer delete(data)
        overwrite:=false
        if host_exists(path) {
            result,_:=ask("Replace exported file",fmt.tprintf("Replace %s on your PC?",path),4)
            if result!=1 { return "Export cancelled." }
            overwrite=true
        }
        return host_save(path,data,overwrite)
    }
    return ""
}
activate_selected :: proc() {
    indices:=selected(); defer delete(indices)
    if len(indices)!=1 { return }
    entry:=app.entries[indices[0]]
    if entry.directory {
        append(&app.locations,Location{entry.cluster,strings.clone(entry.name)})
        refresh()
    }
}
command :: proc(id: int) {
    switch id {
    case ID_NEW:
        if !can_replace() { return }
        result,_:=ask("New floppy image","Disk size:",2)
        if result>=10 { new_image(fat.Format(result-10)) }
    case ID_OPEN:
        path:=host_choose_file(app.window,false,"Open floppy image",app.path); defer delete(path)
        if path!="" { open_image(path) }
    case ID_SAVE: save_image()
    case ID_SAVE_AS: save_image(true)
    case ID_ADD:
        paths:=host_choose_import(app.window); defer host_release_paths(paths)
        import_paths(paths)
    case ID_ADD_FOLDER:
        path:=host_choose_folder(app.window,parent_name(app.path)); defer delete(path)
        if path!="" { paths:=[1]string{path}; import_paths(paths[:]) }
    case ID_UP:
        if len(app.locations)>0 { delete(pop(&app.locations).name); refresh() }
    case ID_MKDIR:
        result,name:=ask("New folder","Folder name (long names receive a DOS 8.3 alias):",1); defer delete(name)
        if result==1 && !report(fat.mkdir(&app.disk,directory(),name)) { app.dirty=true; refresh() }
    case ID_RENAME:
        indices:=selected(); defer delete(indices)
        if len(indices)!=1 { set_status("Select one file or folder to rename"); return }
        entry:=app.entries[indices[0]]
        result,name:=ask("Rename","New name (long names receive a DOS 8.3 alias):",1,entry.name); defer delete(name)
        if result==1 && !report(fat.rename(&app.disk,entry,name)) { app.dirty=true; refresh() }
    case ID_DELETE:
        indices:=selected(); defer delete(indices)
        if len(indices)==0 { return }
        result,_:=ask("Delete from image",fmt.tprintf("Delete %d selected item(s) and any files inside their folders?",len(indices)),4)
        if result!=1 { return }
        backup:=make([]u8,len(app.disk.data)); copy(backup,app.disk.data); defer delete(backup)
        for i in indices { if error:=fat.remove(&app.disk,app.entries[i]); error!="" { copy(app.disk.data,backup); report(error); refresh(); return } }
        app.dirty=true; refresh()
    case ID_EXTRACT:
        indices:=selected(); defer delete(indices)
        if len(indices)==0 { set_status("Select files or folders to extract"); return }
        path:=host_choose_folder(app.window,parent_name(app.path)); defer delete(path)
        if path=="" { return }
        for i in indices { if error:=extract_entry(app.entries[i],path); error!="" { report(error); set_status("Export stopped; earlier items may have been exported"); return } }
        set_status("Selected files extracted")
    case ID_EXIT: win.SendMessageW(app.window,win.WM_CLOSE,0,0)
    case ID_SELECT_ALL:
        state:=win.LVITEMW{state=win.LVIS_SELECTED,stateMask=win.LVIS_SELECTED}
        win.SendMessageW(app.view,win.LVM_SETITEMSTATE,~uintptr(0),cast(win.LPARAM)uintptr(&state))
    case ID_ABOUT:
        ask("About imgMan","imgMan\nFloppy image manager\nCopyright (C) 2026 vorvek\nGNU General Public License v3")
    }
}

layout :: proc() {
    r: win.RECT; win.GetClientRect(app.window,&r)
    x:=px(12)
    for b,i in app.buttons {
        if i==4 || i==7 || i==8 { x+=px(12) }
        win.MoveWindow(b.handle,x,px(8),px(b.width),px(36),true)
        x+=px(b.width+3)
    }
    win.MoveWindow(app.breadcrumb,px(16),px(56),r.right-px(32),px(24),true)
    win.MoveWindow(app.view,px(12),px(86),r.right-px(24),r.bottom-px(154),true)
    win.ListView_SetColumnWidth(app.view,0,max(px(220),r.right-px(504)))
}
paint_main :: proc(hwnd: win.HWND) {
    ps: win.PAINTSTRUCT; dc:=win.BeginPaint(hwnd,&ps); defer win.EndPaint(hwnd,&ps)
    r: win.RECT; win.GetClientRect(hwnd,&r)
    fill(dc,r,BG)
    line:=win.RECT{0,r.bottom-px(56),r.right,r.bottom}
    fill(dc,line,PANEL)
    used,total:=fat.usage(&app.disk)
    label:=fmt.tprintf("%s  |  %d items",fat.format_name(&app.disk),len(app.entries))
    draw_text(dc,label,win.RECT{px(16),r.bottom-px(52),r.right/2,r.bottom-px(28)})
    draw_text(dc,app.status,win.RECT{px(16),r.bottom-px(28),r.right/2,r.bottom-px(6)},MUTED)
    bar:=win.RECT{max(r.right/2, r.right-px(470)),r.bottom-px(43),r.right-px(16),r.bottom-px(15)}
    fill(dc,bar,win.COLORREF(0x404040))
    progress:=bar
    if total>0 { progress.right=progress.left+i32(i64(bar.right-bar.left)*i64(used)/i64(total)); fill(dc,progress,ACCENT) }
    draw_text(dc,fmt.tprintf("%d / %d bytes",used,total),bar,TEXT,(.DT_CENTER | .DT_VCENTER | .DT_SINGLELINE))
}
list_proc :: proc "system" (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM, id: uintptr, data: win.DWORD_PTR) -> win.LRESULT {
    context=runtime.default_context()
    if msg==win.WM_GETDLGCODE && wp!=win.VK_TAB { return win.DefSubclassProc(hwnd,msg,wp,lp) | 4 }
    if msg==win.WM_NOTIFY { return win.SendMessageW(app.window,msg,wp,lp) }
    if msg==win.WM_PAINT && len(app.entries)==0 {
        result:=win.DefSubclassProc(hwnd,msg,wp,lp)
        dc:=win.GetDC(hwnd); r:win.RECT; win.GetClientRect(hwnd,&r)
        r.top=px(90); r.bottom=px(122)
        draw_text(dc,"Drop files or folders here",r,MUTED,(.DT_CENTER | .DT_SINGLELINE | .DT_VCENTER))
        win.ReleaseDC(hwnd,dc)
        return result
    }
    if msg==win.WM_KEYDOWN {
        switch wp {
        case win.VK_DELETE: command(ID_DELETE); return 0
        case win.VK_F2: command(ID_RENAME); return 0
        case win.VK_BACK: command(ID_UP); return 0
        case win.VK_RETURN: activate_selected(); return 0
        }
        if wp=='A' && win.GetKeyState(win.VK_CONTROL)<0 {
            state:=win.LVITEMW{state=win.LVIS_SELECTED,stateMask=win.LVIS_SELECTED}
            win.SendMessageW(hwnd,win.LVM_SETITEMSTATE,~uintptr(0),cast(win.LPARAM)uintptr(&state)); return 0
        }
    }
    if msg==win.WM_DROPFILES { win.SendMessageW(app.window,msg,wp,lp); return 0 }
    return win.DefSubclassProc(hwnd,msg,wp,lp)
}
window_proc :: proc "system" (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
    context=runtime.default_context()
    switch msg {
    case win.WM_COMMAND: command(int(wp & 0xffff)); return 0
    case win.WM_SIZE: if app.view!=nil { layout() }; return 0
    case win.WM_GETMINMAXINFO:
        info:=cast(^win.MINMAXINFO)uintptr(lp); info.ptMinTrackSize=win.POINT{px(920),px(480)}; return 0
    case win.WM_PAINT: paint_main(hwnd); return 0
    case win.WM_ERASEBKGND: return 1
    case win.WM_DRAWITEM: draw_button(cast(^Draw_Item)uintptr(lp)); return 1
    case win.WM_MEASUREITEM: measure_menu_item(cast(^Measure_Item)uintptr(lp)); return 1
    case win.WM_MENUCHAR: return menu_mnemonic(cast(win.HMENU)uintptr(lp),u8(wp & 0xff))
    case win.WM_CTLCOLORSTATIC:
        win.SetTextColor(cast(win.HDC)wp,TEXT); win.SetBkColor(cast(win.HDC)wp,BG); return cast(win.LRESULT)uintptr(app.background)
    case win.WM_NOTIFY:
        header:=cast(^win.NMHDR)uintptr(lp)
        if header.hwndFrom==app.view && header.code==u32(win.NM_DBLCLK & 0xffffffff) { activate_selected(); return 0 }
        if header.hwndFrom==win.ListView_GetHeader(app.view) && header.code==u32(win.NM_CUSTOMDRAW & 0xffffffff) {
            cd:=cast(^win.NMCUSTOMDRAW)uintptr(lp)
            if cd.dwDrawStage==win.CDDS_PREPAINT { return win.CDRF_NOTIFYITEMDRAW | win.CDRF_NOTIFYPOSTPAINT }
            if cd.dwDrawStage==win.CDDS_POSTPAINT {
                last,r:win.RECT
                win.SendMessageW(header.hwndFrom,win.HDM_GETITEMRECT,3,cast(win.LPARAM)uintptr(&last))
                win.GetClientRect(header.hwndFrom,&r)
                r.left=last.right
                if r.right>r.left { fill(cd.hdc,r,PANEL) }
                return win.CDRF_DODEFAULT
            }
            if cd.dwDrawStage==win.CDDS_ITEMPREPAINT {
                fill(cd.hdc,cd.rc,PANEL)
                names:=[?]string{"Name","Size","Type","Modified"}
                rect:=cd.rc; rect.left+=px(10)
                if int(cd.dwItemSpec)<len(names) { draw_text(cd.hdc,names[cd.dwItemSpec],rect,MUTED) }
                return win.CDRF_SKIPDEFAULT
            }
        }
    case win.WM_DROPFILES:
        drop:=cast(win.HDROP)wp
        count:=win.DragQueryFileW(drop,0xffffffff,nil,0)
        paths:=make([]string,int(count))
        for i in 0..<count {
            n:=win.DragQueryFileW(drop,i,nil,0)
            buf:=make([]u16,int(n)+1); win.DragQueryFileW(drop,i,raw_data(buf),n+1)
            paths[i]=win.utf16_to_utf8(buf[:n],context.allocator) or_else ""; delete(buf)
        }
        win.DragFinish(drop)
        import_paths(paths); host_release_paths(paths); return 0
    case win.WM_CLOSE:
        if can_replace() { win.DestroyWindow(hwnd) }; return 0
    case win.WM_DESTROY: win.PostQuitMessage(0); return 0
    }
    return win.DefWindowProcW(hwnd,msg,wp,lp)
}

main :: proc() {
    app.scale=1
    win.SetProcessDPIAware()
    dc:=win.GetDC(nil); dpi:=win.GetDeviceCaps(dc,88); win.ReleaseDC(nil,dc)
    if dpi>0 { app.scale=f32(dpi)/96 }
    win.CoInitializeEx(nil,.APARTMENTTHREADED)
    defer win.CoUninitialize()
    version:=win.OSVERSIONINFOEXW{dwOSVersionInfoSize=size_of(win.OSVERSIONINFOEXW)}
    win.RtlGetVersion(&version)
    if version.dwBuildNumber>=18362 {
        theme:=win.LoadLibraryW(win.L("uxtheme.dll"))
        if theme!=nil {
            ordinal: uintptr=135
            mode:=cast(proc "system" (i32)->i32)win.GetProcAddress(theme,transmute(cstring)ordinal)
            if mode!=nil { mode(2) }
        }
    }
    common:=win.INITCOMMONCONTROLSEX{dwSize=size_of(win.INITCOMMONCONTROLSEX),dwICC=win.ICC_LISTVIEW_CLASSES}
    win.InitCommonControlsEx(&common)
    app.instance=cast(win.HINSTANCE)win.GetModuleHandleW(nil)
    app.background=win.CreateSolidBrush(BG); app.panel=win.CreateSolidBrush(PANEL)
    app.font=win.CreateFontW(-px(14),0,0,0,400,0,0,0,1,0,0,5,0,win.L("Segoe UI"))
    cursor_id: uintptr=32512
    cls:=win.WNDCLASSEXW{cbSize=size_of(win.WNDCLASSEXW),lpfnWndProc=window_proc,hInstance=app.instance,
        hCursor=win.LoadCursorW(nil,transmute(win.LPCWSTR)cursor_id),hbrBackground=app.background,lpszClassName=win.L("imgManWindow"),hIcon=stock_icon(6)}
    win.RegisterClassExW(&cls)
    cls.lpfnWndProc=prompt_proc; cls.lpszClassName=win.L("imgManPrompt"); cls.hbrBackground=app.panel
    win.RegisterClassExW(&cls)
    app.window=win.CreateWindowExW(0,win.L("imgManWindow"),win.L("imgMan"),win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN,
        win.CW_USEDEFAULT,win.CW_USEDEFAULT,px(1060),px(690),nil,nil,app.instance,nil)
    dark_window(app.window)
    create_menus()
    add_button(ID_NEW,"New image (Ctrl+N)")
    add_button(ID_OPEN,"Open image (Ctrl+O)")
    add_button(ID_SAVE,"Save (Ctrl+S)")
    add_button(ID_SAVE_AS,"Save as (Ctrl+Shift+S)")
    add_button(ID_ADD,"Add files (Ctrl+I)")
    add_button(ID_ADD_FOLDER,"Add folder")
    add_button(ID_EXTRACT,"Extract selected (Ctrl+E)")
    add_button(ID_UP,"Up one folder (Backspace)")
    add_button(ID_MKDIR,"New folder (Ctrl+Shift+N)")
    add_button(ID_RENAME,"Rename (F2)")
    add_button(ID_DELETE,"Delete (Del)")
    app.breadcrumb=control(app.window,"STATIC","A:\\",win.SS_LEFT,120)
    app.view=control(app.window,"SysListView32","",win.LVS_REPORT | win.LVS_SHOWSELALWAYS | win.WS_TABSTOP,130)
    win.ListView_SetExtendedListViewStyle(app.view,win.LVS_EX_FULLROWSELECT | win.LVS_EX_DOUBLEBUFFER)
    win.SendMessageW(app.view,win.LVM_SETBKCOLOR,0,win.LPARAM(BG)); win.ListView_SetTextBkColor(app.view,BG); win.ListView_SetTextColor(app.view,TEXT)
    win.SetWindowTheme(win.ListView_GetHeader(app.view),win.L(""),win.L(""))
    win.SetWindowSubclass(app.view,list_proc,1,0)
    app.icons=win.ImageList_Create(px(16),px(16),win.ILC_COLOR32 | win.ILC_MASK,2,0)
    folder,file:=stock_icon(3),stock_icon(0)
    win.ImageList_ReplaceIcon(app.icons,-1,folder); win.ImageList_ReplaceIcon(app.icons,-1,file)
    win.DestroyIcon(folder); win.DestroyIcon(file)
    win.SendMessageW(app.view,win.LVM_SETIMAGELIST,win.LVSIL_SMALL,cast(win.LPARAM)uintptr(app.icons))
    columns := [?]string{"Name","Size","Type","Modified"}
    for label,i in columns {
        col:=win.LVCOLUMNW{mask=win.LVCF_TEXT | win.LVCF_WIDTH,pszText=w(label),cx=px(170 if i==3 else 140)}
        win.ListView_InsertColumn(app.view,i32(i),&col)
    }
    win.DragAcceptFiles(app.window,true); win.DragAcceptFiles(app.view,true)
    new_image(.MB144); app.dirty=false; refresh()
    if len(os.args)>1 { open_image(os.args[1]) }
    layout(); win.ShowWindow(app.window,win.SW_SHOW); win.UpdateWindow(app.window)
    win.SetFocus(app.view)
    message: win.MSG
    for win.GetMessageW(&message,nil,0,0)>0 {
        handled:=false
        if message.message==win.WM_KEYDOWN && win.GetKeyState(win.VK_CONTROL)<0 {
            switch message.wParam {
            case 'N': command(ID_MKDIR if win.GetKeyState(win.VK_SHIFT)<0 else ID_NEW); handled=true
            case 'O': command(ID_OPEN); handled=true
            case 'S': command(ID_SAVE_AS if win.GetKeyState(win.VK_SHIFT)<0 else ID_SAVE); handled=true
            case 'I': command(ID_ADD); handled=true
            case 'E': command(ID_EXTRACT); handled=true
            }
        }
        if !handled && !win.IsDialogMessageW(app.window,&message) { win.TranslateMessage(&message); win.DispatchMessageW(&message) }
        free_all(context.temp_allocator)
    }
    fat.entries_free(app.entries); fat.destroy(&app.disk)
    clear_locations(); delete(app.locations); delete(app.path); delete(app.status)
    for b in app.buttons { if b.icon!=nil { win.DestroyIcon(b.icon) } }; delete(app.buttons)
    for text in tooltip_strings { delete(text) }; delete(tooltip_strings)
    win.ImageList_Destroy(app.icons); win.DeleteObject(cast(win.HGDIOBJ)app.font); win.DeleteObject(cast(win.HGDIOBJ)app.background); win.DeleteObject(cast(win.HGDIOBJ)app.panel)
}
