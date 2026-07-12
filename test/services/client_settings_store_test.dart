import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/client_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientSettingsStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = ClientSettingsStore();
  });

  group('ClientSettingsStore', () {
    test('保存した設定を同じ uuid で復元できる', () async {
      await store.save(
        'uuid-a',
        const ClientSettings(volume: 0.3, isMuted: true),
      );

      final loaded = await store.load('uuid-a');
      expect(loaded, isNotNull);
      expect(loaded!.volume, closeTo(0.3, 0.001));
      expect(loaded.isMuted, isTrue);
    });

    test('未保存の uuid は null', () async {
      expect(await store.load('unknown-uuid'), isNull);
    });

    test('uuid ごとに独立して保存される', () async {
      await store.save('uuid-a', const ClientSettings(volume: 0.2));
      await store.save('uuid-b', const ClientSettings(volume: 0.9));

      expect((await store.load('uuid-a'))!.volume, closeTo(0.2, 0.001));
      expect((await store.load('uuid-b'))!.volume, closeTo(0.9, 0.001));
    });

    test('上書き保存で最新の値が返る', () async {
      await store.save('uuid-a', const ClientSettings(volume: 0.5));
      await store.save(
        'uuid-a',
        const ClientSettings(volume: 0.8, isMuted: true),
      );

      final loaded = await store.load('uuid-a');
      expect(loaded!.volume, closeTo(0.8, 0.001));
      expect(loaded.isMuted, isTrue);
    });

    test('remove で設定が消える', () async {
      await store.save('uuid-a', const ClientSettings(volume: 0.5));
      await store.remove('uuid-a');
      expect(await store.load('uuid-a'), isNull);
    });

    test('壊れた JSON は null(クラッシュしない)', () async {
      SharedPreferences.setMockInitialValues({
        'client_settings_uuid-broken': '{not json',
      });
      expect(await store.load('uuid-broken'), isNull);
    });

    test('範囲外の音量はクランプされる', () async {
      SharedPreferences.setMockInitialValues({
        'client_settings_uuid-c': '{"volume": 5.0, "isMuted": false}',
      });
      final loaded = await store.load('uuid-c');
      expect(loaded!.volume, 1.0);
    });
  });
}
