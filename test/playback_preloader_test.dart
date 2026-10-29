import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

/// 预加载会按线路各准备一份，测试里记下每次带的线路并回一个可识别的计划。
class _PreloadRepository extends FixtureRepository {
  final prepared = <int>[];
  final released = <String>[];

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    bool adBlock = true,
    int route = 0,
  }) async {
    prepared.add(route);
    return PlaybackPlan(
      url: 'https://example.test/preload-$route.mp4',
      session: 'preload-$route',
      routeIndex: route,
      routeCount: 2,
    );
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

void main() {
  final drama = FixtureRepository.free;
  final episode = Episode({'id': '2', 'currentEpisode': 2}, 2);

  test('a preloaded episode is only reused for the same route', () async {
    final repository = _PreloadRepository();
    final preloader = PlaybackPreloader(repository);
    addTearDown(preloader.dispose);

    preloader.prepare(drama, episode, route: 1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(repository.prepared, [1]);
    expect(preloader.status, contains('下一集'));

    // 玩家已经换到别的线路：预载好的那一集不能拿来用，否则切集就跳线。
    expect(preloader.take(drama, episode, route: 0), isNull);
    expect(repository.released, ['preload-1']);

    preloader.prepare(drama, episode, route: 1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final plan = preloader.take(drama, episode, route: 1);
    expect(plan?.session, 'preload-1');
    expect(plan?.routeIndex, 1);
  });
}
