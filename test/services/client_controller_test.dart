import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/providers/client_state_provider.dart';
import 'package:local_audio_sync/providers/discovered_hubs_provider.dart';
import 'package:local_audio_sync/services/client_controller.dart';
import 'package:local_audio_sync/services/device_identity_service.dart';
import 'package:local_audio_sync/services/discovery_service.dart';
import 'package:local_audio_sync/services/mdns_discovery_service.dart';
import 'package:local_audio_sync/services/opus_encoder_service.dart';
import 'package:local_audio_sync/services/screen_audio_capture_service.dart';
import 'package:local_audio_sync/services/udp_sender_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UDP を張らないフェイク探索リスナ。テストからビーコン受信・喪失を叩ける。
class _FakeDiscovery extends ClientDiscoveryListener {
  final _hub = StreamController<DiscoveredHub>.broadcast();
  final _all = StreamController<DiscoveredHub>.broadcast();
  final _lost = StreamController<void>.broadcast();
  bool started = false;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Stream<DiscoveredHub> get stream => _hub.stream;
  @override
  Stream<DiscoveredHub> get allHubsStream => _all.stream;
  @override
  Stream<void> get hubLostStream => _lost.stream;

  @override
  void stop() {}

  @override
  void dispose() {
    _hub.close();
    _all.close();
    _lost.close();
  }

  void emit(DiscoveredHub hub) {
    _hub.add(hub);
    _all.add(hub);
  }

  void emitLost() => _lost.add(null);
}

/// mDNS を触らないフェイクブラウザ。
class _FakeMdns extends ClientMdnsBrowser {
  final _ctrl = StreamController<DiscoveredHub>.broadcast();

  @override
  Future<void> start() async {}
  @override
  Stream<DiscoveredHub> get stream => _ctrl.stream;
  @override
  Future<void> stop() async {}
  @override
  void dispose() {
    _ctrl.close();
  }
}

/// ソケットを張らないフェイク送信サービス。connect で即「接続済み」になる。
class _FakeSender extends UdpSenderService {
  bool _connected = false;
  bool shouldFail = false;
  int connectCalls = 0;
  final List<Uint8List> sent = [];

  @override
  Future<void> connect(
    String hubIp,
    int hubPort,
    String deviceName,
    String uuid, {
    String? platform,
  }) async {
    connectCalls++;
    if (shouldFail) {
      throw TimeoutException('接続失敗(テスト)');
    }
    _connected = true;
  }

  @override
  bool get isConnected => _connected;

  @override
  void sendAudio(Uint8List opusBytes) => sent.add(opusBytes);

  @override
  void disconnect() {
    _connected = false;
  }
}

/// FFI を触らないフェイクエンコーダ。
class _FakeEncoder extends OpusEncoderService {
  @override
  void init() {}
  @override
  Uint8List? encode(Uint8List pcm16Bytes) => null;
  @override
  void dispose() {}
}

/// MethodChannel を触らないフェイクキャプチャ。
class _FakeCapture extends ScreenAudioCaptureService {
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<bool> isBroadcastingActive() async => false;
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _FakeDiscovery discovery;
  late _FakeMdns mdns;
  late _FakeSender sender;
  late ClientController controller;

  ClientController build() {
    discovery = _FakeDiscovery();
    mdns = _FakeMdns();
    sender = _FakeSender();
    final provider = Provider<ClientController>((ref) => ClientController(
          ref,
          discovery: discovery,
          mdnsBrowser: mdns,
          sender: sender,
          capture: _FakeCapture(),
          encoder: _FakeEncoder(),
          isIOSOverride: false,
          isAndroidOverride: false,
        ));
    return container.read(provider);
  }

  setUp(() {
    DeviceIdentityService.resetCache();
  });

  tearDown(() async {
    await controller.stop();
    container.dispose();
  });

  const hubA = DiscoveredHub(
    ip: '192.168.1.20',
    port: 7777,
    name: 'Hub A',
    hubId: 'hub-a',
    protocolVersion: 2,
  );

  group('ClientController 探索と接続', () {
    test('start で探索が始まり searching になる', () async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      controller = build();

      await controller.start();
      await pumpEventQueue();

      expect(discovery.started, isTrue);
      expect(
        container.read(clientStateProvider).status,
        ClientConnectionStatus.searching,
      );
    });

    test('発見しても前回 Hub と一致しなければ自動接続せず一覧に載せる', () async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      controller = build();
      await controller.start();
      await pumpEventQueue();

      discovery.emit(hubA);
      await pumpEventQueue();

      // 自動接続はしない(first-wins 撤廃)
      expect(sender.connectCalls, 0);
      expect(
        container.read(clientStateProvider).status,
        ClientConnectionStatus.searching,
      );
      // 発見集合には載る
      expect(container.read(discoveredHubsProvider), contains('hub-a'));
    });

    test('ピッカー選択(connectTo)で ACKHELLO 相当を経て connected になる', () async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      controller = build();
      await controller.start();
      await pumpEventQueue();

      await controller.connectTo(hubA);
      await pumpEventQueue();

      expect(sender.connectCalls, 1);
      expect(sender.isConnected, isTrue);
      final state = container.read(clientStateProvider);
      expect(state.status, ClientConnectionStatus.connected);
      expect(state.connectedHubId, 'hub-a');
      expect(state.isManualMode, isFalse);
    });

    test('前回接続 hubId と一致する Hub は自動接続する', () async {
      SharedPreferences.setMockInitialValues({
        'last_connected_hub': jsonEncode({
          'ip': '192.168.1.20',
          'port': 7777,
          'name': 'Hub A',
          'hubId': 'hub-a',
          'proto': 2,
        }),
      });
      container = ProviderContainer();
      controller = build();
      await controller.start();
      await pumpEventQueue();

      discovery.emit(hubA);
      await pumpEventQueue();

      expect(sender.connectCalls, 1);
      expect(
        container.read(clientStateProvider).status,
        ClientConnectionStatus.connected,
      );
    });

    test('接続後に喪失すると再探索へ戻る', () async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      controller = build();
      await controller.start();
      await pumpEventQueue();

      await controller.connectTo(hubA);
      await pumpEventQueue();
      expect(
        container.read(clientStateProvider).status,
        ClientConnectionStatus.connected,
      );

      discovery.emitLost();
      await pumpEventQueue();

      expect(sender.isConnected, isFalse);
      expect(
        container.read(clientStateProvider).status,
        ClientConnectionStatus.searching,
      );
    });
  });
}
