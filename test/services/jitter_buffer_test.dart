import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/jitter_buffer.dart';

void main() {
  group('JitterBuffer', () {
    late JitterBuffer buffer;

    setUp(() {
      // Use targetDelayFrames=1 so pop() returns immediately after 1 packet
      buffer = JitterBuffer(targetDelayFrames: 1);
    });

    test('in-order packets are popped in sequence order', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(2, Uint8List.fromList([0x02]));
      buffer.push(3, Uint8List.fromList([0x03]));

      final f1 = buffer.pop();
      final f2 = buffer.pop();
      final f3 = buffer.pop();

      expect(f1, equals(Uint8List.fromList([0x01])));
      expect(f2, equals(Uint8List.fromList([0x02])));
      expect(f3, equals(Uint8List.fromList([0x03])));
    });

    test('out-of-order packets (1,3,2) are popped in order', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(3, Uint8List.fromList([0x03]));
      buffer.push(2, Uint8List.fromList([0x02]));

      final f1 = buffer.pop();
      final f2 = buffer.pop();
      final f3 = buffer.pop();

      expect(f1, equals(Uint8List.fromList([0x01])));
      expect(f2, equals(Uint8List.fromList([0x02])));
      expect(f3, equals(Uint8List.fromList([0x03])));
    });

    test('missing sequence returns null (PLC trigger)', () {
      // Push seq 1 and seq 3, skip seq 2
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(3, Uint8List.fromList([0x03]));

      final f1 = buffer.pop(); // seq 1 — present
      expect(f1, isNotNull);

      final plc = buffer.pop(); // seq 2 — missing → null for PLC
      expect(plc, isNull, reason: 'Missing packet should return null for PLC');
    });

    test('buffer is empty after all packets consumed', () {
      buffer.push(1, Uint8List.fromList([0xAA]));
      buffer.pop(); // consumes seq 1
      final extra = buffer.pop(); // buffer empty → null
      expect(extra, isNull);
      expect(buffer.hasData, isFalse);
    });

    test('duplicate older sequence is dropped', () {
      buffer.push(1, Uint8List.fromList([0x01]));
      buffer.push(2, Uint8List.fromList([0x02]));
      buffer.pop(); // consume seq 1
      // Push seq 0 — older than current expected (seq 2), should be dropped
      final accepted = buffer.push(0, Uint8List.fromList([0x00]));
      expect(accepted, isFalse);
    });
  });
}
