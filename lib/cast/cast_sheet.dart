import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import 'cast_controller.dart';

/// 投屏所需的一份播放信息。
///
/// 播放器把当前这一集的地址、进度和仓库传进来，面板只管选设备、下发地址；
/// 投屏成功后本机暂停，避免两头同时出声。
class CastSource {
  const CastSource({
    required this.repository,
    required this.title,
    required this.directUrl,
    required this.streamUrl,
    required this.position,
    required this.playing,
    this.onPause,
  });

  final AppRepository repository;
  final String title;

  /// 站源返回的原始地址。非空时电视直连拉流，手机退出 App 也能继续播。
  final String directUrl;

  /// 核心的本机流地址，直连不可用时改成手机内网地址转发给电视。
  final String streamUrl;

  final Duration position;
  final bool playing;
  final VoidCallback? onPause;

  /// 这条线路能不能让电视自己去拉流。
  bool get direct => directUrl.isNotEmpty;
}

/// 原生侧抛回来的错误只需要那句中文，不要把异常类型糊到界面上。
String castMessage(Object failure) => failure is PlatformException
    ? (failure.message ?? '投屏失败')
    : failure.toString();

/// 打开投屏选设备面板。沿用播放器菜单的深色主题与抽屉尺寸。
Future<void> showCastSheet(
  BuildContext context, {
  required CastSource source,
}) {
  final size = MediaQuery.sizeOf(context);
  final landscape = size.width > size.height;
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => Dialog(
      key: const ValueKey('cast-sheet'),
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: landscape ? math.min(440, size.width * .6) : 600,
        height: landscape ? size.height : size.height * .72,
        child: CastSheet(source: source),
      ),
    ),
  );
}

String _clock(Duration value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final seconds = value.inSeconds;
  final clock = '${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  return seconds >= 3600 ? '${seconds ~/ 3600}:$clock' : clock;
}

class CastSheet extends StatefulWidget {
  const CastSheet({super.key, required this.source});
  final CastSource source;

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  final _cast = CastController.instance;
  bool _busy = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    if (!_cast.casting && _cast.devices.isEmpty && !_cast.scanning) {
      unawaited(_cast.scan());
    }
  }

  Future<void> _select(CastDevice target) async {
    if (_busy) return;
    final source = widget.source;
    setState(() {
      _busy = true;
      _failure = null;
    });
    var relayed = false;
    try {
      // 首选把站源返回的原始地址直接交给电视：电视自己上网拉流，手机不再
      // 参与转发，投屏后退出 App、切后台、锁屏都不影响电视上的播放。
      if (source.direct) {
        try {
          await _cast.start(
            target: target,
            url: source.directUrl,
            title: source.title,
            position: source.position,
          );
        } catch (_) {
          // 少数盒子只接受手机内网地址，直连被拒时退回转发，别让用户看到失败。
        }
      }
      if (!_cast.casting) {
        // 退回转发：电视拉不到手机的 127.0.0.1，地址要换成核心在局域网口上
        // 开的同一份流。把电视地址一起给它：核心据此挑手机这一侧走哪块网卡。
        final peer = Uri.tryParse(target.controlUrl)?.host ?? '';
        final base = await source.repository.castBase(peer: peer);
        final path = Uri.parse(source.streamUrl).path;
        await _cast.start(
          target: target,
          url: '$base${path.isEmpty ? '/' : path}',
          title: source.title,
          position: source.position,
          relayed: true,
        );
        relayed = true;
      }
      // 本机暂停，免得两头同时播。
      if (source.playing) source.onPause?.call();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            relayed
                ? '已投屏到 ${target.name} · 这条线路需要手机转发，请留在 App'
                : '已投屏到 ${target.name} · 现在可以退出 App',
          ),
        ),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _failure = castMessage(failure);
        _busy = false;
      });
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _cast.stop();
    // 直连投屏时根本没开过局域网监听，这里调用是幂等的。
    await widget.source.repository.releaseCastBase();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// 直连成功但电视实际播不出来（比如要求 Referer）时的逃生口：
  /// 换成经手机转发的地址重投一次，从当前进度继续。
  Future<void> _relay() async {
    final target = _cast.device;
    if (target == null) return;
    final source = widget.source;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final peer = Uri.tryParse(target.controlUrl)?.host ?? '';
      final base = await source.repository.castBase(peer: peer);
      final path = Uri.parse(source.streamUrl).path;
      await _cast.start(
        target: target,
        url: '$base${path.isEmpty ? '/' : path}',
        title: source.title,
        position: _cast.position,
        relayed: true,
      );
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _failure = castMessage(failure);
        _busy = false;
      });
    }
  }

  /// 转发投屏时反过来切回电视直连：把站源原始地址重新下发给电视，
  /// 电视自己拉流，手机就能退出 App 了。
  Future<void> _direct() async {
    final target = _cast.device;
    final source = widget.source;
    if (target == null || !source.direct) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await _cast.start(
        target: target,
        url: source.directUrl,
        title: source.title,
        position: _cast.position,
      );
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _failure = castMessage(failure);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _cast,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final hint = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '投屏到电视',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (_cast.casting) ...[
                  _connected(context, hint),
                  const SizedBox(height: 12),
                  Text('停止投屏后可以接着在本机看，进度不会同步回来。', style: hint),
                ] else ...[
                  Text(
                    widget.source.direct
                        ? '把当前这一集投到同一 Wi-Fi 下的电视 / 盒子 / 投影仪。'
                              '电视会直接拉取站源的原始线路，投屏后可以退出 App，'
                              '电视上的播放不受影响。'
                        : '把当前这一集投到同一 Wi-Fi 下的电视 / 盒子 / 投影仪。'
                              '这条线路是 DRM 加密内容，电视无法直接解密，只能经手机转发，'
                              '投屏期间请留在 App，不要退出。',
                    style: hint,
                  ),
                  const SizedBox(height: 12),
                  if (_cast.scanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_cast.devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_cast.error ?? '没有找到可投屏的设备', style: hint),
                    )
                  else
                    for (final device in _cast.devices)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        enabled: !_busy,
                        leading: const Icon(Icons.tv_rounded),
                        title: Text(device.name),
                        subtitle: const Text('DLNA · 点击投屏'),
                        onTap: _busy ? null : () => _select(device),
                      ),
                  if (_failure case final failure?) ...[
                    const SizedBox(height: 8),
                    Text(failure, style: hint.copyWith(color: colors.error)),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _cast.scanning || _busy
                          ? null
                          : () => unawaited(_cast.scan()),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新搜索'),
                    ),
                  ),
                ],
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _connected(BuildContext context, TextStyle hint) {
    final colors = Theme.of(context).colorScheme;
    final duration = _cast.duration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerHighest,
          child: ListTile(
            leading: Icon(Icons.tv_rounded, color: colors.primary),
            title: Text(_cast.device?.name ?? '投屏设备'),
            subtitle: Text(
              duration > Duration.zero
                  ? '正在投放 · ${_clock(_cast.position)} / ${_clock(duration)}'
                  : '正在投放 · ${_clock(_cast.position)}',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _cast.relayed
              ? '经手机转发：投屏期间请留在 App，退出后电视会断流。'
              : '电视直连线路：可以退出 App，电视会自行继续播放。',
          style: hint.copyWith(
            color: _cast.relayed ? colors.error : colors.primary,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _cast.playing ? _cast.pause() : _cast.resume(),
                    ),
              icon: Icon(
                _cast.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              label: Text(_cast.playing ? '暂停' : '继续'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => unawaited(_stop()),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('停止投屏'),
            ),
          ],
        ),
        if (!_cast.relayed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_relay()),
              icon: const Icon(Icons.sync_rounded),
              label: const Text('电视播不出来？改用手机转发'),
            ),
          ),
        // 正在转发但这集本来有原始地址：允许切回直连，之后手机可以退出。
        if (_cast.relayed && widget.source.direct)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_direct()),
              icon: const Icon(Icons.cast_connected_rounded),
              label: const Text('改用电视直连（可退出 App）'),
            ),
          ),
        if (_failure case final failure?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              failure,
              style: hint.copyWith(color: colors.error),
            ),
          ),
        const SizedBox(height: 8),
        Text('暂停 / 继续只影响电视，本机画面保持暂停。', style: hint),
      ],
    );
  }
}
