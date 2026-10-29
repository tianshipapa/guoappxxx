package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 投屏时电视按内网地址拉流，播放列表里写回的绝对地址必须跟着请求 Host 走，
// 否则电视拿到 127.0.0.1 的分片地址就播不出来。
func TestNativeCastPlaylistUsesRequestHost(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		io.WriteString(w, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n/media.m3u8\n")
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()

	address, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/master.m3u8"}, false)
	local := readCastBody(t, address, "")
	if !strings.Contains(local, stream.address+"/"+token+"/") {
		t.Fatalf("本机播放应写回 127.0.0.1 地址，实际：%s", local)
	}

	// 模拟电视：同一个监听，但请求 Host 是手机的内网地址。
	cast := readCastBody(t, address, "192.168.1.20:40000")
	if !strings.Contains(cast, "http://192.168.1.20:40000/"+token+"/") {
		t.Fatalf("投屏播放列表应写回请求 Host，实际：%s", cast)
	}
	if strings.Contains(cast, "127.0.0.1") {
		t.Fatalf("投屏播放列表不应出现回环地址，实际：%s", cast)
	}
}

func TestNativeCastBaseOpensLanListener(t *testing.T) {
	if nativeCastAddress("", 0) == "" {
		t.Skip("本机没有可用的内网地址")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()

	base, err := stream.nativeCastBase("")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(base, "http://") || strings.Contains(base, "127.0.0.1") {
		t.Fatalf("投屏基址应是内网地址，实际：%s", base)
	}
	// 复用同一个基址，不要每次投屏都开新端口。
	again, err := stream.nativeCastBase("")
	if err != nil || again != base {
		t.Fatalf("重复读取投屏基址应保持一致：%s %v", again, err)
	}
	response, err := http.Get(base + "/missing")
	if err != nil {
		t.Fatalf("投屏端口应可访问：%v", err)
	}
	_ = response.Body.Close()
	if response.StatusCode == http.StatusOK {
		t.Fatalf("不存在的资源不应返回 200")
	}

	stream.nativeCloseCast()
	// 换一个全新的连接再试：默认客户端的 keep-alive 连接可能还在池里，
	// 复用它测不出端口是否真的关了。
	fresh := &http.Client{Transport: &http.Transport{}}
	defer fresh.CloseIdleConnections()
	if _, err := fresh.Get(base + "/missing"); err == nil {
		t.Fatalf("关闭投屏后端口应停止监听")
	}
	if stream.castBase != "" {
		t.Fatalf("关闭投屏后应清空基址，实际：%s", stream.castBase)
	}
}

// 投屏地址不能是回环、未指定或链路本地地址，否则电视拉不到流。
func TestNativeUsableIPv4(t *testing.T) {
	cases := map[string]string{
		"192.168.1.20":  "192.168.1.20",
		"10.0.0.5":      "10.0.0.5",
		"172.20.3.4":    "172.20.3.4",
		"127.0.0.1":     "",
		"0.0.0.0":       "",
		"169.254.10.10": "",
		"::1":           "",
		"":              "",
		"not-an-ip":     "",
	}
	for input, want := range cases {
		if got := nativeUsableIPv4(input); got != want {
			t.Fatalf("nativeUsableIPv4(%q) = %q，期望 %q", input, got, want)
		}
	}
}

// 取到的投屏地址必须是能用的（本机没有任何网络时跳过）。
func TestNativeCastAddressIsUsable(t *testing.T) {
	address := nativeCastAddress("", 0)
	if address == "" {
		t.Skip("本机没有可用的内网地址")
	}
	if nativeUsableIPv4(address) != address {
		t.Fatalf("投屏地址不合格：%q", address)
	}
}

// 直连地址只在「电视自己就能播」时才给：需要本机重建播放列表或解密分片的
// 线路必须留空，让 Flutter 侧退回本机转发。
func TestNativeCastDirectURL(t *testing.T) {
	cases := []struct {
		name  string
		media providerMedia
		want  string
	}{
		{"普通 m3u8 可直连", providerMedia{URL: "https://cdn.example.com/a.m3u8"}, "https://cdn.example.com/a.m3u8"},
		{"普通 mp4 可直连", providerMedia{URL: "https://cdn.example.com/a.mp4"}, "https://cdn.example.com/a.mp4"},
		{"本机重建的播放列表不可直连", providerMedia{URL: "https://cdn.example.com/a.m3u8", Playlist: "#EXTM3U\n"}, ""},
		{"CENC 加密分片不可直连", providerMedia{URL: "https://cdn.example.com/a.m3u8", CENCKey: []byte("key")}, ""},
		{"AES-128 分片不可直连", providerMedia{URL: "https://cdn.example.com/a.m3u8", HLSKey: []byte("key")}, ""},
		{"非 http 地址不可直连", providerMedia{URL: "magnet:?xt=urn:btih:x"}, ""},
	}
	for _, test := range cases {
		if got := nativeCastDirectURL(test.media); got != test.want {
			t.Fatalf("%s：nativeCastDirectURL = %q，期望 %q", test.name, got, test.want)
		}
	}
}

// 播放计划要把原始地址一起交给 Flutter，否则投屏只能走手机转发。
func TestNativeOpenPlaybackKeepsDirectURL(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		io.WriteString(w, "media")
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	choice := nativePlaybackChoices(providerMedia{URL: upstream.URL + "/a.mp4"}, 0)
	choice.adBlock = false
	plan, err := engine.nativeOpenPlayback(context.Background(), choice)
	if err != nil {
		t.Fatal(err)
	}
	if plan.DirectURL != upstream.URL+"/a.mp4" {
		t.Fatalf("播放计划应保留原始地址，实际：%q", plan.DirectURL)
	}
	// 本机播放用的 url 仍然是本机中转地址，两者不能混用。
	if plan.URL == plan.DirectURL {
		t.Fatalf("本机播放地址不应等于直连地址：%q", plan.URL)
	}
	engine.nativeReleasePlayback(plan.Session)
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		_ = stream.server.Close()
	}
}

func readCastBody(t *testing.T, address, host string) string {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		t.Fatal(err)
	}
	if host != "" {
		request.Host = host
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("拉取播放列表失败：HTTP %d %s", response.StatusCode, body)
	}
	return string(body)
}
