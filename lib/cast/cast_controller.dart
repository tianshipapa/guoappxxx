import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个可投屏的接收端：电视、盒子、投影仪等支持 DLNA 的设备。
class CastDevice {
  const CastDevice({
    required this.name,
    required this.udn,
    required this.controlUrl,
  });
  final String name;
  final String udn;
  final String controlUrl;

  factory CastDevice.fromMap(Map<dynamic, dynamic> map) => CastDevice(
    name: map['name']?.toString() ?? '投屏设备',
    udn: map['udn']?.toString() ?? '',
    controlUrl: map['controlUrl']?.toString() ?? '',
  );
}

/// 投屏状态机：搜索设备、把地址下发给电视、以及远端的暂停 / 继续 / 停止。
///
/// 用单例：投屏是跨页面的全局状态，关掉播放设置面板后进度轮询要接着跑。
/// Android 侧（`DlnaCast.kt`）负责 SSDP 与 SOAP，这里只管状态与错误文案。
class CastController extends ChangeNotifier {
  CastController._();

  static final CastController instance = CastController._();

  @visibleForTesting
  static const channel = MethodChannel('duanju/cast');

  bool get supported => defaultTargetPlatform == TargetPlatform.android;

  List<CastDevice> devices = const [];
  bool scanning = false;
  String? error;
  CastDevice? device;
  bool casting = false;
  bool playing = true;

  /// 本次投屏是否经手机转发拉流。false 表示电视直连站源原始地址，
  /// 手机退出 App 也能继续播；true 表示电视连的是手机上的流服务。
  bool relayed = false;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  Timer? _poll;

  /// 搜索局域网里的接收端。[scan] 是幂等的，重复点只会忽略。
  Future<void> scan() async {
    if (!supported || scanning) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('discover');
      final rows = data?['devices'];
      devices = [
        if (rows is List)
          for (final row in rows)
            if (row is Map) CastDevice.fromMap(row),
      ];
      final message = data?['error'];
      if (message is String && message.isNotEmpty) error = message;
    } on MissingPluginException {
      error = '当前版本不支持投屏';
    } on PlatformException catch (failure) {
      error = failure.message ?? '搜索投屏设备失败';
    } catch (_) {
      error = '搜索投屏设备失败';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 把 [url] 下发给 [target] 并从 [position] 起播。
  Future<void> start({
    required CastDevice target,
    required String url,
    required String title,
    required Duration position,
    bool relayed = false,
  }) async {
    await channel.invokeMethod<void>('play', {
      'controlUrl': target.controlUrl,
      'url': url,
      'title': title,
      'positionMs': position.inMilliseconds,
      // 只有经手机转发才需要手机保持唤醒；直连时让手机自由休眠 / 退出。
      'relay': relayed,
    });
    device = target;
    casting = true;
    playing = true;
    this.relayed = relayed;
    error = null;
    this.position = position;
    duration = Duration.zero;
    _startPolling();
    notifyListeners();
  }

  Future<void> pause() => _control('pause', playing: false);

  Future<void> resume() => _control('resume', playing: true);

  /// 停止投屏并清空状态。局域网监听由调用方通过 `releaseCastBase` 关掉。
  Future<void> stop() async {
    final target = device;
    _stopPolling();
    try {
      if (target != null) {
        await channel.invokeMethod<void>('control', {
          'controlUrl': target.controlUrl,
          'command': 'stop',
        });
      }
    } catch (_) {}
    device = null;
    casting = false;
    playing = true;
    relayed = false;
    position = Duration.zero;
    duration = Duration.zero;
    notifyListeners();
  }

  Future<void> _control(String command, {required bool playing}) async {
    final target = device;
    if (target == null) return;
    await channel.invokeMethod<void>('control', {
      'controlUrl': target.controlUrl,
      'command': command,
    });
    this.playing = playing;
    notifyListeners();
  }

  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _refresh() async {
    final target = device;
    if (target == null || !casting) return;
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('status', {
        'controlUrl': target.controlUrl,
      });
      if (data == null || !casting) return;
      final state = data['state']?.toString() ?? '';
      if (state == 'PLAYING' || state == 'PAUSED_PLAYBACK') {
        playing = state == 'PLAYING';
      }
      final current = data['positionMs'];
      if (current is num && current >= 0) {
        position = Duration(milliseconds: current.round());
      }
      final total = data['durationMs'];
      if (total is num && total > 0) {
        duration = Duration(milliseconds: total.round());
      }
      notifyListeners();
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    _stopPolling();
    devices = const [];
    scanning = false;
    error = null;
    device = null;
    casting = false;
    playing = true;
    relayed = false;
    position = Duration.zero;
    duration = Duration.zero;
  }
}
