import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/audio_packet.dart';

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
class UdpSenderService {
  RawDatagramSocket? _socket;
  StreamSubscription? _socketSub;

  String? _hubIp;
  int _hubPort = 7777;
  String? _deviceName;
  String? _uuid;

  int _clientId = 0;
  int _sequence = 0;
  Timer? _pingTimer;

  /// 再接続用の指数バックオフ次回間隔(ms)。
  int _retryDelayMs = 200;
  static const int _retryDelayMaxMs = 5000;

  /// 接続失敗回数(統計用)。
  int _consecutiveFailures = 0;
  int get consecutiveFailures => _consecutiveFailures;

  bool get isConnected => _socket != null && _hubIp != null && _clientId != 0;
  String? get hubIp => _hubIp;
  int get clientId => _clientId;

  /// Hub への接続を確立する。HELLO を投げて ACKHELLO で clientId を受け取る。
  Future<void> connect(
    String hubIp,
    int hubPort,
    String deviceName,
    String uuid,
  ) async {
    _hubIp = hubIp;
    _hubPort = hubPort;
    _deviceName = deviceName;
    _uuid = uuid;
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
        final dg = sock.receive();
        if (dg == null) return;
        final text = String.fromCharCodes(dg.data);
        if (text.startsWith('ACKHELLO:')) {
          final parts = text.split(':');
          if (parts.length >= 2) {
            _clientId = int.tryParse(parts[1]) ?? 0;
            if (!completer.isCompleted) completer.complete();
          }
        } else if (text.startsWith('RESYNC:')) {
          // Hub から「seq を 0 に戻して送り直せ」と要求された
          final id = int.tryParse(text.substring(7));
          if (id == null || id == _clientId) {
            debugPrint('[UdpSender] RESYNC 受信、sequence をリセット');
            _sequence = 0;
          }
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

    // HELLO 送信
    _sendText('HELLO:$_deviceName:$_uuid');

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
    _retryDelayMs = 200;
  }

  // ---- 内部 ----

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendText('PING:$_clientId');
    });
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
