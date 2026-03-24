import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../models/audio_packet.dart';

typedef OnAudioPacket = void Function(AudioPacket packet, String sourceIp);
typedef OnClientHello = void Function(String name, String uuid, String sourceIp, int sourcePort);
typedef OnClientPing = void Function(int clientId);
typedef OnClientBye = void Function(int clientId);

class UdpReceiverService {
  RawDatagramSocket? _socket;
  StreamSubscription? _sub;

  OnAudioPacket? onAudioPacket;
  OnClientHello? onClientHello;
  OnClientPing? onClientPing;
  OnClientBye? onClientBye;

  /// Send ACKHELLO back to a client with their assigned ID.
  void sendAckHello(String ip, int port, int assignedId) {
    final msg = 'ACKHELLO:$assignedId';
    _socket?.send(
      Uint8List.fromList(msg.codeUnits),
      InternetAddress(ip),
      port,
    );
  }

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kAudioPort,
      reuseAddress: true,
    );

    _sub = _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      _dispatch(dg.data, dg.address.address, dg.port);
    });
  }

  void _dispatch(Uint8List data, String ip, int port) {
    // Try text messages first
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

    // Binary audio packet
    final packet = AudioPacket.fromBytes(data);
    if (packet != null) {
      onAudioPacket?.call(packet, ip);
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }
}

const int kAudioPort = 7777;
