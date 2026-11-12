#+build windows
package imgman

import win "core:sys/windows"

Toolbar_Icon_Context :: struct { dc: win.HDC, x, y, size: i32, disabled: bool }

toolbar_icon_color :: proc(icon: Toolbar_Icon_Context, color: win.COLORREF) -> win.COLORREF {
    if !icon.disabled { return color }
    r, g, b := u32(color)&255, (u32(color)>>8)&255, (u32(color)>>16)&255
    gray := (r*30 + g*59 + b*11)/100
    gray = 65 + gray/3
    return win.COLORREF(gray | gray<<8 | gray<<16)
}

toolbar_icon_point :: proc(icon: Toolbar_Icon_Context, x, y: i32) -> win.POINT {
    return {icon.x + (x*icon.size+12)/24, icon.y + (y*icon.size+12)/24}
}

toolbar_icon_polygon :: proc(icon: Toolbar_Icon_Context, points: []win.POINT, color: win.COLORREF, outline := win.COLORREF(0x303030)) {
    scaled: [16]win.POINT
    for point, i in points { scaled[i] = toolbar_icon_point(icon, point.x, point.y) }
    pen := win.CreatePen(0, max(1, icon.size/24), toolbar_icon_color(icon, outline))
    brush := win.CreateSolidBrush(toolbar_icon_color(icon, color))
    old_pen := win.SelectObject(icon.dc, cast(win.HGDIOBJ)pen)
    old_brush := win.SelectObject(icon.dc, cast(win.HGDIOBJ)brush)
    win.Polygon(icon.dc, &scaled[0], i32(len(points)))
    win.SelectObject(icon.dc, old_brush)
    win.SelectObject(icon.dc, old_pen)
    win.DeleteObject(cast(win.HGDIOBJ)brush)
    win.DeleteObject(cast(win.HGDIOBJ)pen)
}

toolbar_icon_rect :: proc(icon: Toolbar_Icon_Context, left, top, right, bottom: i32, color: win.COLORREF) {
    a, b := toolbar_icon_point(icon, left, top), toolbar_icon_point(icon, right, bottom)
    rect := win.RECT{a.x,a.y,b.x,b.y}
    brush := win.CreateSolidBrush(toolbar_icon_color(icon,color))
    win.FillRect(icon.dc, &rect, brush)
    win.DeleteObject(cast(win.HGDIOBJ)brush)
}

toolbar_icon_line :: proc(icon: Toolbar_Icon_Context, x1,y1,x2,y2: i32, color: win.COLORREF, width: i32=1) {
    a, b := toolbar_icon_point(icon,x1,y1), toolbar_icon_point(icon,x2,y2)
    pen := win.CreatePen(0,max(1,(width*icon.size+12)/24),toolbar_icon_color(icon,color))
    previous := win.SelectObject(icon.dc,cast(win.HGDIOBJ)pen)
    win.MoveToEx(icon.dc,a.x,a.y,nil)
    win.LineTo(icon.dc,b.x,b.y)
    win.SelectObject(icon.dc,previous)
    win.DeleteObject(cast(win.HGDIOBJ)pen)
}

toolbar_icon_document :: proc(icon: Toolbar_Icon_Context) {
    toolbar_icon_polygon(icon,[]win.POINT{{3,2},{13,2},{18,7},{18,22},{3,22}},win.RGB(227,232,239))
    toolbar_icon_polygon(icon,[]win.POINT{{13,2},{13,7},{18,7}},win.RGB(159,176,195))
    toolbar_icon_line(icon,6,10,14,10,win.RGB(133,153,174))
    toolbar_icon_line(icon,6,13,14,13,win.RGB(133,153,174))
    toolbar_icon_line(icon,6,16,12,16,win.RGB(133,153,174))
}

toolbar_icon_folder :: proc(icon: Toolbar_Icon_Context) {
    toolbar_icon_polygon(icon,[]win.POINT{{2,6},{9,6},{11,8},{21,8},{21,21},{2,21}},win.RGB(190,137,48))
    toolbar_icon_polygon(icon,[]win.POINT{{1,10},{21,10},{23,12},{20,22},{3,22}},win.RGB(238,191,89))
    toolbar_icon_line(icon,4,12,20,12,win.RGB(255,218,133))
}

toolbar_icon_floppy :: proc(icon: Toolbar_Icon_Context) {
    toolbar_icon_polygon(icon,[]win.POINT{{3,2},{18,2},{22,6},{22,22},{3,22}},win.RGB(70,135,204))
    toolbar_icon_rect(icon,7,3,17,10,win.RGB(212,223,232))
    toolbar_icon_rect(icon,13,4,16,9,win.RGB(63,80,100))
    toolbar_icon_rect(icon,6,13,19,21,win.RGB(228,235,241))
    toolbar_icon_line(icon,8,16,17,16,win.RGB(135,156,177))
    toolbar_icon_line(icon,8,18,15,18,win.RGB(135,156,177))
    toolbar_icon_rect(icon,4,3,5,20,win.RGB(103,168,227))
}

toolbar_icon_plus :: proc(icon: Toolbar_Icon_Context, x,y: i32) {
    toolbar_icon_polygon(icon,[]win.POINT{{x-2,y-6},{x+2,y-6},{x+2,y-2},{x+6,y-2},{x+6,y+2},{x+2,y+2},{x+2,y+6},{x-2,y+6},{x-2,y+2},{x-6,y+2},{x-6,y-2},{x-2,y-2}},win.RGB(103,204,121))
}

toolbar_icon_down :: proc(icon: Toolbar_Icon_Context, x,y: i32) {
    toolbar_icon_polygon(icon,[]win.POINT{{x-2,y},{x+2,y},{x+2,y+8},{x+5,y+8},{x,y+14},{x-5,y+8},{x-2,y+8}},win.RGB(103,204,121))
}

toolbar_icon_up :: proc(icon: Toolbar_Icon_Context, color: win.COLORREF, top: i32=2, bottom: i32=21) {
    toolbar_icon_polygon(icon,[]win.POINT{{12,top},{21,top+8},{15,top+8},{15,bottom},{9,bottom},{9,top+8},{3,top+8}},color)
    toolbar_icon_line(icon,12,top+4,12,bottom-2,win.RGB(190,230,246))
}

toolbar_icon_pencil :: proc(icon: Toolbar_Icon_Context) {
    toolbar_icon_polygon(icon,[]win.POINT{{10,21},{12,15},{20,7},{24,11},{16,19}},win.RGB(247,193,74))
    toolbar_icon_polygon(icon,[]win.POINT{{10,21},{12,15},{16,19}},win.RGB(232,212,174))
    toolbar_icon_polygon(icon,[]win.POINT{{20,7},{22,5},{26,9},{24,11}},win.RGB(216,115,115))
    toolbar_icon_line(icon,14,16,21,9,win.RGB(255,227,139))
    toolbar_icon_line(icon,10,21,12,18,win.RGB(45,48,56),2)
}

draw_toolbar_icon :: proc(dc: win.HDC, id: int, x,y,size: i32, disabled: bool=false) {
    if size <= 0 { return }
    icon := Toolbar_Icon_Context{dc,x,y,size,disabled}
    switch id {
    case ID_NEW:
        toolbar_icon_document(icon)
        toolbar_icon_plus(icon,17,17)
    case ID_OPEN:
        toolbar_icon_folder(icon)
        toolbar_icon_polygon(icon,[]win.POINT{{11,15},{16,10},{12,10},{12,6},{23,6},{23,17},{19,17},{19,13},{14,18}},win.RGB(103,204,121))
    case ID_SAVE:
        toolbar_icon_floppy(icon)
    case ID_SAVE_AS:
        toolbar_icon_floppy(icon)
        pencil := icon; pencil.x -= max(1,size/12)
        toolbar_icon_pencil(pencil)
    case ID_ADD:
        toolbar_icon_document(icon)
        toolbar_icon_down(icon,18,6)
    case ID_ADD_FOLDER:
        toolbar_icon_folder(icon)
        toolbar_icon_down(icon,17,2)
    case ID_EXTRACT:
        toolbar_icon_polygon(icon,[]win.POINT{{3,12},{21,12},{21,22},{3,22}},win.RGB(177,132,83))
        toolbar_icon_polygon(icon,[]win.POINT{{3,12},{1,16},{9,18},{12,14}},win.RGB(222,182,130))
        toolbar_icon_polygon(icon,[]win.POINT{{12,14},{15,18},{23,16},{21,12}},win.RGB(232,193,142))
        arrow := icon; arrow.x += (size*4+12)/24; arrow.size = (size*16+12)/24
        toolbar_icon_up(arrow,win.RGB(103,204,121),1,21)
    case ID_UP:
        toolbar_icon_up(icon,win.RGB(112,181,231))
    case ID_MKDIR:
        toolbar_icon_folder(icon)
        toolbar_icon_plus(icon,17,16)
    case ID_RENAME:
        toolbar_icon_document(icon)
        pencil := icon; pencil.x -= max(1,size/12)
        toolbar_icon_pencil(pencil)
    case ID_DELETE:
        toolbar_icon_polygon(icon,[]win.POINT{{6,3},{12,9},{18,3},{22,7},{16,13},{22,19},{18,23},{12,17},{6,23},{2,19},{8,13},{2,7}},win.RGB(225,104,104))
        toolbar_icon_line(icon,6,6,19,19,win.RGB(255,162,154))
    }
}
