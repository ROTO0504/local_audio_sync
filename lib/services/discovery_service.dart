import 'dart:async';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';

const int kDiscoveryPort = 9999;
const int kAudioPort = 7777;
const String _kBeaconPrefix = 'LAHUB:';

class DiscoveredHub {
  final String ip;
  final int port;
  final String name;

  const DiscoveredHub({required this.ip, required this.port, required this.name});

  /// Parse 'LAHUB:{ip}:{port}:{name}' beacon string.
  static DiscoveredHub? fromBeacon(String beacon) {
    if (!beacon.startsWith(_kBeaconPrefix)) return null;
    final parts = beacon.substring(_kBeaconPrefix.length).split(':');
    if (parts.length < 3) return null;
    final port = int.tryParse(parts[1]);
    if (port == null) return null;
    return DiscoveredHub(
      ip: parts[0],
      port: port,
      name: parts.sublist(2).join(':'),
    );
  }

  String toBeacon(String localName) => '$_kBeaconPrefix$ip:$port:$localName';
}

/// Hub side: broadcasts a beacon every [intervalSeconds] seconds.
class HubBeaconSender {
  Timer? _timer;
  RawDatagramSocket? _socket;

  Future<void> start(String hubName) async {
    final localIp = await _getLocalIp();
    final beaconStr = '$_kBeaconPrefix$localIp:$kAudioPort:$hubName';
    final beaconBytes = beaconStr.codeUnits;

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;

    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _socket?.send(
        beaconBytes,
        InternetAddress('255.255.255.255'),
        kDiscoveryPort,
      );
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}

/// Client side: listens for Hub beacons and emits [DiscoveredHub] events.
class ClientDiscoveryListener {
  final StreamController<DiscoveredHub> _controller =
      StreamController<DiscoveredHub>.broadcast();
  RawDatagramSocket? _socket;

  Stream<DiscoveredHub> get stream => _controller.stream;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
      reusePort: false,
    );

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg == null) return;
        final text = String.fromCharCodes(dg.data);
        final hub = DiscoveredHub.fromBeacon(text);
        if (hub != null) {
          _controller.add(hub);
        }
      }
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
    _controller.close();
  }
}

Future<String> _getLocalIp() async {
  try {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    if (ip != null && ip.isNotEmpty) return ip;
  } catch (_) {}
  // Fallback: enumerate network interfaces
  for (final iface in await NetworkInterface.list()) {
    for (final addr in iface.addresses) {
      if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
        return addr.address;
      }
    }
  }
  return '127.0.0.1';
}
