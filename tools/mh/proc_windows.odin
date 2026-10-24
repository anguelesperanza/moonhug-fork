#+build windows
package mh

import win32 "core:sys/windows"

// process_alive reports whether a process with this pid exists: opening a
// handle to a dead pid fails.
process_alive :: proc(pid: int) -> bool {
	h := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, win32.DWORD(pid))
	if h == nil do return false
	win32.CloseHandle(h)
	return true
}
