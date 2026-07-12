import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/control_messages.dart';
import 'package:local_audio_sync/services/command_retry_queue.dart';

void main() {
  group('CommandRetryQueue', () {
    test('enqueue で即座に 1 回送信され commandSeq が発番される', () {
      final sent = <RemoteCommand>[];
      final queue = CommandRetryQueue(
        send: (cmd, ip, port) => sent.add(cmd),
        retryInterval: const Duration(milliseconds: 20),
        maxAttempts: 3,
      );

      final seq1 =
          queue.enqueue(1, RemoteCommandAction.pause, '10.0.0.2', 5000);
      final seq2 =
          queue.enqueue(2, RemoteCommandAction.stop, '10.0.0.3', 5001);

      expect(sent, hasLength(2));
      expect(sent[0].commandSeq, seq1);
      expect(sent[1].commandSeq, seq2);
      expect(seq2, greaterThan(seq1)); // 単調増加

      queue.dispose();
    });

    test('ACK が来なければ再送し、maxAttempts で諦めて onGiveUp を呼ぶ', () async {
      final sent = <RemoteCommand>[];
      final gaveUp = <RemoteCommand>[];
      final queue = CommandRetryQueue(
        send: (cmd, ip, port) => sent.add(cmd),
        retryInterval: const Duration(milliseconds: 20),
        maxAttempts: 3,
      );
      queue.onGiveUp = gaveUp.add;

      queue.enqueue(1, RemoteCommandAction.pause, '10.0.0.2', 5000);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 初回 + 再送 2 回 = maxAttempts(3)回送信し、その後諦める
      expect(sent, hasLength(3));
      expect(gaveUp, hasLength(1));
      expect(queue.pendingCount, 0);
      // 再送はすべて同じ commandSeq(受信側の重複排除が効くように)
      expect(sent.map((c) => c.commandSeq).toSet(), hasLength(1));

      queue.dispose();
    });

    test('handleAck で再送が止まり onGiveUp は呼ばれない', () async {
      final sent = <RemoteCommand>[];
      final gaveUp = <RemoteCommand>[];
      final queue = CommandRetryQueue(
        send: (cmd, ip, port) => sent.add(cmd),
        retryInterval: const Duration(milliseconds: 20),
        maxAttempts: 5,
      );
      queue.onGiveUp = gaveUp.add;

      final seq =
          queue.enqueue(1, RemoteCommandAction.resume, '10.0.0.2', 5000);
      queue.handleAck(seq);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(sent, hasLength(1)); // 再送されない
      expect(gaveUp, isEmpty);
      expect(queue.pendingCount, 0);

      queue.dispose();
    });

    test('存在しない commandSeq の ACK は無視される', () {
      final queue = CommandRetryQueue(
        send: (cmd, ip, port) {},
        retryInterval: const Duration(milliseconds: 20),
      );
      expect(() => queue.handleAck(999), returnsNormally);
      queue.dispose();
    });

    test('dispose で全ての再送が止まる', () async {
      final sent = <RemoteCommand>[];
      final queue = CommandRetryQueue(
        send: (cmd, ip, port) => sent.add(cmd),
        retryInterval: const Duration(milliseconds: 20),
        maxAttempts: 10,
      );

      queue.enqueue(1, RemoteCommandAction.pause, '10.0.0.2', 5000);
      queue.enqueue(2, RemoteCommandAction.stop, '10.0.0.3', 5000);
      queue.dispose();

      final countAtDispose = sent.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(sent.length, countAtDispose); // dispose 後は送信なし
      expect(queue.pendingCount, 0);
    });
  });
}
