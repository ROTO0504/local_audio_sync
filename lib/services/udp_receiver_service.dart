import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/audio_packet.dart';

typedef OnAudioPacket = void Function(AudioPacket packet, String sourceIp);
typedef OnClientHello = void Function(
    String name, String uuid, String sourceIp, int sourcePort);
typedef OnClientPing = void Function(int clientId);
typedef OnClientBye = void Function(int clientId);

/// Hub 側 UDP 受信サービス。
///
/// 旧実装は socket が一度死ぬと回復不能だった。本実装ではソケットエラー時に
/// 自動的に bind し直す(指数バックオフ)ようにする。
class UdpReceiverService {
  RawDatagramSocket? _socket;
  StreamSubscription? _sub;
  bool _running = false;
  int _retryDelayMs = 200;
  static const int _retryDelayMaxMs = 5000;

  OnAudioPacket? onAudioPacket;
  OnClientHello? onClientHello;
  OnClientPing? onClientPing;
  OnClientBye? onClientBye;

  /// ACKHELLO を該当クライアントへ返す。
  void sendAckHello(String ip, int port, int assignedId) {
    final msg = 'ACKHELLO:$assignedId';
    try {
      _socket?.send(
        Uint8List.fromList(msg.codeUnits),
        InternetAddress(ip),
        port,
      );
    } catch (e) {
      debugPrint('[UdpReceiver] ACKHELLO 送信失敗: $e');
    }
  }

  /// JitterBuffer がシーケンス断絶を検出したときに、送信側へ seq リセット要求を送る。
  /// 受信した側は内部の sequence を 0 に戻し、新しい seq から再送信する。
  void sendResync(String ip, int port, int clientId) {
    final msg = 'RESYNC:$clientId';
    try {
      _socket?.send(
        Uint8List.fromList(msg.codeUnits),
        InternetAddress(ip),
        port,
      );
    } catch (e) {
      debugPrint('[UdpReceiver] RESYNC 送信失敗: $e');
    }
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
          kAudioPort,
          reuseAddress: true,
        );
        _retryDelayMs = 200;

        _sub = _socket!.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            try {
              final dg = _socket!.receive();
              if (dg == null) return;
              _dispatch(dg.data, dg.address.address, dg.port);
            } catch (e) {
              debugPrint('[UdpReceiver] receive 例外: $e');
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
      if (text.startsWith('HELLO:')) {
        final parts = text.split(':');
        if (parts.length >= 3) {
          onClientHello?.call(parts[1], parts[2], ip, port);
          return;
        }
      } else if (text.startsWith('PING:')) {
        final id = int.tryParse(text.substring(5));
        if (id != null) onClientPing?.call(id);
        return;
      } else if (text.startsWith('BYE:')) {
        final id = int.tryParse(text.substring(4));
        if (id != null) onClientBye?.call(id);
        return;
      }
    }

    // バイナリ音声パケット
    final packet = AudioPacket.fromBytes(data);
    if (packet != null) {
      onAudioPacket?.call(packet, ip);
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
    _closeSocket();
  }
}

const int kAudioPort = 7777;
