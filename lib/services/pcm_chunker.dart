import 'dart:typed_data';
import 'pcm_constants.dart';

/// 任意サイズで届く PCM バイト列を、エンコーダや UDP 送信が期待する固定サイズの
/// チャンク([kBytesPerChunk] = 3840 byte = 20ms)に揃えるためのユーティリティ。
///
/// プラットフォーム実装(iOS Broadcast Extension、Android MediaProjection、
/// macOS ScreenCaptureKit、Windows WASAPI)から届くバッファサイズはまちまち
/// なので、ここで吸収する。
///
/// 使い方:
///   final chunker = PcmChunker();
///   for (final chunk in chunker.add(rawBytes)) {
///     // chunk.length == kBytesPerChunk(必ず)
///     send(chunk);
///   }
///
/// 残ったバイトは次回 [add] のときに先頭に連結される。バッファに残りがある場合に
/// [pendingBytes] で取り出せる(ハートビートやリセットのため)。
class PcmChunker {
  final int chunkSize;
  Uint8List _carry = Uint8List(0);

  PcmChunker({this.chunkSize = kBytesPerChunk});

  /// 入力を蓄積し、揃った 1 チャンクごとに yield する。
  /// 返値の各バイト列は新しい [Uint8List] でコピー済み(呼び出し側が自由に保持できる)。
  Iterable<Uint8List> add(Uint8List incoming) sync* {
    if (incoming.isEmpty && _carry.isEmpty) return;

    // _carry と incoming を連結。
    final merged = Uint8List(_carry.length + incoming.length);
    merged.setRange(0, _carry.length, _carry);
    merged.setRange(_carry.length, merged.length, incoming);

    int offset = 0;
    while (merged.length - offset >= chunkSize) {
      yield Uint8List.fromList(
        merged.sublist(offset, offset + chunkSize),
      );
      offset += chunkSize;
    }

    // 残り(端数)を _carry に保存
    if (offset < merged.length) {
      _carry = Uint8List.fromList(merged.sublist(offset));
    } else {
      _carry = Uint8List(0);
    }
  }

  /// 現在の中間バッファサイズ(byte)。
  int get pendingBytes => _carry.length;

  /// 内部バッファをクリア(ストリーム再開時など)。
  void reset() {
    _carry = Uint8List(0);
  }
}
