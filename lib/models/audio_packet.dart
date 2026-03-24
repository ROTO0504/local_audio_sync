import 'dart:typed_data';

/// Binary packet format:
/// [0x00-0x01] Magic: 0xA1 0xA2
/// [0x02-0x03] Client ID (uint16 big-endian)
/// [0x04-0x07] Sequence number (uint32 big-endian)
/// [0x08-...] Opus payload bytes
const int _kMagic0 = 0xA1;
const int _kMagic1 = 0xA2;
const int kHeaderSize = 8;

class AudioPacket {
  final int clientId;
  final int sequence;
  final Uint8List opusBytes;

  const AudioPacket({
    required this.clientId,
    required this.sequence,
    required this.opusBytes,
  });

  /// Serialize to UDP datagram bytes.
  Uint8List toBytes() {
    final buf = ByteData(kHeaderSize + opusBytes.length);
    buf.setUint8(0, _kMagic0);
    buf.setUint8(1, _kMagic1);
    buf.setUint16(2, clientId, Endian.big);
    buf.setUint32(4, sequence, Endian.big);
    final bytes = buf.buffer.asUint8List();
    bytes.setRange(kHeaderSize, bytes.length, opusBytes);
    return bytes;
  }

  /// Deserialize from raw datagram bytes. Returns null on parse failure.
  static AudioPacket? fromBytes(Uint8List data) {
    if (data.length < kHeaderSize) return null;
    final buf = ByteData.sublistView(data);
    if (buf.getUint8(0) != _kMagic0 || buf.getUint8(1) != _kMagic1) {
      return null;
    }
    final clientId = buf.getUint16(2, Endian.big);
    final sequence = buf.getUint32(4, Endian.big);
    final opusBytes = data.sublist(kHeaderSize);
    return AudioPacket(
      clientId: clientId,
      sequence: sequence,
      opusBytes: opusBytes,
    );
  }
}
