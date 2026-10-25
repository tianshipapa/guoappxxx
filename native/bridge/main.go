package main

/*
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
*/
import "C"
import (
	"duanjuapp/native/core"
	"os"
	"path/filepath"
	"unsafe"
)

//export DuanjuInstallStderrLog
func DuanjuInstallStderrLog(logPath *C.char) int32 {
	if logPath == nil {
		return -1
	}
	target := C.GoString(logPath)
	// C.open 只能建文件不能建目录，这里先把 <logs> 目录补齐。
	if dir := filepath.Dir(target); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return -1
		}
	}
	// 打开目标日志文件（追加），并把标准错误(fd 2)指过去。Go runtime 的
	// fatal error（如并发 map 读写）会把堆栈直接打到 fd 2 然后 exit(2)，
	// 桌面端没有 console 时这些输出会彻底丢失，导致「闪退却查不到任何日志」。
	// 重定向后即便 fatal 也能把完整堆栈留在文件里。
	fd := C.open(target, C.O_WRONLY|C.O_CREAT|C.O_APPEND, 0644)
	if fd < 0 {
		return -1
	}
	if C.dup2(fd, 2) < 0 {
		return -1
	}
	return 0
}

//export DuanjuRequest
func DuanjuRequest(input *C.char) *C.char {
	if input == nil {
		return C.CString(`{"ok":false,"error":"请求为空"}`)
	}
	return C.CString(core.NativeRequest(C.GoString(input)))
}

//export DuanjuFree
func DuanjuFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}
