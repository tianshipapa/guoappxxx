package core

import (
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// 投屏（DLNA）只需要一个电视能访问到的播放地址。首选是把站源返回的原始
// 地址直接交给电视，电视自己上网拉流，手机退出 App 也不影响播放。
//
// 但有些线路离开本机就播不了：HLS 播放列表由核心重写过（media.Playlist）、
// 分片要用本机持有的密钥解密（CENC / AES-128），这些只能由核心在局域网口
// 再挂一份流服务、让电视连手机拉。因此核心同时给出 directUrl，由 Flutter
// 侧优先直连、失败再退回转发。

// nativeCastDirectURL 返回可以直接交给电视拉流的原始地址。
//
// 返回空串表示这条线路必须经本机转发：本地文件、需要核心重建的播放列表、
// 需要本机解密的加密分片，都属于这种情况。另外 adBlock 只在本机重写清单时
// 生效，直连会丢掉去广告能力，但换来「关掉 App 也能继续看」，取舍上以能
// 独立播放为准。
func nativeCastDirectURL(media providerMedia) string {
	if !isProviderHTTPMediaURL(media.URL) {
		return ""
	}
	if media.Playlist != "" || len(media.CENCKey) > 0 || len(media.HLSKey) > 0 {
		return ""
	}
	return media.URL
}

// nativeCastBase 打开（或复用）投屏监听，返回局域网可访问的基址。
//
// peer 是投屏目标（电视）的地址，用来确定手机这一侧走哪块网卡：Android 上
// Go 的 net.Interfaces() 在部分机型 / 系统版本上拿不到网卡表（netlink 被拦，
// 表现为「当前没有可用的局域网地址，请先连接 Wi-Fi」，但 SSDP 明明能搜到设备），
// 而朝目标地址 connect 一个 UDP socket 再读本地地址只依赖内核路由，一定有值。
func (stream *nativeStreamServer) nativeCastBase(peer string) (string, error) {
	stream.mu.Lock()
	if stream.castBase != "" {
		base := stream.castBase
		stream.mu.Unlock()
		return base, nil
	}
	address := nativeCastAddress(peer, 0)
	if address == "" {
		stream.mu.Unlock()
		return "", errors.New("当前没有可用的局域网地址，请先连接 Wi-Fi")
	}
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		stream.mu.Unlock()
		return "", errors.New("无法开启投屏端口")
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if port <= 0 {
		_ = listener.Close()
		stream.mu.Unlock()
		return "", errors.New("无法开启投屏端口")
	}
	server := &http.Server{
		Handler:           http.HandlerFunc(stream.nativeServe),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16384,
	}
	go func() { _ = server.Serve(listener) }()
	// 端口开好之后再定一次：这次能顺手验证地址确实落在本机某块网卡上。
	if checked := nativeCastAddress(peer, port); checked != "" {
		address = checked
	}
	base := "http://" + net.JoinHostPort(address, strconv.Itoa(port))
	stream.castServer = server
	stream.castListener = listener
	stream.castBase = base
	stream.mu.Unlock()
	stream.nativeLog(nativeStreamDiagnostic{}, "cast_open", base, "", 0, "")
	return base, nil
}

// nativeCloseCast 停止投屏监听。会话本身不动，本机播放照常。
func (stream *nativeStreamServer) nativeCloseCast() {
	stream.mu.Lock()
	server := stream.castServer
	base := stream.castBase
	stream.castServer = nil
	stream.castListener = nil
	stream.castBase = ""
	stream.mu.Unlock()
	if server != nil {
		stream.nativeLog(nativeStreamDiagnostic{}, "cast_close", base, "", 0, "")
		_ = server.Close()
	}
}

// nativeCastAddress 挑一个电视能访问的本地地址。
//
// port > 0 表示本地监听已经就绪，可以顺手验证候选地址确实落在本机某块网卡上
// （连不上说明是别的网卡的地址，比如流量卡的），避免把电视根本连不到的地址
// 返回出去。
func nativeCastAddress(peer string, port int) string {
	candidates := nativeCastCandidates(peer)
	if port > 0 {
		for _, candidate := range candidates {
			if nativeAddressServes(candidate, port) {
				return candidate
			}
		}
	}
	if len(candidates) > 0 {
		return candidates[0]
	}
	return ""
}

// nativeCastCandidates 按靠谱程度排候选地址：先是「朝电视那个方向选中」的地址，
// 再是枚举出来的网卡地址，最后才退到默认路由（可能是流量卡，优先级最低）。
func nativeCastCandidates(peer string) []string {
	seen := make(map[string]bool, 4)
	candidates := make([]string, 0, 4)
	add := func(address string) {
		if address == "" || seen[address] {
			return
		}
		seen[address] = true
		candidates = append(candidates, address)
	}
	add(nativeIPv4Toward(peer))
	for _, address := range nativeIPv4FromInterfaces() {
		add(address)
	}
	if strings.TrimSpace(peer) != "" {
		add(nativeIPv4Toward(""))
	}
	return candidates
}

// nativeIPv4Toward 朝 target 连一个 UDP socket，取内核选中的本地地址。target 为空
// 时退到一个公共地址，也就是走默认路由。UDP 的 connect 不发任何包，只是让路由表
// 挑出口，不用担心产生流量；它也不依赖网卡枚举，在 Android 上比 net.Interfaces()
// 可靠得多。
func nativeIPv4Toward(target string) string {
	targets := make([]string, 0, 2)
	if host := strings.TrimSpace(target); host != "" {
		if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
			targets = append(targets, net.JoinHostPort(host, "1900"))
		}
	} else {
		targets = append(targets, "223.5.5.5:80", "8.8.8.8:80")
	}
	for _, target := range targets {
		connection, err := net.Dial("udp4", target)
		if err != nil {
			continue
		}
		local := connection.LocalAddr()
		_ = connection.Close()
		host, _, err := net.SplitHostPort(local.String())
		if err != nil {
			continue
		}
		if address := nativeUsableIPv4(host); address != "" {
			return address
		}
	}
	return ""
}

// nativeAddressServes 确认 address:port 在本机真的连得上，也就是这个地址确实
// 属于本机某块网卡。
func nativeAddressServes(address string, port int) bool {
	connection, err := net.DialTimeout(
		"tcp4",
		net.JoinHostPort(address, strconv.Itoa(port)),
		400*time.Millisecond,
	)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

// nativeIPv4FromInterfaces 枚举网卡地址，私有网段排在前面，跳过回环、未指定与
// 链路本地（169.254）。
func nativeIPv4FromInterfaces() []string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	private := make([]string, 0, 2)
	others := make([]string, 0, 2)
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addresses {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			address := nativeUsableIPv4(ipNet.IP.String())
			if address == "" {
				continue
			}
			if net.ParseIP(address).IsPrivate() {
				private = append(private, address)
				continue
			}
			others = append(others, address)
		}
	}
	return append(private, others...)
}

// nativeUsableIPv4 过滤掉投屏地址不能用的取值。
func nativeUsableIPv4(value string) string {
	ip := net.ParseIP(strings.TrimSpace(value)).To4()
	if ip == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
		return ""
	}
	return ip.String()
}

func (engine *nativeEngine) nativeCastBase(peer string) (string, error) {
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream == nil {
		return "", errors.New("播放器尚未初始化，请先开始播放")
	}
	return stream.nativeCastBase(peer)
}

func (engine *nativeEngine) nativeCloseCast() {
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		stream.nativeCloseCast()
	}
}
