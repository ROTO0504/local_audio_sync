import 'dart:async';
import '../models/control_messages.dart';

/// Hub → Client のリモート制御コマンド(CMD)の再送キュー。
///
/// UDP には到達保証がないため、CMDACK を受け取るまで [retryInterval] 間隔で
/// 同じ commandSeq のまま再送する。[maxAttempts] 回送っても ACK が来なければ
/// 諦めて [onGiveUp] に通知する(UI 側でエラー表示する)。
class CommandRetryQueue {
  CommandRetryQueue({
    required this.send,
    this.retryInterval = const Duration(milliseconds: 500),
    this.maxAttempts = 5,
  });

  /// 実際の送信処理。ソケットを持つ側(UdpReceiverService)が注入する。
  final void Function(RemoteCommand command, String ip, int port) send;

  final Duration retryInterval;
  final int maxAttempts;

  /// maxAttempts 回送っても ACK が来なかったときに呼ばれる。
  void Function(RemoteCommand command)? onGiveUp;

  int _nextCommandSeq = 1;
  final Map<int, _PendingCommand> _pending = {};

  /// ACK 待ちのコマンド数(テスト・デバッグ用)。
  int get pendingCount => _pending.length;

  /// コマンドを発番して送信し、ACK が来るまで再送する。
  /// 発番した commandSeq を返す。
  int enqueue(int clientId, RemoteCommandAction action, String ip, int port) {
    final command = RemoteCommand(
      clientId: clientId,
      commandSeq: _nextCommandSeq++,
      action: action,
    );
    send(command, ip, port);

    final pending = _PendingCommand(command, ip, port);
    pending.timer = Timer.periodic(retryInterval, (_) {
      if (pending.attempts >= maxAttempts) {
        _remove(command.commandSeq);
        onGiveUp?.call(command);
        return;
      }
      pending.attempts++;
      send(command, ip, port);
    });
    _pending[command.commandSeq] = pending;
    return command.commandSeq;
  }

  /// CMDACK を受け取ったら該当コマンドの再送を止める。
  void handleAck(int commandSeq) {
    _remove(commandSeq);
  }

  void _remove(int commandSeq) {
    _pending.remove(commandSeq)?.timer?.cancel();
  }

  /// すべての再送を止める(Hub 停止時)。
  void dispose() {
    for (final pending in _pending.values) {
      pending.timer?.cancel();
    }
    _pending.clear();
  }
}

class _PendingCommand {
  _PendingCommand(this.command, this.ip, this.port);

  final RemoteCommand command;
  final String ip;
  final int port;

  /// 送信済み回数(enqueue 直後の 1 回を含む)。
  int attempts = 1;
  Timer? timer;
}
