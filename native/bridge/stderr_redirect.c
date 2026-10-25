// [duanju] stderr 重定向到日志文件的 C 辅助（Windows / POSIX 通用）。
//
// 为什么单独放一个 .c 而不是写进 main.go 的 cgo preamble：
//   1) main.go 里用了多个 //export，cgo 会把 preamble **复制到两个生成的文
//      件**里，preamble 里出现函数定义会造成重复定义；
//   2) open() 是可变参函数，Android bionic 打开 _FORTIFY_SOURCE 后给它的声明
//      带 fortify / overloadable 属性，cgo 直接调 C.open(...) 会报
//      "cgo: unexpected type: ..."（本机 glibc 上却能过，只在 Android 交叉
//      编译时炸）。所以把可变参调用彻底移出 cgo，Go 侧改用 os.OpenFile，
//      这里只保留一个固定参数的小函数。
//
// 本文件由 cgo 自动纳入 native/bridge 包的编译（包目录下的 .c 会被自动编）。

#ifdef _WIN32
#include <stdint.h>
#include <io.h>
#include <windows.h>

// 把 fd 复制到标准错误。Windows 上除了 CRT 的 fd 2，还要更新进程的
// STD_ERROR_HANDLE，否则拿到的是启动时那个已失效的控制台句柄。
int duanju_dup_stderr_fd(int fd) {
  if (fd < 0) {
    return -1;
  }
  if (_dup2(fd, 2) < 0) {
    return -1;
  }
  intptr_t handle = _get_osfhandle(fd);
  if (handle != -1) {
    SetStdHandle(STD_ERROR_HANDLE, (HANDLE)handle);
  }
  return 0;
}

#else
#include <unistd.h>

// 把 fd 复制到标准错误。Go runtime 的 fatal error 堆栈是直接写 fd 2 的，
// dup2 之后就会落到日志文件里。
int duanju_dup_stderr_fd(int fd) {
  if (fd < 0) {
    return -1;
  }
  if (dup2(fd, 2) < 0) {
    return -1;
  }
  return 0;
}

#endif
