import 'dart:typed_data';

/// UDP 音声パケットのバイナリフォーマット。
///
/// v1(レガシー, 8byte ヘッダ):
///   [0x00-0x01] Magic: 0xA1 0xA2
///   [0x02-0x03] Client ID (uint16 big-endian)
///   [0x04-0x07] Sequence number (uint32 big-endian)
///   [0x08-...]  Opus payload
///
/// v2(13byte ヘッダ, 本コミットで追加):
///   [0x00-0x01] Magic: 0xA1 0xA3
///   [0x02-0x03] Client ID (uint16 big-endian)
///   [0x04-0x07] Sequence number (uint32 big-endian)
///   [0x08-0x0B] 送信タイムスタンプ(uint32 big-endian, 送信側の単調増加 ms。
///               ジッタ推定・再生タイミングの基準に使う。約49.7日でラップ)
///   [0x0C]      フラグ(bit0: RED 冗長ペイロードあり / bit1: DTX 無音マーカ。
///               いずれもフェーズ2で使用。現状は 0)
///   [0x0D-...]  Opus payload
///
/// 受信側は v2 / v1 の両方を解釈する(新クライアント→旧Hub のロールアウト時に
/// 旧Hubが壊れないよう、また新Hubが旧クライアントを受けられるように)。
const int _kMagic0 = 0xA1;
const int _kMagicV1 = 0xA2;
const int _kMagicV2 = 0xA3;

/// v1 ヘッダ長(レガシー)。
const int kHeaderSize = 8;

/// v2 ヘッダ長。
const int kHeaderSizeV2 = 13;

/// フラグ: RED(冗長)ペイロードを含む。
const int kAudioFlagRed = 0x01;

/// フラグ: DTX(無音)マーカ。
const int kAudioFlagDtx = 0x02;

class AudioPacket {
  final int clientId;
  final int sequence;
  final Uint8List opusBytes;

  /// 送信側の単調増加タイムスタンプ(ms)。v1 受信時は 0。
  final int timestampMs;

  /// パケットフラグ([kAudioFlagRed] / [kAudioFlagDtx])。v1 受信時は 0。
  final int flags;

  const AudioPacket({
    required this.clientId,
    required this.sequence,
    required this.opusBytes,
    this.timestampMs = 0,
    this.flags = 0,
  });

  /// UDP データグラムへシリアライズする(v2 フォーマットで出力)。
  Uint8List toBytes() {
    final buf = ByteData(kHeaderSizeV2 + opusBytes.length);
    buf.setUint8(0, _kMagic0);
    buf.setUint8(1, _kMagicV2);
    buf.setUint16(2, clientId, Endian.big);
    buf.setUint32(4, sequence, Endian.big);
    buf.setUint32(8, timestampMs & 0xFFFFFFFF, Endian.big);
    buf.setUint8(12, flags & 0xFF);
    final bytes = buf.buffer.asUint8List();
    bytes.setRange(kHeaderSizeV2, bytes.length, opusBytes);
    return bytes;
  }

  /// 生データグラムからデシリアライズする。パース失敗時 null。
  /// v2(0xA1 0xA3)と v1(0xA1 0xA2)の両方を受理する。
  static AudioPacket? fromBytes(Uint8List data) {
    if (data.length < kHeaderSize) return null;
    final buf = ByteData.sublistView(data);
    if (buf.getUint8(0) != _kMagic0) return null;

    final magic1 = buf.getUint8(1);
    if (magic1 == _kMagicV2) {
      if (data.length < kHeaderSizeV2) return null;
      return AudioPacket(
        clientId: buf.getUint16(2, Endian.big),
        sequence: buf.getUint32(4, Endian.big),
        timestampMs: buf.getUint32(8, Endian.big),
        flags: buf.getUint8(12),
        opusBytes: data.sublist(kHeaderSizeV2),
      );
    }
    if (magic1 == _kMagicV1) {
      return AudioPacket(
        clientId: buf.getUint16(2, Endian.big),
        sequence: buf.getUint32(4, Endian.big),
        opusBytes: data.sublist(kHeaderSize),
      );
    }
    return null;
  }
}
