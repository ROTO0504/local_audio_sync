import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';

void main() {
  group('AudioPacket', () {
    test('round-trips serialization correctly', () {
      final opusPayload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      final original = AudioPacket(
        clientId: 1,
        sequence: 100,
        opusBytes: opusPayload,
      );

      final bytes = original.toBytes();
      expect(bytes.length, equals(kHeaderSize + opusPayload.length));
      // Check magic bytes
      expect(bytes[0], equals(0xA1));
      expect(bytes[1], equals(0xA2));

      final restored = AudioPacket.fromBytes(bytes);
      expect(restored, isNotNull);
      expect(restored!.clientId, equals(1));
      expect(restored.sequence, equals(100));
      expect(restored.opusBytes, equals(opusPayload));
    });

    test('fromBytes returns null for too-short buffer', () {
      final result = AudioPacket.fromBytes(Uint8List(3));
      expect(result, isNull);
    });

    test('fromBytes returns null for wrong magic bytes', () {
      final bad = Uint8List(kHeaderSize + 4);
      bad[0] = 0xFF;
      bad[1] = 0xFF;
      final result = AudioPacket.fromBytes(bad);
      expect(result, isNull);
    });

    test('sequence wraps at 0xFFFFFFFF', () {
      final pkt = AudioPacket(
        clientId: 0,
        sequence: 0xFFFFFFFF,
        opusBytes: Uint8List(1),
      );
      final bytes = pkt.toBytes();
      final restored = AudioPacket.fromBytes(bytes);
      expect(restored!.sequence, equals(0xFFFFFFFF));
    });
  });
}
