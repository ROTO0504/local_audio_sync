import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../models/control_messages.dart';
import 'discovery_service.dart';

/// mDNS(Bonjour / NSD)のサービスタイプ。
///
/// RFC 6335 によりサービスタイプ名は 15 文字以内なので、
/// `local-audio-sync`(16 文字)ではなく短縮名 `lasync` を使う。
/// iOS の Info.plist(NSBonjourServices)にも同じ値を宣言すること。
const String kMdnsServiceType = '_lasync._udp';

/// Hub 側: mDNS(Bonjour)でサービスを公開する。
///
/// iOS は UDP ブロードキャストの送信に multicast entitlement(Apple 申請制)が
/// 必要でビーコンを送れないため、iOS Hub にとってはこれが唯一の被発見手段。
/// 他 OS では UDP ビーコン(HubBeaconSender)との併用になる。
/// mDNS が使えない環境でも例外は握りつぶし、ビーコンのみで継続する。
class HubMdnsAdvertiser {
  BonsoirBroadcast? _broadcast;

  bool get isAdvertising => _broadcast != null;

  Future<void> start({
    required String hubName,
    required String hubId,
    int port = kAudioPort,
  }) async {
    if (_broadcast != null) return;
    try {
      final service = BonsoirService(
        name: 'LAS $hubName',
        type: kMdnsServiceType,
        port: port,
        attributes: {
          'name': hubName,
          'hubId': hubId,
          'proto': '$kProtocolVersion',
        },
      );
      final broadcast = BonsoirBroadcast(service: service);
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (e) {
      debugPrint('[HubMdnsAdvertiser] mDNS 公開に失敗(ビーコンのみで継続): $e');
      _broadcast = null;
    }
  }

  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null) {
      try {
        await broadcast.stop();
      } catch (_) {}
    }
  }
}

/// クライアント側: mDNS で Hub をブラウズし、[DiscoveredHub] を流す。
///
/// UDP ビーコン(ClientDiscoveryListener)と並走させ、どちらで見つかっても
/// 同じ [DiscoveredHub] として上位へ届ける(重複は上位の接続ガードで無害)。
class ClientMdnsBrowser {
  BonsoirDiscovery? _discovery;
  StreamSubscription? _eventSub;
  final StreamController<DiscoveredHub> _controller =
      StreamController<DiscoveredHub>.broadcast();

  Stream<DiscoveredHub> get stream => _controller.stream;

  bool get isBrowsing => _discovery != null;

  Future<void> start() async {
    if (_discovery != null) return;
    try {
      final discovery = BonsoirDiscovery(type: kMdnsServiceType);
      await discovery.initialize();
      _eventSub = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            // 発見しただけでは host/port が未解決なので resolve を要求する
            service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent(:final service):
          case BonsoirDiscoveryServiceUpdatedEvent(:final service):
            final hub = _toDiscoveredHub(service);
            if (hub != null && !_controller.isClosed) {
              _controller.add(hub);
            }
          default:
            break;
        }
      });
      await discovery.start();
      _discovery = discovery;
    } catch (e) {
      debugPrint('[ClientMdnsBrowser] mDNS 探索を開始できません(ビーコンのみで継続): $e');
      await stop();
    }
  }

  DiscoveredHub? _toDiscoveredHub(BonsoirService service) {
    // IPv4 アドレスを優先して選ぶ(音声経路は IPv4 前提)
    String? ip;
    for (final address in service.hostAddresses) {
      if (!address.contains(':')) {
        ip = address;
        break;
      }
    }
    if (ip == null || ip.isEmpty) return null;

    final attributes = service.attributes;
    return DiscoveredHub(
      ip: ip,
      port: service.port,
      name: attributes['name'] ?? service.name,
      hubId: attributes['hubId'],
      protocolVersion:
          int.tryParse(attributes['proto'] ?? '') ?? kProtocolVersionLegacy,
    );
  }

  Future<void> stop() async {
    await _eventSub?.cancel();
    _eventSub = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      try {
        await discovery.stop();
      } catch (_) {}
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
