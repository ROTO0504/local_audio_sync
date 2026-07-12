import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';

void main() {
  group('AudioPacket', () {
    test('round-trips serialization correctly (v2)', () {
      final opusPayload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      final original = AudioPacket(
        clientId: 1,
        sequence: 100,
        timestampMs: 123456,
        flags: kAudioFlagDtx,
        opusBytes: opusPayload,
      );

      final bytes = original.toBytes();
      expect(bytes.length, equals(kHeaderSizeV2 + opusPayload.length));
      // v2 マジック
      expect(bytes[0], equals(0xA1));
      expect(bytes[1], equals(0xA3));

      final restored = AudioPacket.fromBytes(bytes);
      expect(restored, isNotNull);
      expect(restored!.clientId, equals(1));
      expect(restored.sequence, equals(100));
      expect(restored.timestampMs, equals(123456));
      expect(restored.flags, equals(kAudioFlagDtx));
      expect(restored.opusBytes, equals(opusPayload));
    });

    test('parses legacy v1 packets (0xA1 0xA2, no timestamp)', () {
      // 手組みの v1 データグラム(8byte ヘッダ + payload)。
      final payload = Uint8List.fromList([0xAA, 0xBB]);
      final buf = ByteData(kHeaderSize + payload.length);
      buf.setUint8(0, 0xA1);
      buf.setUint8(1, 0xA2);
      buf.setUint16(2, 7, Endian.big);
      buf.setUint32(4, 42, Endian.big);
      final bytes = buf.buffer.asUint8List();
      bytes.setRange(kHeaderSize, bytes.length, payload);

      final restored = AudioPacket.fromBytes(bytes);
      expect(restored, isNotNull);
      expect(restored!.clientId, equals(7));
      expect(restored.sequence, equals(42));
      expect(restored.timestampMs, equals(0));
      expect(restored.flags, equals(0));
      expect(restored.opusBytes, equals(payload));
    });

    test('fromBytes returns null for too-short buffer', () {
      final result = AudioPacket.fromBytes(Uint8List(3));
      expect(result, isNull);
    });

    test('fromBytes returns null for wrong magic bytes', () {
      final bad = Uint8List(kHeaderSizeV2 + 4);
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

    test('timestampMs wraps at 0xFFFFFFFF', () {
      final pkt = AudioPacket(
        clientId: 0,
        sequence: 0,
        timestampMs: 0xFFFFFFFF,
        opusBytes: Uint8List(1),
      );
      final restored = AudioPacket.fromBytes(pkt.toBytes());
      expect(restored!.timestampMs, equals(0xFFFFFFFF));
    });
  });
}
