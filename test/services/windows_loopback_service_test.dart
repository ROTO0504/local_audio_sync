import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/windows_loopback_service.dart';

void main() {
  group('WindowsLoopbackService', () {
    test('Windows 以外では initFfi が no-op で例外を投げない', () {
      // CI の Linux runner などでも flutter test が走るので、
      // initFfi が安全に呼べることを確認する。
      WindowsLoopbackService.initFfi();
      expect(true, isTrue);
    });

    test('Windows 以外で start() を呼ぶと WindowsLoopbackException', () async {
      if (Platform.isWindows) {
        // Windows ではここを通せない(DLL ロード判定が走るため別経路)
        return;
      }
      final svc = WindowsLoopbackService();
      try {
        await svc.start();
        fail('非 Windows で例外が出ませんでした');
      } on WindowsLoopbackException catch (e) {
        expect(e.message, contains('audio_mixer_plugin.dll'));
      } finally {
        svc.dispose();
      }
    });

    test('stop() は未開始でも安全に呼べる', () async {
      final svc = WindowsLoopbackService();
      await svc.stop(); // 例外が出ないこと
      expect(svc.isRunning, isFalse);
      svc.dispose();
    });

    test('pendingFrames は未初期化時に 0', () {
      final svc = WindowsLoopbackService();
      // initFfi 失敗時(非 Windows)を想定
      if (!Platform.isWindows) {
        expect(svc.pendingFrames(), 0);
      }
      svc.dispose();
    });
  });
}
