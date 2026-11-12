#+build windows
package imgman

import win "core:sys/windows"

ID_EXIT :: 112
ID_SELECT_ALL :: 113
ID_ABOUT :: 114
Menu_Info :: struct { size, mask, style, max_height: u32, background: win.HBRUSH, help_id: u32, data: uintptr }
Measure_Item :: struct { kind, id, item, width, height: u32, data: uintptr }
Tool_Info :: struct { size, flags: u32, window: win.HWND, id: uintptr, rect: win.RECT, instance: win.HINSTANCE, text: [^]u16, param: win.LPARAM, reserved: rawptr }
Menu_Item :: struct { label, shortcut: string, top: bool, key: u8 }
menu_items: [32]Menu_Item
menu_count: int
menu_bar: win.HMENU
tooltips: win.HWND
tooltip_strings: [dynamic][]u16
foreign import menu_user "system:User32.lib"
foreign menu_user {
    SetMenuInfo :: proc "system" (menu: win.HMENU, info: ^Menu_Info) -> win.BOOL ---
    DrawMenuBar :: proc "system" (window: win.HWND) -> win.BOOL ---
}

menu_item :: proc(menu: win.HMENU, id: int, label: string, shortcut: string="", submenu:win.HMENU=nil) {
    index:=menu_count; menu_count+=1
    key:u8
    for i in 0..<len(label)-1 { if label[i]=='&' { key=label[i+1]; break } }
    menu_items[index]=Menu_Item{label,shortcut,submenu!=nil,key}
    item:=win.MENUITEMINFOW{cbSize=size_of(win.MENUITEMINFOW),fMask=win.MIIM_ID | win.MIIM_FTYPE | win.MIIM_DATA | win.MIIM_STRING,
        fType=win.MF_OWNERDRAW,wID=u32(id),dwItemData=uint(index+1),dwTypeData=w(label)}
    if submenu!=nil { item.fMask|=win.MIIM_SUBMENU; item.hSubMenu=submenu }
    win.InsertMenuItemW(menu,0xffffffff,true,&item)
}
menu_dark :: proc(menu:win.HMENU) {
    info:=Menu_Info{size=size_of(Menu_Info),mask=2 | 0x80000000,background=app.panel}
    SetMenuInfo(menu,&info)
}
create_menus :: proc() {
    menu_bar=win.CreateMenu()
    file,edit,help:=win.CreatePopupMenu(),win.CreatePopupMenu(),win.CreatePopupMenu()
    menu_item(file,ID_NEW,"&New image...","Ctrl+N")
    menu_item(file,ID_OPEN,"&Open image...","Ctrl+O")
    win.AppendMenuW(file,win.MF_SEPARATOR,0,nil)
    menu_item(file,ID_SAVE,"&Save","Ctrl+S")
    menu_item(file,ID_SAVE_AS,"Save &as...","Ctrl+Shift+S")
    win.AppendMenuW(file,win.MF_SEPARATOR,0,nil)
    menu_item(file,ID_EXIT,"E&xit","Alt+F4")
    menu_item(edit,ID_ADD,"Add &files...","Ctrl+I")
    menu_item(edit,ID_ADD_FOLDER,"Add f&older...")
    menu_item(edit,ID_MKDIR,"&New folder...","Ctrl+Shift+N")
    win.AppendMenuW(edit,win.MF_SEPARATOR,0,nil)
    menu_item(edit,ID_EXTRACT,"&Extract selected...","Ctrl+E")
    menu_item(edit,ID_RENAME,"&Rename...","F2")
    menu_item(edit,ID_DELETE,"&Delete","Del")
    win.AppendMenuW(edit,win.MF_SEPARATOR,0,nil)
    menu_item(edit,ID_SELECT_ALL,"Select &all","Ctrl+A")
    menu_item(edit,ID_UP,"&Up one folder","Backspace")
    menu_item(help,ID_ABOUT,"&About imgMan")
    menu_item(menu_bar,0,"&File",submenu=file)
    menu_item(menu_bar,0,"&Edit",submenu=edit)
    menu_item(menu_bar,0,"&Help",submenu=help)
    menu_dark(menu_bar)
    win.SetMenu(app.window,menu_bar)
    DrawMenuBar(app.window)
    tooltips=win.CreateWindowExW(win.WS_EX_TOPMOST,win.L("tooltips_class32"),nil,win.WS_POPUP | win.TTS_ALWAYSTIP,
        0,0,0,0,app.window,nil,app.instance,nil)
    dark_window(tooltips)
}
add_tooltip :: proc(button:win.HWND, text:string) {
    value:=win.utf8_to_utf16(text,context.allocator)
    append(&tooltip_strings,value)
    info:=Tool_Info{size=size_of(Tool_Info),flags=0x1 | 0x10,window=app.window,id=uintptr(button),text=raw_data(value)}
    win.SendMessageW(tooltips,win.TTM_ADDTOOLW,0,cast(win.LPARAM)uintptr(&info))
}
draw_menu_item :: proc(item:^Draw_Item) {
    if item.data==0 || item.data>uintptr(menu_count) { return }
    data:=menu_items[item.data-1]
    fill(item.dc,item.rect,ACCENT if item.state & (1 | 0x40)!=0 else PANEL)
    r:=item.rect; r.left+=px(12); r.right-=px(12)
    draw_text(item.dc,data.label,r,MUTED if item.state & 6!=0 else TEXT)
    if data.shortcut!="" { draw_text(item.dc,data.shortcut,r,MUTED,(.DT_RIGHT | .DT_SINGLELINE | .DT_VCENTER)) }
}
measure_menu_item :: proc(item:^Measure_Item) {
    if item.data==0 || item.data>uintptr(menu_count) { return }
    data:=menu_items[item.data-1]
    item.width=u32(px(20+4*i32(len(data.label)-1)) if data.top else px(270))
    item.height=u32(px(22) if data.top else px(28))
}
menu_mnemonic :: proc(menu:win.HMENU, key:u8) -> win.LRESULT {
    key:=key
    for i:u32=0; i<32; i+=1 {
        item:=win.MENUITEMINFOW{cbSize=size_of(win.MENUITEMINFOW),fMask=win.MIIM_DATA}
        if !win.GetMenuItemInfoW(menu,i,true,&item) { break }
        if item.dwItemData>0 && item.dwItemData<=uint(menu_count) {
            letter:=menu_items[item.dwItemData-1].key
            if letter>='A' && letter<='Z' { letter+=32 }
            if key>='A' && key<='Z' { key+=32 }
            if letter==key { return win.LRESULT(i | (2<<16)) }
        }
    }
    return 0
}
