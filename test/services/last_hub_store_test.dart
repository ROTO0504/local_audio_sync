import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/control_messages.dart';
import 'package:local_audio_sync/services/discovery_service.dart';
import 'package:local_audio_sync/services/last_hub_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LastHubStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LastHubStore();
  });

  group('LastHubStore', () {
    test('保存していなければ null', () async {
      expect(await store.loadLastHub(), isNull);
    });

    test('v2 Hub を保存して復元できる(hubId / proto 込み)', () async {
      const hub = DiscoveredHub(
        ip: '192.168.1.20',
        port: 7777,
        name: 'Living Hub',
        hubId: 'hub-uuid-1',
        protocolVersion: 2,
      );

      await store.saveLastHub(hub);
      final restored = await store.loadLastHub();

      expect(restored, isNotNull);
      expect(restored!.ip, '192.168.1.20');
      expect(restored.port, 7777);
      expect(restored.name, 'Living Hub');
      expect(restored.hubId, 'hub-uuid-1');
      expect(restored.protocolVersion, 2);
    });

    test('hubId の無い手動 Hub も往復できる', () async {
      const hub = DiscoveredHub(ip: '10.0.0.5', port: 8888, name: '手動接続');

      await store.saveLastHub(hub);
      final restored = await store.loadLastHub();

      expect(restored, isNotNull);
      expect(restored!.ip, '10.0.0.5');
      expect(restored.port, 8888);
      expect(restored.hubId, isNull);
      expect(restored.protocolVersion, kProtocolVersionLegacy);
    });

    test('保存は上書きされる', () async {
      await store.saveLastHub(
        const DiscoveredHub(ip: '1.1.1.1', port: 1, name: 'A', hubId: 'a'),
      );
      await store.saveLastHub(
        const DiscoveredHub(ip: '2.2.2.2', port: 2, name: 'B', hubId: 'b'),
      );

      final restored = await store.loadLastHub();
      expect(restored!.hubId, 'b');
      expect(restored.ip, '2.2.2.2');
    });

    test('clear で忘れる', () async {
      await store.saveLastHub(
        const DiscoveredHub(ip: '1.1.1.1', port: 1, name: 'A', hubId: 'a'),
      );
      await store.clear();
      expect(await store.loadLastHub(), isNull);
    });
  });
}
