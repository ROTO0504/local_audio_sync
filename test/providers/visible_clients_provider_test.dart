import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/client_diagnostics.dart';
import 'package:local_audio_sync/models/client_info.dart';
import 'package:local_audio_sync/providers/hub_diagnostics_provider.dart';
import 'package:local_audio_sync/providers/hub_state_provider.dart';
import 'package:local_audio_sync/providers/hub_view_prefs_provider.dart';
import 'package:local_audio_sync/providers/visible_clients_provider.dart';

ClientInfo _client(
  String id,
  String name, {
  String ip = '192.168.1.10',
  String platform = 'ios',
  double volume = 1.0,
  bool isMuted = false,
  bool isActive = true,
  bool isPaused = false,
  DateTime? lastSeen,
}) =>
    ClientInfo(
      id: id,
      name: name,
      ip: ip,
      port: 7777,
      platform: platform,
      volume: volume,
      isMuted: isMuted,
      isActive: isActive,
      isPaused: isPaused,
      lastSeen: lastSeen ?? DateTime(2026, 1, 1),
    );

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  void seed(List<ClientInfo> clients) {
    final notifier = container.read(hubStateProvider.notifier);
    for (final c in clients) {
      notifier.addOrUpdateClient(c);
    }
  }

  List<String> visibleIds() =>
      container.read(visibleClientsProvider).map((c) => c.id).toList();

  group('フィルタ', () {
    test('all はすべてを返す', () {
      seed([
        _client('a', 'Alice', isActive: true),
        _client('b', 'Bob', isActive: false),
      ]);
      expect(visibleIds(), containsAll(['a', 'b']));
      expect(visibleIds(), hasLength(2));
    });

    test('active は isActive のみ', () {
      seed([
        _client('a', 'Alice', isActive: true),
        _client('b', 'Bob', isActive: false),
      ]);
      container.read(hubViewPrefsProvider.notifier).setFilter(HubFilter.active);
      expect(visibleIds(), ['a']);
    });

    test('disconnected は !isActive のみ', () {
      seed([
        _client('a', 'Alice', isActive: true),
        _client('b', 'Bob', isActive: false),
      ]);
      container
          .read(hubViewPrefsProvider.notifier)
          .setFilter(HubFilter.disconnected);
      expect(visibleIds(), ['b']);
    });

    test('paused は isPaused のみ', () {
      seed([
        _client('a', 'Alice', isPaused: true),
        _client('b', 'Bob', isPaused: false),
      ]);
      container.read(hubViewPrefsProvider.notifier).setFilter(HubFilter.paused);
      expect(visibleIds(), ['a']);
    });

    test('muted は isMuted のみ', () {
      seed([
        _client('a', 'Alice', isMuted: true),
        _client('b', 'Bob', isMuted: false),
      ]);
      container.read(hubViewPrefsProvider.notifier).setFilter(HubFilter.muted);
      expect(visibleIds(), ['a']);
    });
  });

  group('検索クエリ', () {
    test('name の部分一致(大文字小文字無視)', () {
      seed([
        _client('a', 'iPhone 15'),
        _client('b', 'Pixel 8'),
      ]);
      container.read(hubViewPrefsProvider.notifier).setQuery('PIXEL');
      expect(visibleIds(), ['b']);
    });

    test('ip の部分一致', () {
      seed([
        _client('a', 'Alice', ip: '192.168.1.20'),
        _client('b', 'Bob', ip: '10.0.0.5'),
      ]);
      container.read(hubViewPrefsProvider.notifier).setQuery('10.0.0');
      expect(visibleIds(), ['b']);
    });

    test('空クエリはフィルタしない', () {
      seed([
        _client('a', 'Alice'),
        _client('b', 'Bob'),
      ]);
      container.read(hubViewPrefsProvider.notifier).setQuery('   ');
      expect(visibleIds(), hasLength(2));
    });
  });

  group('ソート', () {
    test('name 昇順 / 降順', () {
      seed([
        _client('a', 'Charlie'),
        _client('b', 'Alice'),
        _client('c', 'Bob'),
      ]);
      // 既定 name / ascending
      expect(visibleIds(), ['b', 'c', 'a']);

      container.read(hubViewPrefsProvider.notifier).toggleAscending();
      expect(visibleIds(), ['a', 'c', 'b']);
    });

    test('volume 昇順', () {
      seed([
        _client('a', 'Alice', volume: 0.9),
        _client('b', 'Bob', volume: 0.1),
        _client('c', 'Carol', volume: 0.5),
      ]);
      container.read(hubViewPrefsProvider.notifier).setSortKey(HubSortKey.volume);
      expect(visibleIds(), ['b', 'c', 'a']);
    });

    test('lossRate は診断 provider の値で並ぶ', () {
      seed([
        _client('a', 'Alice'),
        _client('b', 'Bob'),
        _client('c', 'Carol'),
      ]);
      container.read(hubDiagnosticsProvider.notifier).setAll({
        'a': const ClientDiagnostics(totalReceived: 100, totalDropped: 20),
        'b': const ClientDiagnostics(totalReceived: 100, totalDropped: 1),
        'c': const ClientDiagnostics(totalReceived: 100, totalDropped: 5),
      });
      container
          .read(hubViewPrefsProvider.notifier)
          .setSortKey(HubSortKey.lossRate);
      // b(1%) < c(5%) < a(20%)
      expect(visibleIds(), ['b', 'c', 'a']);
    });

    test('lastSeen は ClientInfo.lastSeen で並ぶ', () {
      seed([
        _client('a', 'Alice', lastSeen: DateTime(2026, 1, 3)),
        _client('b', 'Bob', lastSeen: DateTime(2026, 1, 1)),
        _client('c', 'Carol', lastSeen: DateTime(2026, 1, 2)),
      ]);
      container
          .read(hubViewPrefsProvider.notifier)
          .setSortKey(HubSortKey.lastSeen);
      expect(visibleIds(), ['b', 'c', 'a']);
    });
  });

  test('filter → query → sort の合成', () {
    seed([
      _client('a', 'iPhone', isActive: true, volume: 0.9),
      _client('b', 'iPad', isActive: true, volume: 0.2),
      _client('c', 'iPhone-old', isActive: false, volume: 0.5),
      _client('d', 'Pixel', isActive: true, volume: 0.7),
    ]);
    final prefs = container.read(hubViewPrefsProvider.notifier);
    prefs.setFilter(HubFilter.active); // a, b, d
    prefs.setQuery('i'); // iPhone, iPad(Pixel も 'i' を含む→ Pixel も残る)
    prefs.setSortKey(HubSortKey.volume); // 昇順

    // active かつ name/ip に 'i' を含む: a(iPhone), b(iPad), d(Pixel)
    // volume 昇順: b(0.2), d(0.7), a(0.9)
    expect(visibleIds(), ['b', 'd', 'a']);
  });
}
