package main

/*
#include <stdlib.h>

// 把 fd 复制到标准错误(fd 2)，实现在 stderr_redirect.c。
// 声明只放在 preamble（//export 要求 preamble 里不能有定义）。
int duanju_dup_stderr_fd(int fd);
*/
import "C"
import (
	"duanjuapp/native/core"
	"os"
	"path/filepath"
	"unsafe"
)

// stderrLogFile 必须保持引用：一旦被 GC 回收，finalizer 会关掉这个文件描述符。
// （dup2 之后 fd 2 是独立的描述符，关掉原 fd 不会连带关掉 stderr，但保持引用
// 更稳妥，也方便日后排查。）
var stderrLogFile *os.File

//export DuanjuInstallStderrLog
func DuanjuInstallStderrLog(logPath *C.char) int32 {
	if logPath == nil {
		return -1
	}
	target := C.GoString(logPath)
	if dir := filepath.Dir(target); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return -1
		}
	}
	// 用 os.OpenFile 而不是 C.open：一是避开可变参函数在 bionic 上的 cgo 解析
	// 问题，二是路径按 UTF-8 交给 Go 处理，不会被 Windows 的 ANSI 代码页破坏
	// （数据目录常含中文用户名）。
	file, err := os.OpenFile(
		target,
		os.O_WRONLY|os.O_CREATE|os.O_APPEND,
		0o644,
	)
	if err != nil {
		return -1
	}
	// 把标准错误(fd 2)指过去。Go runtime 的 fatal error（如并发 map 读写）会把
	// 堆栈直接打到 fd 2 然后 exit(2)，桌面/移动端没有 console 时这些输出会彻底
	// 丢失，导致「闪退却查不到任何日志」。重定向后即便 fatal 也能留下堆栈。
	if C.duanju_dup_stderr_fd(C.int(file.Fd())) != 0 {
		_ = file.Close()
		return -1
	}
	stderrLogFile = file
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
