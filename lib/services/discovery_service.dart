import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';
import '../models/control_messages.dart';

const int kDiscoveryPort = 9999;
const int kAudioPort = 7777;
const String _kBeaconPrefix = 'LAHUB:';
const String _kBeaconV2Prefix = 'LAHUB2:';

/// 発見された Hub(ビーコン / mDNS / 手動入力のいずれか由来)。
class DiscoveredHub {
  final String ip;
  final int port;
  final String name;

  /// Hub の永続 ID(プロトコル v2 のみ)。v1 ビーコン由来では null。
  /// 「前回接続した Hub への優先接続」の判定に使う。
  final String? hubId;

  /// Hub の話すプロトコルバージョン(v1 ビーコン由来では 1)。
  final int protocolVersion;

  const DiscoveredHub({
    required this.ip,
    required this.port,
    required this.name,
    this.hubId,
    this.protocolVersion = kProtocolVersionLegacy,
  });

  /// `LAHUB:{ip}:{port}:{name}`(v1)または
  /// `LAHUB2:{ip}:{port}:{name}:{hubId}:{proto}`(v2)をパース。失敗時 null。
  static DiscoveredHub? fromBeacon(String beacon) {
    if (beacon.startsWith(_kBeaconV2Prefix)) {
      final parts = beacon.substring(_kBeaconV2Prefix.length).split(':');
      if (parts.length < 5) return null;
      final port = int.tryParse(parts[1]);
      final proto = int.tryParse(parts.last);
      if (port == null || proto == null) return null;
      final hubId = parts[parts.length - 2];
      return DiscoveredHub(
        ip: parts[0],
        port: port,
        // name にコロンが含まれても壊れないよう、末尾 2 要素以外を結合
        name: parts.sublist(2, parts.length - 2).join(':'),
        hubId: hubId,
        protocolVersion: proto,
      );
    }
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

  /// v1 ビーコンと v2 ビーコンが交互に届いても「同じ Hub」として dedup できる
  /// よう、equality には hubId / protocolVersion を含めない(ip/port/name で
  /// 同一性を判定し、hubId は emit 時の参考情報として扱う)。
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
  String toString() =>
      'DiscoveredHub(ip=$ip, port=$port, name=$name, hubId=$hubId, proto=$protocolVersion)';
}

/// Hub 側: ビーコンを 2 秒ごとにブロードキャスト送信する。
///
/// プロトコル v2 では `LAHUB2:{ip}:{port}:{name}:{hubId}:{proto}` を送り、
/// 旧クライアント互換のため v1 形式 `LAHUB:{ip}:{port}:{name}` も同じ
/// ティックで併送する(v2 を先に送るので、新クライアントは通常 v2 を先に拾う)。
class HubBeaconSender {
  Timer? _timer;
  RawDatagramSocket? _socket;

  Future<void> start(String hubName, {String? hubId}) async {
    final localIp = await getLocalIpv4();
    final beaconV1 =
        utf8.encode('$_kBeaconPrefix$localIp:$kAudioPort:$hubName');
    final beaconV2 = hubId == null
        ? null
        : utf8.encode(
            '$_kBeaconV2Prefix$localIp:$kAudioPort:$hubName:$hubId:$kProtocolVersion');

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;

    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final target = InternetAddress('255.255.255.255');
      if (beaconV2 != null) {
        _socket?.send(beaconV2, target, kDiscoveryPort);
      }
      _socket?.send(beaconV1, target, kDiscoveryPort);
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

  /// 複数 Hub を同時に扱うための「集合 API」。dedup せず、受信したビーコンを
  /// 逐次流す。購読側(discoveredHubsProvider)が最終受信時刻を管理して
  /// 一覧の追加・除去を行う。旧来の [stream] は「接続先候補 1 件」向けの
  /// dedup 付きストリームとして従来どおり残す。
  final StreamController<DiscoveredHub> _allHubsController =
      StreamController<DiscoveredHub>.broadcast();

  RawDatagramSocket? _socket;
  StreamSubscription? _socketSub;
  Timer? _watchdog;

  DiscoveredHub? _lastEmitted;
  DateTime _lastBeaconAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lostNotified = true; // 開始時はまだ Hub を見つけていない

  /// Hub ごと(キー `hubId ?? 'ip:port'`)の最終受信時刻。
  final Map<String, DateTime> _lastSeenByKey = {};

  ClientDiscoveryListener({
    this.withinDedup = const Duration(seconds: 5),
    this.lossTimeout = const Duration(seconds: 6),
  });

  Stream<DiscoveredHub> get stream => _hubController.stream;

  /// Hub 喪失イベント(タイムアウト時に発火)。
  Stream<void> get hubLostStream => _lostController.stream;

  /// 受信した全ビーコンを dedup せずに流す集合ストリーム。複数 Hub を
  /// 同時に一覧へ載せるために使う(接続用の [stream] とは別系統)。
  Stream<DiscoveredHub> get allHubsStream => _allHubsController.stream;

  /// Hub のキー(`hubId ?? 'ip:port'`)。集合 API の同一性判定に使う。
  static String keyOf(DiscoveredHub hub) =>
      hub.hubId ?? '${hub.ip}:${hub.port}';

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
        final text = utf8.decode(dg.data, allowMalformed: true);
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

    // 集合 API: dedup せず毎ビーコンを流し、最終受信時刻も更新する。
    _lastSeenByKey[keyOf(hub)] = now;
    if (!_allHubsController.isClosed) {
      _allHubsController.add(hub);
    }

    // 以下は従来の「接続先候補 1 件」向け dedup 付き stream(挙動は不変)。
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

  /// 集合 API 用: [maxAge] より古い最終受信のキーを一覧から落とし、
  /// 残っているキーの集合を返す(discoveredHubsProvider 側の pruning 補助)。
  Set<String> pruneStaleKeys(Duration maxAge) {
    final now = DateTime.now();
    _lastSeenByKey.removeWhere((_, seen) => now.difference(seen) > maxAge);
    return _lastSeenByKey.keys.toSet();
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
    _lastSeenByKey.clear();
  }

  /// 監視を継続したまま、内部状態のみリセットする(再接続後の二重通知抑止解除等)。
  void resetState() {
    _lastEmitted = null;
    _lostNotified = true;
    _lastBeaconAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSeenByKey.clear();
  }

  void dispose() {
    stop();
    _hubController.close();
    _lostController.close();
    _allHubsController.close();
  }
}

/// Discovery 開始時の例外。
class DiscoveryStartException implements Exception {
  final String message;
  const DiscoveryStartException(this.message);
  @override
  String toString() => 'DiscoveryStartException: $message';
}

/// この端末の LAN 向け IPv4 アドレスを返す(見つからなければ 127.0.0.1)。
/// ビーコンの自 IP 通知と、Hub 画面での手動接続案内表示に使う。
///
/// マルチホーム(有線/Wi-Fi + Tailscale などの VPN)環境では、単純に
/// `NetworkInterface.list()` の先頭を採ると Tailscale の CGNAT アドレス
/// (100.64.0.0/10)を掴んでしまい、同一 LAN のクライアントから到達不能な
/// IP をビーコンに載せてしまう。そのため RFC1918 の LAN アドレスを優先し、
/// VPN/仮想インターフェースと CGNAT を避けるようスコアリングして選ぶ。
Future<String> getLocalIpv4() async {
  // モバイル(Wi-Fi で Hub になるケース)では getWifiIP() が最も確実。
  // ただし VPN/CGNAT を返すことがあるので、妥当な LAN アドレスのときだけ採る。
  try {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    if (ip != null && ip.isNotEmpty && !_isCgnatIpv4(ip)) return ip;
  } catch (_) {}

  String? best;
  var bestScore = -1 << 30;
  for (final iface in await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  )) {
    for (final addr in iface.addresses) {
      if (addr.isLoopback || addr.isLinkLocal) continue;
      final score = _scoreLanIpv4(iface.name, addr.address);
      if (score > bestScore) {
        bestScore = score;
        best = addr.address;
      }
    }
  }
  return best ?? '127.0.0.1';
}

/// Tailscale などが使う CGNAT 共有アドレス空間(100.64.0.0/10)か。
bool _isCgnatIpv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

/// LAN ビーコンに載せる自 IP として好ましいほど高いスコアを返す。
/// 家庭内 LAN(RFC1918)を優先し、VPN/仮想 IF と CGNAT を避ける。
int _scoreLanIpv4(String ifaceName, String ip) {
  var score = 0;
  final name = ifaceName.toLowerCase();
  const virtualHints = [
    'tailscale', 'vethernet', 'vpn', 'wireguard', 'wg', 'zerotier',
    'utun', 'hyper-v', 'virtual', 'vmware', 'vbox',
  ];
  if (virtualHints.any(name.contains)) score -= 1000;
  if (_isCgnatIpv4(ip)) score -= 500;
  if (ip.startsWith('192.168.')) {
    score += 30;
  } else if (ip.startsWith('10.')) {
    score += 20;
  } else {
    // 172.16.0.0/12
    final parts = ip.split('.');
    final a = int.tryParse(parts.isNotEmpty ? parts[0] : '');
    final b = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (a == 172 && b != null && b >= 16 && b <= 31) score += 20;
  }
  return score;
}
