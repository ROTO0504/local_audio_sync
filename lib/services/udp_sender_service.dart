import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/audio_packet.dart';
import '../models/control_messages.dart';

/// 音声パケット(Opus)を Hub に UDP ユニキャスト送信するクライアント側サービス。
///
/// 旧実装の弱点:
///   - send 失敗時にソケットが死んでも再生成しなかった
///   - Hub の IP が変わったときに追従できず、無音を送り続けた
///   - PING の応答(PONG)を期待しないので、Hub の生死をここから検知できなかった
///
/// 本実装では:
///   - send 例外時にソケットを閉じて再生成 + 指数バックオフで再接続
///   - HELLO 応答待ちを Future として明示し、タイムアウト時に内部状態を一掃
///   - 接続が確立した後の Hub IP 変更要求(reconnect)を受け付ける
///
/// プロトコル v2 で以下を追加:
///   - HELLO2(platform / protocolVersion 付き)を v1 HELLO と併送。
///     新 Hub は HELLO2 を、旧 Hub は HELLO を拾うのでどちらにも接続できる
///   - PONG 受信による Hub 生存監視(v2 Hub のみ。PONG を一度も受けていない
///     旧 Hub 相手では判定しない)
///   - CMD 受信(リモート制御)→ CMDACK 応答 + commandSeq による重複排除
class UdpSenderService {
  UdpSenderService({
    Duration? pingInterval,
    Duration? pongTimeout,
  })  : _pingInterval = pingInterval ?? const Duration(seconds: 5),
        _pongTimeout = pongTimeout ?? const Duration(seconds: 15);

  final Duration _pingInterval;
  final Duration _pongTimeout;

  RawDatagramSocket? _socket;
  StreamSubscription? _socketSub;

  String? _hubIp;
  int _hubPort = 7777;
  String? _deviceName;
  String? _uuid;
  String? _platform;

  int _clientId = 0;
  int _sequence = 0;
  Timer? _pingTimer;

  /// PONG による Hub 生存監視の状態。
  DateTime? _lastPongAt;
  bool _pongSupported = false;
  bool _hubUnresponsiveNotified = false;

  /// 実行済み CMD の commandSeq(重複実行防止、直近 64 件を保持)。
  final LinkedHashSet<int> _handledCommandSeqs = LinkedHashSet<int>();
  static const int _handledCommandSeqsMax = 64;

  /// 再接続用の指数バックオフ次回間隔(ms)。
  int _retryDelayMs = 200;
  static const int _retryDelayMaxMs = 5000;

  /// 接続失敗回数(統計用)。
  int _consecutiveFailures = 0;
  int get consecutiveFailures => _consecutiveFailures;

  /// Hub からのリモート制御コマンドを受けたときに呼ばれる。
  /// (重複排除済み。同じ commandSeq の再送では発火しない)
  void Function(RemoteCommandAction action)? onRemoteCommand;

  /// PONG が [_pongTimeout] を超えて途絶えたときに一度だけ呼ばれる。
  /// 呼び出し側で切断・再探索に戻すことを想定。
  VoidCallback? onHubUnresponsive;

  bool get isConnected => _socket != null && _hubIp != null && _clientId != 0;
  String? get hubIp => _hubIp;
  int get clientId => _clientId;

  /// Hub への接続を確立する。HELLO を投げて ACKHELLO で clientId を受け取る。
  ///
  /// [platform] は `ios` / `android` などの OS 識別子。省略時は実行環境から
  /// 判定する(テストでは明示指定する)。
  Future<void> connect(
    String hubIp,
    int hubPort,
    String deviceName,
    String uuid, {
    String? platform,
  }) async {
    _hubIp = hubIp;
    _hubPort = hubPort;
    _deviceName = deviceName;
    _uuid = uuid;
    _platform = platform ?? Platform.operatingSystem;
    await _establishSocket();
  }

  /// 既知の(_hubIp / _deviceName / _uuid)を使って物理ソケットを張り直す。
  /// バックオフを含めずに 1 回だけ試みる。失敗したら例外を投げる。
  Future<void> _establishSocket() async {
    if (_hubIp == null || _deviceName == null || _uuid == null) {
      throw StateError('Hub IP / デバイス名 / UUID が未設定');
    }

    // 既存ソケットを片付ける
    await _closeSocket();

    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket = sock;

    final completer = Completer<void>();
    _socketSub = sock.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        // 1 回の read イベントに複数のデータグラムが溜まっていることが
        // あるため、null が返るまでドレインする(制御メッセージの
        // 取りこぼし防止)。
        while (true) {
          final dg = sock.receive();
          if (dg == null) break;
          _handleIncomingText(String.fromCharCodes(dg.data), completer);
        }
      },
      onError: (Object err) {
        debugPrint('[UdpSender] socket error: $err');
        if (!completer.isCompleted) {
          completer.completeError(err);
        }
      },
      cancelOnError: false,
    );

    // HELLO2(v2)と HELLO(v1)を併送する。新 Hub は HELLO2 を優先して
    // 拾い、旧 Hub は HELLO2 を無視して HELLO だけを処理する。
    final hello = ClientHello(
      name: _deviceName!,
      uuid: _uuid!,
      platform: _platform ?? 'unknown',
      protocolVersion: kProtocolVersion,
    );
    _sendText(hello.encodeHello2());
    _sendText(hello.encodeHelloV1());

    try {
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Hub からの ACKHELLO がありません'),
      );
    } catch (e) {
      await _closeSocket();
      _consecutiveFailures++;
      rethrow;
    }

    _consecutiveFailures = 0;
    _retryDelayMs = 200;
    _startPing();
  }

  /// Hub からの受信テキストを処理する。
  void _handleIncomingText(String text, Completer<void> helloCompleter) {
    if (text.startsWith('ACKHELLO:')) {
      final parts = text.split(':');
      if (parts.length >= 2) {
        _clientId = int.tryParse(parts[1]) ?? 0;
        // 新しいセッションが始まったので生存監視と CMD 履歴をリセット
        _lastPongAt = null;
        _pongSupported = false;
        _hubUnresponsiveNotified = false;
        _handledCommandSeqs.clear();
        if (!helloCompleter.isCompleted) helloCompleter.complete();
      }
      return;
    }
    if (text.startsWith('RESYNC:')) {
      // Hub から「seq を 0 に戻して送り直せ」と要求された
      final id = int.tryParse(text.substring(7));
      if (id == null || id == _clientId) {
        debugPrint('[UdpSender] RESYNC 受信、sequence をリセット');
        _sequence = 0;
      }
      return;
    }
    _handleV2Message(text);
  }

  /// PONG / CMD などプロトコル v2 の受信メッセージを処理する。
  void _handleV2Message(String text) {
    final pongId = parsePong(text);
    if (pongId != null) {
      if (pongId == _clientId) {
        _lastPongAt = DateTime.now();
        _pongSupported = true;
        _hubUnresponsiveNotified = false;
      }
      return;
    }

    final command = RemoteCommand.parse(text);
    if (command != null) {
      if (command.clientId != _clientId) return;
      // ACK は再送分にも毎回返す(Hub 側の再送を止めるため)
      _sendText(
        CommandAck(clientId: _clientId, commandSeq: command.commandSeq)
            .encode(),
      );
      if (_handledCommandSeqs.contains(command.commandSeq)) return;
      _handledCommandSeqs.add(command.commandSeq);
      if (_handledCommandSeqs.length > _handledCommandSeqsMax) {
        _handledCommandSeqs.remove(_handledCommandSeqs.first);
      }
      onRemoteCommand?.call(command.action);
    }
  }

  /// HELLO を送り直して再接続を試みる。失敗時はバックオフで再試行を呼び出し側が回す。
  Future<bool> reconnect() async {
    try {
      await _establishSocket();
      return true;
    } catch (e) {
      debugPrint('[UdpSender] 再接続失敗: $e');
      return false;
    }
  }

  /// バックオフ付きで非同期に再接続を試みる(失敗してもアプリは継続)。
  Future<void> reconnectWithBackoff() async {
    final delay = _retryDelayMs;
    _retryDelayMs = (_retryDelayMs * 2).clamp(0, _retryDelayMaxMs);
    await Future<void>.delayed(Duration(milliseconds: delay));
    await reconnect();
  }

  /// Hub IP が変わったときに呼ぶ(Discovery 経由など)。
  Future<void> switchHub(String hubIp, int hubPort) async {
    if (_hubIp == hubIp && _hubPort == hubPort && isConnected) return;
    _hubIp = hubIp;
    _hubPort = hubPort;
    if (_deviceName != null && _uuid != null) {
      await reconnect();
    }
  }

  /// Opus フレームを送る。送信失敗時はソケットを閉じて再接続をスケジュール。
  void sendAudio(Uint8List opusBytes) {
    if (!isConnected) return;
    final packet = AudioPacket(
      clientId: _clientId,
      sequence: _sequence,
      opusBytes: opusBytes,
    );
    _sequence = (_sequence + 1) & 0xFFFFFFFF;
    _sendBytes(packet.toBytes());
  }

  /// 接続を断つ(BYE 通知 + ソケット閉じ)。
  void disconnect() {
    if (_clientId != 0 && _socket != null) {
      try {
        _sendText('BYE:$_clientId');
      } catch (_) {}
    }
    _pingTimer?.cancel();
    _pingTimer = null;
    _closeSocket();
    _hubIp = null;
    _sequence = 0;
    _clientId = 0;
    _deviceName = null;
    _uuid = null;
    _platform = null;
    _retryDelayMs = 200;
    _lastPongAt = null;
    _pongSupported = false;
    _hubUnresponsiveNotified = false;
    _handledCommandSeqs.clear();
  }

  // ---- 内部 ----

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _sendText('PING:$_clientId');
      _checkPongHealth();
    });
  }

  /// PONG ベースの Hub 生存確認。
  ///
  /// PONG を一度も受けていない(= 旧 Hub か、まだ届いていない)間は
  /// 判定しない。ビーコン喪失検出(DiscoveryService)は別途動いているので、
  /// ここは v2 Hub 相手の早期検知として補完的に働く。
  void _checkPongHealth() {
    if (!_pongSupported || _hubUnresponsiveNotified) return;
    final last = _lastPongAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > _pongTimeout) {
      _hubUnresponsiveNotified = true;
      debugPrint('[UdpSender] PONG が途絶えました(Hub 応答なし)');
      onHubUnresponsive?.call();
    }
  }

  Future<void> _closeSocket() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void _sendText(String text) {
    _sendBytes(Uint8List.fromList(text.codeUnits));
  }

  void _sendBytes(Uint8List data) {
    final sock = _socket;
    final ip = _hubIp;
    if (sock == null || ip == null) return;
    try {
      sock.send(data, InternetAddress(ip), _hubPort);
    } catch (e) {
      debugPrint('[UdpSender] send 失敗、再接続を予定: $e');
      // ソケットが死んでいる可能性が高い。閉じて非同期で再接続。
      _closeSocket().then((_) {
        // _hubIp などはまだ残っているので reconnectWithBackoff で再生成可能
        if (_hubIp != null) {
          unawaited(reconnectWithBackoff());
        }
      });
    }
  }
}
