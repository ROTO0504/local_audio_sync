import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/manual_hub_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ManualHubStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = ManualHubStore();
  });

  group('ManualHubStore 履歴', () {
    test('追加した接続先が新しい順に並ぶ', () async {
      await store.add('192.168.1.10', 7777);
      await store.add('10.0.0.5', 7777);

      expect(
        await store.loadHistory(),
        ['10.0.0.5:7777', '192.168.1.10:7777'],
      );
    });

    test('同じ接続先を再追加すると先頭に移動する(重複しない)', () async {
      await store.add('192.168.1.10', 7777);
      await store.add('10.0.0.5', 7777);
      await store.add('192.168.1.10', 7777);

      expect(
        await store.loadHistory(),
        ['192.168.1.10:7777', '10.0.0.5:7777'],
      );
    });

    test('履歴は最大 5 件まで', () async {
      for (int i = 1; i <= 7; i++) {
        await store.add('10.0.0.$i', 7777);
      }
      final history = await store.loadHistory();
      expect(history, hasLength(5));
      expect(history.first, '10.0.0.7:7777');
      expect(history, isNot(contains('10.0.0.1:7777')));
      expect(history, isNot(contains('10.0.0.2:7777')));
    });
  });

  group('ManualHubStore.parse', () {
    test('ip:port をパースできる', () {
      final parsed = ManualHubStore.parse('192.168.1.10:7777');
      expect(parsed, isNotNull);
      expect(parsed!.ip, '192.168.1.10');
      expect(parsed.port, 7777);
    });

    test('不正な形式は null', () {
      expect(ManualHubStore.parse('192.168.1.10'), isNull);
      expect(ManualHubStore.parse(':7777'), isNull);
      expect(ManualHubStore.parse('host:notaport'), isNull);
      expect(ManualHubStore.parse('host:0'), isNull);
      expect(ManualHubStore.parse('host:99999'), isNull);
    });
  });
}
