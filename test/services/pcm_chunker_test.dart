import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/pcm_chunker.dart';

void main() {
  group('PcmChunker', () {
    test('チャンクサイズちょうどの入力はそのまま 1 個 yield', () {
      final chunker = PcmChunker(chunkSize: 4);
      final chunks =
          chunker.add(Uint8List.fromList([1, 2, 3, 4])).toList();
      expect(chunks, hasLength(1));
      expect(chunks.first, equals(Uint8List.fromList([1, 2, 3, 4])));
      expect(chunker.pendingBytes, 0);
    });

    test('チャンクサイズ未満は端数として保持', () {
      final chunker = PcmChunker(chunkSize: 4);
      final chunks =
          chunker.add(Uint8List.fromList([1, 2, 3])).toList();
      expect(chunks, isEmpty);
      expect(chunker.pendingBytes, 3);
    });

    test('複数回の add で端数が連結される', () {
      final chunker = PcmChunker(chunkSize: 4);
      expect(chunker.add(Uint8List.fromList([1, 2, 3])).toList(), isEmpty);
      final out = chunker.add(Uint8List.fromList([4, 5, 6, 7, 8])).toList();
      expect(out, hasLength(2));
      expect(out[0], equals(Uint8List.fromList([1, 2, 3, 4])));
      expect(out[1], equals(Uint8List.fromList([5, 6, 7, 8])));
      expect(chunker.pendingBytes, 0);
    });

    test('巨大入力は複数チャンクに分割', () {
      final chunker = PcmChunker(chunkSize: 4);
      final big = Uint8List(20);
      for (int i = 0; i < 20; i++) {
        big[i] = i;
      }
      final out = chunker.add(big).toList();
      expect(out, hasLength(5));
      expect(out[0], equals(Uint8List.fromList([0, 1, 2, 3])));
      expect(out[4], equals(Uint8List.fromList([16, 17, 18, 19])));
    });

    test('chunkSize の倍数 + 端数を 1 回で処理', () {
      final chunker = PcmChunker(chunkSize: 4);
      final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      final out = chunker.add(input).toList();
      expect(out, hasLength(1));
      expect(out[0], equals(Uint8List.fromList([1, 2, 3, 4])));
      expect(chunker.pendingBytes, 3);
    });

    test('reset でキャリーがクリアされる', () {
      final chunker = PcmChunker(chunkSize: 4);
      chunker.add(Uint8List.fromList([1, 2])).toList();
      expect(chunker.pendingBytes, 2);
      chunker.reset();
      expect(chunker.pendingBytes, 0);
      // reset 後は新しいキャリーから開始
      final out = chunker.add(Uint8List.fromList([10, 20, 30, 40])).toList();
      expect(out.first, equals(Uint8List.fromList([10, 20, 30, 40])));
    });

    test('空入力で何も yield しない', () {
      final chunker = PcmChunker(chunkSize: 4);
      expect(chunker.add(Uint8List(0)).toList(), isEmpty);
    });

    test('返ってくるチャンクは独立コピー(後の add で改変されない)', () {
      final chunker = PcmChunker(chunkSize: 4);
      final chunks =
          chunker.add(Uint8List.fromList([1, 2, 3, 4])).toList();
      // さらに別のデータを追加
      chunker.add(Uint8List.fromList([9, 9, 9, 9])).toList();
      // 既に取得済みのチャンクは変わっていないこと
      expect(chunks.first, equals(Uint8List.fromList([1, 2, 3, 4])));
    });

    test('デフォルトのチャンクサイズは 3840 byte(20ms ステレオ 48kHz)', () {
      final chunker = PcmChunker();
      final input = Uint8List(3840);
      final out = chunker.add(input).toList();
      expect(out, hasLength(1));
      expect(out.first.length, 3840);
    });
  });
}
