import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/audio_packet.dart';
import '../models/control_messages.dart';
import 'command_retry_queue.dart';

typedef OnAudioPacket = void Function(AudioPacket packet, String sourceIp);
typedef OnClientHello = void Function(
    ClientHello hello, String sourceIp, int sourcePort);
typedef OnClientPing = void Function(int clientId);
typedef OnClientBye = void Function(int clientId);
typedef OnCommandFailed = void Function(RemoteCommand command);

/// Hub 側 UDP 受信サービス。
///
/// 旧実装は socket が一度死ぬと回復不能だった。本実装ではソケットエラー時に
/// 自動的に bind し直す(指数バックオフ)ようにする。
///
/// プロトコル v2 で以下を追加:
///   - HELLO2(platform / protocolVersion 付き)の受理。旧 HELLO も引き続き受理
///   - PING への PONG 自動応答(クライアント側の Hub 生存確認用)
///   - CMD 送信(リモート制御)+ CMDACK 受信までの自動再送
class UdpReceiverService {
  UdpReceiverService({int port = kAudioPort}) : _port = port {
    _commandQueue = CommandRetryQueue(
      send: (command, ip, port) => _sendText(command.encode(), ip, port),
    );
    _commandQueue.onGiveUp = (command) => onCommandFailed?.call(command);
  }

  final int _port;
  RawDatagramSocket? _socket;
  StreamSubscription? _sub;
  bool _running = false;
  int _retryDelayMs = 200;
  static const int _retryDelayMaxMs = 5000;

  late final CommandRetryQueue _commandQueue;

  OnAudioPacket? onAudioPacket;
  OnClientHello? onClientHello;
  OnClientPing? onClientPing;
  OnClientBye? onClientBye;

  /// CMD を最大回数再送しても CMDACK が返らなかったときに呼ばれる。
  OnCommandFailed? onCommandFailed;

  /// ACKHELLO を該当クライアントへ返す。
  void sendAckHello(String ip, int port, int assignedId) {
    _sendText('ACKHELLO:$assignedId', ip, port);
  }

  /// JitterBuffer がシーケンス断絶を検出したときに、送信側へ seq リセット要求を送る。
  /// 受信した側は内部の sequence を 0 に戻し、新しい seq から再送信する。
  void sendResync(String ip, int port, int clientId) {
    _sendText('RESYNC:$clientId', ip, port);
  }

  /// リモート制御コマンドを送る。CMDACK が返るまで自動再送される。
  /// 発番した commandSeq を返す。
  int sendCommand(
    int clientId,
    RemoteCommandAction action,
    String ip,
    int port,
  ) {
    return _commandQueue.enqueue(clientId, action, ip, port);
  }

  /// 受信開始。失敗時は再 bind を試みる。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _bindLoop();
  }

  Future<void> _bindLoop() async {
    while (_running) {
      try {
        _socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _port,
          reuseAddress: true,
        );
        _retryDelayMs = 200;

        _sub = _socket!.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            // 1 回の read イベントに複数のデータグラムが溜まっていることが
            // あるため、null が返るまでドレインする。
            while (true) {
              try {
                final dg = _socket?.receive();
                if (dg == null) break;
                _dispatch(dg.data, dg.address.address, dg.port);
              } catch (e) {
                debugPrint('[UdpReceiver] receive 例外: $e');
                break;
              }
            }
          },
          onError: (Object err) {
            debugPrint('[UdpReceiver] socket error: $err');
            _scheduleRebind();
          },
          onDone: () {
            debugPrint('[UdpReceiver] socket closed unexpectedly');
            _scheduleRebind();
          },
          cancelOnError: false,
        );
        return;
      } catch (e) {
        debugPrint('[UdpReceiver] bind 失敗、リトライします: $e');
        await Future<void>.delayed(Duration(milliseconds: _retryDelayMs));
        _retryDelayMs = (_retryDelayMs * 2).clamp(0, _retryDelayMaxMs);
      }
    }
  }

  void _scheduleRebind() {
    if (!_running) return;
    _closeSocket();
    // 同期的に rebind するとループしやすいので非同期で
    Future<void>.microtask(_bindLoop);
  }

  void _dispatch(Uint8List data, String ip, int port) {
    // テキスト先頭が ASCII 範囲内のときだけテキスト解釈を試す。
    if (data.length > 5 && data[0] < 128) {
      final text = String.fromCharCodes(data);
      final hello = ClientHello.parse(text);
      if (hello != null) {
        onClientHello?.call(hello, ip, port);
        return;
      }
      if (text.startsWith('PING:')) {
        final id = int.tryParse(text.substring(5));
        if (id != null) {
          // v2: クライアントがソケットレベルで Hub の生存を確認できるよう
          // PONG を返す(v1 クライアントは PONG を無視するだけ)。
          _sendText(encodePong(id), ip, port);
          onClientPing?.call(id);
        }
        return;
      }
      if (text.startsWith('BYE:')) {
        final id = int.tryParse(text.substring(4));
        if (id != null) onClientBye?.call(id);
        return;
      }
      final ack = CommandAck.parse(text);
      if (ack != null) {
        _commandQueue.handleAck(ack.commandSeq);
        return;
      }
    }

    // バイナリ音声パケット
    final packet = AudioPacket.fromBytes(data);
    if (packet != null) {
      onAudioPacket?.call(packet, ip);
    }
  }

  void _sendText(String text, String ip, int port) {
    try {
      _socket?.send(
        Uint8List.fromList(text.codeUnits),
        InternetAddress(ip),
        port,
      );
    } catch (e) {
      debugPrint('[UdpReceiver] 送信失敗 ($text): $e');
    }
  }

  void _closeSocket() {
    _sub?.cancel();
    _sub = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void stop() {
    _running = false;
    _commandQueue.dispose();
    _closeSocket();
  }
}

const int kAudioPort = 7777;
