import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../models/audio_packet.dart';

class UdpSenderService {
  RawDatagramSocket? _socket;
  String? _hubIp;
  int _hubPort = 7777;
  int _clientId = 0;
  int _sequence = 0;
  Timer? _pingTimer;

  bool get isConnected => _socket != null && _hubIp != null;

  /// Open socket and connect to hub. Returns assigned clientId on success.
  Future<void> connect(String hubIp, int hubPort, String deviceName, String uuid) async {
    _hubIp = hubIp;
    _hubPort = hubPort;
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    // Send HELLO
    _sendText('HELLO:$deviceName:$uuid');

    // Listen for ACKHELLO
    final completer = Completer<void>();
    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg == null) return;
        final text = String.fromCharCodes(dg.data);
        if (text.startsWith('ACKHELLO:')) {
          final parts = text.split(':');
          if (parts.length >= 2) {
            _clientId = int.tryParse(parts[1]) ?? 0;
            if (!completer.isCompleted) completer.complete();
          }
        }
      }
    });

    await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Hub did not respond to HELLO'),
    );

    // Start keepalive pings
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendText('PING:$_clientId');
    });
  }

  /// Send an encoded Opus frame to the Hub.
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

  void disconnect() {
    _sendText('BYE:$_clientId');
    _pingTimer?.cancel();
    _pingTimer = null;
    _socket?.close();
    _socket = null;
    _hubIp = null;
    _sequence = 0;
    _clientId = 0;
  }

  void _sendText(String text) {
    _sendBytes(Uint8List.fromList(text.codeUnits));
  }

  void _sendBytes(Uint8List data) {
    if (_socket == null || _hubIp == null) return;
    _socket!.send(data, InternetAddress(_hubIp!), _hubPort);
  }
}
