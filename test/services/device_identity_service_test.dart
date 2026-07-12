import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/device_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceIdentityService.resetCache();
  });

  group('DeviceIdentityService', () {
    test('初回は UUID を生成し、2 回目以降は同じ値を返す', () async {
      final service = DeviceIdentityService();
      final first = await service.getClientUuid();
      final second = await service.getClientUuid();

      expect(first, isNotEmpty);
      expect(second, equals(first));
    });

    test('生成した UUID は shared_preferences に保存される', () async {
      final service = DeviceIdentityService();
      final uuid = await service.getClientUuid();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('device_identity_client_uuid'), equals(uuid));
    });

    test('保存済みの UUID があればそれを返す(再起動を模擬)', () async {
      SharedPreferences.setMockInitialValues({
        'device_identity_client_uuid': 'stored-uuid-123',
      });
      DeviceIdentityService.resetCache();

      final service = DeviceIdentityService();
      expect(await service.getClientUuid(), 'stored-uuid-123');
    });

    test('別インスタンスでも同じ UUID を返す', () async {
      final a = await DeviceIdentityService().getClientUuid();
      DeviceIdentityService.resetCache(); // メモリキャッシュを消しても
      final b = await DeviceIdentityService().getClientUuid();
      expect(b, equals(a)); // prefs から同じ値が読める
    });

    test('クライアント UUID と Hub ID は独立した値', () async {
      final service = DeviceIdentityService();
      final clientUuid = await service.getClientUuid();
      final hubId = await service.getHubId();

      expect(clientUuid, isNot(equals(hubId)));
      // それぞれ永続する
      expect(await service.getClientUuid(), clientUuid);
      expect(await service.getHubId(), hubId);
    });
  });
}
