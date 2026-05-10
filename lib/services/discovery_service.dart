import 'dart:async';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';

const int kDiscoveryPort = 9999;
const int kAudioPort = 7777;
const String _kBeaconPrefix = 'LAHUB:';

/// Hub のビーコン文字列をパースした結果。
class DiscoveredHub {
  final String ip;
  final int port;
  final String name;

  const DiscoveredHub({required this.ip, required this.port, required this.name});

  /// `LAHUB:{ip}:{port}:{name}` 形式のビーコンをパース。失敗時 null。
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredHub &&
          ip == other.ip &&
          port == other.port &&
          name == other.name;

  @override
  int get hashCode => Object.hash(ip, port, name);

  @override
  String toString() => 'DiscoveredHub(ip=$ip, port=$port, name=$name)';
}

/// Hub 側: ビーコンを `intervalSeconds` 秒ごとにブロードキャスト送信する。
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

/// クライアント側: Hub のビーコンを listen し、検出と喪失をストリームで通知する。
///
/// 旧実装はビーコン受信のみで、Hub が落ちたあとも UDP 送信を続けてしまっていた。
/// 本実装では:
///
/// - 直近のビーコン受信時刻を記録
/// - `lossTimeout` 期間ビーコンが届かなければ「Hub 喪失」とみなす
/// - 喪失時は [hubLostStream] にイベントを流し、上位レイヤで再探索状態へ戻せる
///
/// `hubStream` には新規発見と、IP/port/name が変わって再発見した場合に流す。
/// 同じ Hub の連続ビーコンを毎秒流して使う側を圧迫しないよう、[withinDedup] 期間
/// 同一値ならば抑止する。
class ClientDiscoveryListener {
  /// 同一 Hub のイベント抑止期間。
  final Duration withinDedup;

  /// このタイムアウトの間ビーコンが来なければ「Hub 喪失」を発行する。
  final Duration lossTimeout;

  final StreamController<DiscoveredHub> _hubController =
      StreamController<DiscoveredHub>.broadcast();
  final StreamController<void> _lostController =
      StreamController<void>.broadcast();

  RawDatagramSocket? _socket;
  StreamSubscription? _socketSub;
  Timer? _watchdog;

  DiscoveredHub? _lastEmitted;
  DateTime _lastBeaconAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lostNotified = true; // 開始時はまだ Hub を見つけていない

  ClientDiscoveryListener({
    this.withinDedup = const Duration(seconds: 5),
    this.lossTimeout = const Duration(seconds: 6),
  });

  Stream<DiscoveredHub> get stream => _hubController.stream;

  /// Hub 喪失イベント(タイムアウト時に発火)。
  Stream<void> get hubLostStream => _lostController.stream;

  /// 直近のビーコン受信時刻。テスト用。
  DateTime get lastBeaconAt => _lastBeaconAt;

  Future<void> start() async {
    if (_socket != null) return;

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
    } catch (e) {
      _hubController.addError(
        DiscoveryStartException(
          'ビーコン受信ソケットの bind に失敗: $e',
        ),
      );
      return;
    }

    _socketSub = _socket!.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final dg = _socket!.receive();
        if (dg == null) return;
        final text = String.fromCharCodes(dg.data);
        final hub = DiscoveredHub.fromBeacon(text);
        if (hub != null) {
          _onBeacon(hub);
        }
      },
      onError: (Object err) {
        _hubController.addError(err);
      },
      cancelOnError: false,
    );

    // Hub 喪失監視の watchdog を 1 秒ごとに回す
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkLoss());
  }

  void _onBeacon(DiscoveredHub hub) {
    final now = DateTime.now();
    _lastBeaconAt = now;
    if (_lostNotified) {
      _lostNotified = false;
    }
    // 同一 Hub の連続ビーコンは抑止
    if (_lastEmitted != null &&
        _lastEmitted == hub &&
        now.difference(_lastBeaconAt).abs() < withinDedup) {
      // すでに発見済みで dedup 期間内 → emit しない
      return;
    }
    if (_lastEmitted != hub) {
      _lastEmitted = hub;
      _hubController.add(hub);
    }
  }

  void _checkLoss() {
    if (_socket == null) return;
    if (_lostNotified) return; // 既に喪失通知済み
    if (_lastEmitted == null) return; // まだ見つけていないだけ

    final since = DateTime.now().difference(_lastBeaconAt);
    if (since > lossTimeout) {
      _lostNotified = true;
      _lastEmitted = null;
      _lostController.add(null);
    }
  }

  void stop() {
    _watchdog?.cancel();
    _watchdog = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _lastEmitted = null;
    _lostNotified = true;
  }

  /// 監視を継続したまま、内部状態のみリセットする(再接続後の二重通知抑止解除等)。
  void resetState() {
    _lastEmitted = null;
    _lostNotified = true;
    _lastBeaconAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void dispose() {
    stop();
    _hubController.close();
    _lostController.close();
  }
}

/// Discovery 開始時の例外。
class DiscoveryStartException implements Exception {
  final String message;
  const DiscoveryStartException(this.message);
  @override
  String toString() => 'DiscoveryStartException: $message';
}

Future<String> _getLocalIp() async {
  try {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    if (ip != null && ip.isNotEmpty) return ip;
  } catch (_) {}
  for (final iface in await NetworkInterface.list()) {
    for (final addr in iface.addresses) {
      if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
        return addr.address;
      }
    }
  }
  return '127.0.0.1';
}
