import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/jitter_buffer.dart';

void main() {
  group('JitterBuffer 基本動作', () {
    late JitterBuffer buffer;

    setUp(() {
      // targetDelayFrames=1 で 1 パケット入った時点から取り出せる
      buffer = JitterBuffer(targetDelayFrames: 1);
    });

    test('順序通りの seq は順番に pop される', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(2, Uint8List.fromList([0x02]));
      buffer.push(3, Uint8List.fromList([0x03]));

      expect(buffer.pop(), equals(Uint8List.fromList([0x01])));
      expect(buffer.pop(), equals(Uint8List.fromList([0x02])));
      expect(buffer.pop(), equals(Uint8List.fromList([0x03])));
    });

    test('順不同(1,3,2)が seq 順に並び替えられる', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(3, Uint8List.fromList([0x03]));
      buffer.push(2, Uint8List.fromList([0x02]));

      expect(buffer.pop(), equals(Uint8List.fromList([0x01])));
      expect(buffer.pop(), equals(Uint8List.fromList([0x02])));
      expect(buffer.pop(), equals(Uint8List.fromList([0x03])));
    });

    test('欠落 seq は null を返して PLC をトリガする', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(3, Uint8List.fromList([0x03]));

      expect(buffer.pop(), isNotNull); // seq 1
      expect(buffer.pop(), isNull, reason: '欠落 seq 2 は null'); // seq 2 → null
    });

    test('全部消費後の pop は null', () {
      buffer.push(1, Uint8List.fromList([0xAA]));
      buffer.pop();
      expect(buffer.pop(), isNull);
      expect(buffer.hasData, isFalse);
    });

    test('再生済み区間の古い seq は棄却される', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(2, Uint8List.fromList([0x02]));
      buffer.pop();
      // 過去 seq 0 は棄却
      final accepted = buffer.push(0, Uint8List.fromList([0x00]));
      expect(accepted, isFalse);
    });
  });

  group('JitterBuffer 再同期', () {
    test('閾値超のジャンプで自動再同期し、コールバックが呼ばれる', () {
      int? notifiedSeq;
      final buffer = JitterBuffer(
        targetDelayFrames: 1,
        resyncThresholdFrames: 10,
        onResyncDetected: (seq) => notifiedSeq = seq,
      );

      // 通常運用
      buffer.push(0, Uint8List.fromList([0x00]));
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.pop();
      expect(buffer.totalResynced, 0);

      // 1000 という遠未来 seq をプッシュ → 再同期発火
      final ok = buffer.push(1000, Uint8List.fromList([0xFF]));
      expect(ok, isTrue);
      expect(buffer.totalResynced, 1);
      expect(notifiedSeq, 1000);
      expect(buffer.nextExpectedSeq, 1000);
    });

    test('送信側がアプリ再起動して seq=0 から振り直しても追従できる', () {
      final buffer = JitterBuffer(
        targetDelayFrames: 1,
        resyncThresholdFrames: 100,
      );
      // 旧経路で seq 500 まで進む
      for (int i = 500; i < 510; i++) {
        buffer.push(i, Uint8List.fromList([i & 0xFF]));
      }
      while (buffer.hasData) {
        buffer.pop();
      }

      // 送信側が再起動して seq 0 から振り直し → 再同期発火
      buffer.push(0, Uint8List.fromList([0x00]));
      expect(buffer.totalResynced, 1);
      expect(buffer.pop(), equals(Uint8List.fromList([0x00])));
    });

    test('閾値内のジャンプは通常受け入れ、再同期しない', () {
      int? notifiedSeq;
      final buffer = JitterBuffer(
        targetDelayFrames: 1,
        resyncThresholdFrames: 100,
        onResyncDetected: (seq) => notifiedSeq = seq,
      );
      buffer.push(0, Uint8List.fromList([0x00]));
      buffer.push(50, Uint8List.fromList([0x32])); // 50 先(閾値内)
      expect(buffer.totalResynced, 0);
      expect(notifiedSeq, isNull);
    });

    test('reset で nextExpectedSeq が null に戻る', () {
      final buffer = JitterBuffer(targetDelayFrames: 1);
      buffer.push(10, Uint8List.fromList([0x0A]));
      expect(buffer.nextExpectedSeq, 10);
      buffer.reset();
      expect(buffer.nextExpectedSeq, isNull);
      expect(buffer.totalReceived, 0);
      expect(buffer.totalResynced, 0);
    });
  });

  group('JitterBuffer 32bit ラップ', () {
    test('seq 0xFFFFFFFE → 0xFFFFFFFF → 0 がラップして順序通り pop', () {
      final buffer = JitterBuffer(targetDelayFrames: 1);
      buffer.push(0xFFFFFFFE, Uint8List.fromList([0xFE]));
      buffer.push(0xFFFFFFFF, Uint8List.fromList([0xFF]));
      buffer.push(0, Uint8List.fromList([0x00]));

      expect(buffer.pop(), equals(Uint8List.fromList([0xFE])));
      expect(buffer.pop(), equals(Uint8List.fromList([0xFF])));
      expect(buffer.pop(), equals(Uint8List.fromList([0x00])));
    });
  });
}
