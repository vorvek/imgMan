package fat12

import win "core:sys/windows"

foreign import kernel "system:Kernel32.lib"
foreign kernel {
    GetLocalTime :: proc "system" (local: ^win.SYSTEMTIME) ---
}

local_timestamp :: proc()->(date,clock:u16) {
    now:win.SYSTEMTIME
    GetLocalTime(&now)
    date=(clamp(now.year,1980,2107)-1980)<<9|now.month<<5|now.day
    clock=now.hour<<11|now.minute<<5|now.second/2
    return
}
