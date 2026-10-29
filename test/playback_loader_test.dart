import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class DeferredRepository extends FixtureRepository {
  final pending = <int, Completer<PlaybackPlan>>{};
  final released = <String>[];
  Completer<PlaybackPlan>? alternate;
  int cancellations = 0;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) {
    final request = Completer<PlaybackPlan>();
    pending[episode.number] = request;
    return request.future;
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) {
    alternate = Completer<PlaybackPlan>();
    return alternate!.future;
  }

  @override
  Future<void> cancelPlayback() async {
    cancellations++;
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

/// 记录每一次解析带上的线路序号，验证线路确实传到了核心。
class RouteRepository extends FixtureRepository {
  final routes = <int>[];
  final onlineRoutes = <int>[];

  PlaybackPlan _plan(int route) => PlaybackPlan(
    url: 'https://example.test/$route.mp4',
    session: 'route-$route',
    routeIndex: route,
    routeCount: 2,
  );

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) async {
    routes.add(route);
    return _plan(route);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) async {
    onlineRoutes.add(route);
    return _plan(route);
  }
}

void main() {
  Episode episode(int number) =>
      Episode({'id': '$number', 'currentEpisode': number}, number);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('the selected route reaches every later resolve', () async {
    final repository = RouteRepository();
    final loader = PlaybackLoader(repository);

    final first = await loader.load(FixtureRepository.free, episode(1), route: 1);
    expect(first?.routeIndex, 1);
    // 切到下一集：仍然带着玩家选中的线路，而不是回到第 1 条。
    final second = await loader.load(
      FixtureRepository.free,
      episode(2),
      route: 1,
    );
    expect(second?.routeIndex, 1);
    expect(repository.routes, [1, 1]);

    // 在线兜底解析同样不能丢线路。
    await loader.load(
      FixtureRepository.free,
      episode(2),
      online: true,
      route: 1,
    );
    expect(repository.onlineRoutes, [1]);
    await loader.close();
  });

  test('a later episode can start before an old resolver completes', () async {
    final repository = DeferredRepository();
    final loader = PlaybackLoader(repository);
    final old = loader.load(FixtureRepository.free, episode(1));
    await tick();
    final latest = loader.load(FixtureRepository.free, episode(2));
    await tick();
    repository.pending[2]!.complete(
      const PlaybackPlan(url: 'https://example.test/2.mp4', session: 'second'),
    );
    expect((await latest)?.session, 'second');
    repository.pending[1]!.complete(
      const PlaybackPlan(url: 'https://example.test/1.mp4', session: 'first'),
    );
    expect(await old, isNull);
    expect(repository.released, ['first']);
    expect(repository.cancellations, 2);
    await loader.close();
  });

  test('a stale failure does not replace the new playback result', () async {
    final repository = DeferredRepository();
    final loader = PlaybackLoader(repository);
    final old = loader.load(FixtureRepository.free, episode(1));
    await tick();
    final latest = loader.load(FixtureRepository.free, episode(2));
    await tick();
    repository.pending[1]!.completeError(AppFailure('old request failed'));
    expect(await old, isNull);
    repository.pending[2]!.completeError(AppFailure('current request failed'));
    await expectLater(latest, throwsA(isA<AppFailure>()));
    await loader.close();
  });

  test(
    'leaving playback releases a plan that arrives after disposal',
    () async {
      final repository = DeferredRepository();
      final loader = PlaybackLoader(repository);
      final result = loader.load(FixtureRepository.free, episode(1));
      await tick();
      await loader.close();
      repository.pending[1]!.complete(
        const PlaybackPlan(url: 'https://example.test/1.mp4', session: 'late'),
      );
      expect(await result, isNull);
      expect(repository.released, ['late']);
      expect(await loader.load(FixtureRepository.free, episode(2)), isNull);
      expect(repository.pending.length, 1);
    },
  );

  test(
    'changing episode cancels an in-flight fallback and releases its late session',
    () async {
      final repository = DeferredRepository();
      final loader = PlaybackLoader(repository);
      final pending = loader.fallback(
        const PlaybackPlan(
          url: 'https://example.test/first.mp4',
          session: 'first',
          routeCount: 2,
        ),
      );
      await tick();
      final current = loader.load(FixtureRepository.free, episode(2));
      await tick();
      repository.pending[2]!.complete(
        const PlaybackPlan(
          url: 'https://example.test/current.mp4',
          session: 'current',
        ),
      );
      expect((await current)?.session, 'current');
      repository.alternate!.complete(
        const PlaybackPlan(
          url: 'https://example.test/late.mp4',
          session: 'late',
        ),
      );
      expect(await pending, isNull);
      expect(repository.released, ['late']);
      await loader.close();
    },
  );
}
