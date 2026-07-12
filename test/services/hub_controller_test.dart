import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';
import 'package:local_audio_sync/models/control_messages.dart';
import 'package:local_audio_sync/providers/hub_state_provider.dart';
import 'package:local_audio_sync/services/audio_mixer_service.dart';
import 'package:local_audio_sync/services/client_settings_store.dart';
import 'package:local_audio_sync/services/device_identity_service.dart';
import 'package:local_audio_sync/services/discovery_service.dart';
import 'package:local_audio_sync/services/hub_background_keeper.dart';
import 'package:local_audio_sync/services/hub_controller.dart';
import 'package:local_audio_sync/services/jitter_buffer.dart';
import 'package:local_audio_sync/services/mdns_discovery_service.dart';
import 'package:local_audio_sync/services/udp_receiver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ソケットを張らないフェイク受信サービス。
/// コールバックをテストから直接叩いて UDP 受信をシミュレートする。
class _FakeReceiver extends UdpReceiverService {
  bool started = false;
  bool stopped = false;
  final List<(String ip, int port, int id)> ackHellos = [];
  final List<(String ip, int port, int id)> resyncs = [];
  final List<(int clientId, RemoteCommandAction action, String ip, int port)>
      sentCommands = [];
  int _nextCommandSeq = 1;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  void stop() {
    stopped = true;
  }

  @override
  void sendAckHello(String ip, int port, int assignedId) {
    ackHellos.add((ip, port, assignedId));
  }

  @override
  void sendResync(String ip, int port, int clientId) {
    resyncs.add((ip, port, clientId));
  }

  @override
  int sendCommand(
    int clientId,
    RemoteCommandAction action,
    String ip,
    int port,
  ) {
    sentCommands.add((clientId, action, ip, port));
    return _nextCommandSeq++;
  }
}

/// ネイティブ FFI に触れないフェイクミキサー。
class _FakeMixer extends AudioMixerService {
  final List<int> addedClients = [];
  final List<int> removedClients = [];
  final Map<int, double> volumes = {};
  final List<(int id, int seq)> pushedPackets = [];

  @override
  void addClient(int clientId, {void Function()? onResync}) {
    addedClients.add(clientId);
  }

  @override
  void removeClient(int clientId) {
    removedClients.add(clientId);
  }

  @override
  void removeAllClients() {}

  @override
  void setVolume(int clientId, double volume) {
    volumes[clientId] = volume;
  }

  @override
  void pushEncodedPacket(int clientId, int sequence, Uint8List opusBytes) {
    pushedPackets.add((clientId, sequence));
  }
}

/// ブロードキャストを送らないフェイクビーコン。
class _FakeBeacon extends HubBeaconSender {
  String? startedWithName;
  String? startedWithHubId;
  bool stopped = false;

  @override
  Future<void> start(String hubName, {String? hubId}) async {
    startedWithName = hubName;
    startedWithHubId = hubId;
  }

  @override
  void stop() {
    stopped = true;
  }
}

/// mDNS を触らないフェイク公開サービス。
class _FakeMdnsAdvertiser extends HubMdnsAdvertiser {
  String? startedWithName;
  String? startedWithHubId;
  bool stopped = false;

  @override
  Future<void> start({
    required String hubName,
    required String hubId,
    int port = kAudioPort,
  }) async {
    startedWithName = hubName;
    startedWithHubId = hubId;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

/// プラットフォームチャネルを触らないフェイク。
class _FakeBackgroundKeeper extends HubBackgroundKeeper {
  bool started = false;
  bool stopped = false;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _FakeReceiver receiver;
  late _FakeMixer mixer;
  late _FakeBeacon beacon;
  late _FakeMdnsAdvertiser mdns;
  late _FakeBackgroundKeeper backgroundKeeper;
  late ClientSettingsStore settingsStore;
  late HubController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceIdentityService.resetCache();
  });

  Future<void> startController({
    Duration staleCheckInterval = const Duration(seconds: 10),
    Duration staleTimeout = const Duration(seconds: 10),
    Duration vuUpdateInterval = const Duration(milliseconds: 150),
  }) async {
    container = ProviderContainer();
    receiver = _FakeReceiver();
    mixer = _FakeMixer();
    beacon = _FakeBeacon();
    mdns = _FakeMdnsAdvertiser();
    backgroundKeeper = _FakeBackgroundKeeper();
    settingsStore = ClientSettingsStore();
    final provider = Provider<HubController>((ref) => HubController(
          ref,
          receiver: receiver,
          mixer: mixer,
          beacon: beacon,
          mdnsAdvertiser: mdns,
          backgroundKeeper: backgroundKeeper,
          settingsStore: settingsStore,
          staleCheckInterval: staleCheckInterval,
          staleTimeout: staleTimeout,
          vuUpdateInterval: vuUpdateInterval,
        ));
    controller = container.read(provider);
    await controller.start('TestHub');
  }

  ClientHello helloV2(String uuid,
          {String name = 'Dev', String platform = 'ios'}) =>
      ClientHello(
        name: name,
        uuid: uuid,
        platform: platform,
        protocolVersion: kProtocolVersion,
      );

  /// HELLO を送って非同期処理(設定ストア読み込み)の完了まで待つ。
  Future<void> sendHello(ClientHello hello, String ip, int port) async {
    receiver.onClientHello!(hello, ip, port);
    await pumpEventQueue();
  }

  tearDown(() async {
    await controller.stop();
    container.dispose();
  });

  group('HubController 接続ライフサイクル', () {
    test('start で受信・ビーコン・mDNS・バックグラウンド維持が開始される', () async {
      await startController();
      expect(receiver.started, isTrue);
      expect(beacon.startedWithName, 'TestHub');
      expect(beacon.startedWithHubId, isNotNull); // 永続 hubId が渡る
      expect(mdns.startedWithName, 'TestHub');
      expect(mdns.startedWithHubId, beacon.startedWithHubId);
      expect(backgroundKeeper.started, isTrue);
      expect(controller.isRunning, isTrue);
    });

    test('HELLO2 でクライアントが登録され ACKHELLO とミキサー登録が行われる', () async {
      await startController();

      await sendHello(helloV2('uuid-a'), '192.168.1.20', 50000);

      final state = container.read(hubStateProvider);
      expect(state, hasLength(1));
      final client = state['uuid-a']!;
      expect(client.name, 'Dev');
      expect(client.ip, '192.168.1.20');
      expect(client.port, 50000);
      expect(client.platform, 'ios');
      expect(client.protocolVersion, kProtocolVersion);
      expect(client.isActive, isTrue);

      expect(receiver.ackHellos, hasLength(1));
      expect(receiver.ackHellos.single.$3, controller.clientIdOf('uuid-a'));
      expect(mixer.addedClients, hasLength(1));
    });

    test('同一 uuid の再 HELLO は同じ clientId を再利用しミキサーを初期化し直す', () async {
      await startController();

      await sendHello(helloV2('uuid-a'), '192.168.1.20', 50000);
      final firstId = controller.clientIdOf('uuid-a');

      // BYE なしの再接続(ポートが変わるケース)
      await sendHello(helloV2('uuid-a'), '192.168.1.20', 50123);
      final secondId = controller.clientIdOf('uuid-a');

      expect(secondId, firstId);
      // 古いミキサースロットを破棄してから登録し直している
      expect(mixer.removedClients, contains(firstId));
      expect(mixer.addedClients, hasLength(2));
      // ポートは新しい値に更新される
      expect(container.read(hubStateProvider)['uuid-a']!.port, 50123);
    });

    test('異なる uuid には別の clientId を割り当てる', () async {
      await startController();

      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      await sendHello(helloV2('uuid-b'), '10.0.0.2', 2222);

      expect(controller.clientIdOf('uuid-a'),
          isNot(controller.clientIdOf('uuid-b')));
      expect(container.read(hubStateProvider), hasLength(2));
    });
  });

  group('HubController v1/v2 共存', () {
    test('HELLO2 の後に v1 HELLO が届いても platform が退行しない', () async {
      await startController();

      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      // 併送された v1 HELLO が後から届く
      await sendHello(
        const ClientHello(name: 'Dev', uuid: 'uuid-a'),
        '10.0.0.1',
        1111,
      );

      final client = container.read(hubStateProvider)['uuid-a']!;
      expect(client.platform, 'ios');
      expect(client.protocolVersion, kProtocolVersion);
    });

    test('v1 のみのクライアントは platform unknown で登録される', () async {
      await startController();

      await sendHello(
        const ClientHello(name: 'Old', uuid: 'uuid-old'),
        '10.0.0.9',
        9999,
      );

      final client = container.read(hubStateProvider)['uuid-old']!;
      expect(client.platform, 'unknown');
      expect(client.protocolVersion, kProtocolVersionLegacy);
    });
  });

  group('HubController 設定の永続化と復元', () {
    test('保存済みの音量/ミュートが HELLO 時に復元されミキサーへ反映される', () async {
      SharedPreferences.setMockInitialValues({
        'client_settings_uuid-a': '{"volume": 0.25, "isMuted": true}',
      });
      await startController();

      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);

      final client = container.read(hubStateProvider)['uuid-a']!;
      expect(client.volume, closeTo(0.25, 0.001));
      expect(client.isMuted, isTrue);
      // ミュート中なのでミキサー音量は 0
      final id = controller.clientIdOf('uuid-a')!;
      expect(mixer.volumes[id], 0.0);
    });

    test('セッション中の状態は永続ストアより優先される', () async {
      SharedPreferences.setMockInitialValues({
        'client_settings_uuid-a': '{"volume": 0.25, "isMuted": false}',
      });
      await startController();

      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      await controller.setClientVolume('uuid-a', 0.9);

      // BYE なしの再 HELLO(existing が残っている)
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1112);

      expect(
        container.read(hubStateProvider)['uuid-a']!.volume,
        closeTo(0.9, 0.001),
      );
    });

    test('setClientVolume は永続化され、ミキサーに即時反映される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await controller.setClientVolume('uuid-a', 0.4);

      expect(mixer.volumes[id], closeTo(0.4, 0.001));
      final stored = await settingsStore.load('uuid-a');
      expect(stored!.volume, closeTo(0.4, 0.001));
    });

    test('setClientMuted は音量 0 としてミキサーへ反映され永続化される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await controller.setClientMuted('uuid-a', muted: true);

      expect(mixer.volumes[id], 0.0);
      expect((await settingsStore.load('uuid-a'))!.isMuted, isTrue);

      await controller.setClientMuted('uuid-a', muted: false);
      expect(mixer.volumes[id], closeTo(1.0, 0.001));
    });

    test('setMasterVolume は全クライアントに適用される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      await sendHello(helloV2('uuid-b'), '10.0.0.2', 2222);

      await controller.setMasterVolume(0.5);

      final state = container.read(hubStateProvider);
      expect(state['uuid-a']!.volume, closeTo(0.5, 0.001));
      expect(state['uuid-b']!.volume, closeTo(0.5, 0.001));
    });

    test('removeClientEntry で一覧から消えるが設定は残る', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      await controller.setClientVolume('uuid-a', 0.3);
      final id = controller.clientIdOf('uuid-a')!;

      controller.removeClientEntry('uuid-a');

      expect(container.read(hubStateProvider), isEmpty);
      expect(controller.clientIdOf('uuid-a'), isNull);
      expect(mixer.removedClients, contains(id));
      // 設定は保持され、再接続時に復元できる
      expect((await settingsStore.load('uuid-a'))!.volume, closeTo(0.3, 0.001));
    });
  });

  group('HubController PING / BYE / stale', () {
    test('PING で lastSeen が更新され inactive から復帰する', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      container.read(hubStateProvider.notifier).markInactive('uuid-a');
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isFalse);

      receiver.onClientPing!(id);
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isTrue);
    });

    test('BYE でクライアントが削除される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      receiver.onClientBye!(id);

      expect(container.read(hubStateProvider), isEmpty);
      expect(controller.clientIdOf('uuid-a'), isNull);
      expect(mixer.removedClients, contains(id));
    });

    test('PING が途絶えたクライアントは inactive になり、再接続で同じ ID を得る', () async {
      await startController(
        staleCheckInterval: const Duration(milliseconds: 30),
        staleTimeout: const Duration(milliseconds: 60),
      );
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await Future<void>.delayed(const Duration(milliseconds: 150));

      final client = container.read(hubStateProvider)['uuid-a']!;
      expect(client.isActive, isFalse);
      expect(mixer.removedClients, contains(id));
      // uuid → clientId の対応は保持され、再接続では同じ番号を再利用する
      expect(controller.clientIdOf('uuid-a'), id);

      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1112);
      expect(controller.clientIdOf('uuid-a'), id);
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isTrue);
    });
  });

  group('HubController 音声パケットと VU レベル', () {
    AudioPacket packet(int clientId, int seq) => AudioPacket(
          clientId: clientId,
          sequence: seq,
          opusBytes: Uint8List.fromList([1, 2, 3]),
        );

    test('音声パケットが音量つきでミキサーへ流れる', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await controller.setClientVolume('uuid-a', 0.5);
      receiver.onAudioPacket!(packet(id, 0), '10.0.0.1');

      expect(mixer.volumes[id], closeTo(0.5, 0.001));
      expect(mixer.pushedPackets, contains((id, 0)));
    });

    test('ミュート中は音量 0 で流れる', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await controller.setClientMuted('uuid-a', muted: true);
      receiver.onAudioPacket!(packet(id, 1), '10.0.0.1');

      expect(mixer.volumes[id], 0.0);
    });

    test('ミキサーの VU レベルがスロットルされて反映される', () async {
      await startController(
        vuUpdateInterval: const Duration(milliseconds: 100),
      );
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      // 1 回目は反映、直後の 2 回目はスロットルで無視
      mixer.onClientLevel!(id, 0.8);
      mixer.onClientLevel!(id, 0.1);

      expect(
        container.read(hubStateProvider)['uuid-a']!.vuLevel,
        closeTo(0.8, 0.001),
      );

      // スロットル期間を過ぎれば更新される
      await Future<void>.delayed(const Duration(milliseconds: 120));
      mixer.onClientLevel!(id, 0.2);
      expect(
        container.read(hubStateProvider)['uuid-a']!.vuLevel,
        closeTo(0.2, 0.001),
      );
    });
  });

  group('HubController リモート制御', () {
    test('pauseClient で CMD が送られ isPaused が楽観反映される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      controller.pauseClient('uuid-a');

      expect(receiver.sentCommands, hasLength(1));
      final sent = receiver.sentCommands.single;
      expect(sent.$1, id);
      expect(sent.$2, RemoteCommandAction.pause);
      expect(sent.$3, '10.0.0.1');
      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isTrue);

      controller.resumeClient('uuid-a');
      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isFalse);
    });

    test('v1 クライアントには CMD を送らず失敗通知する', () async {
      await startController();
      await sendHello(
        const ClientHello(name: 'Old', uuid: 'uuid-old'),
        '10.0.0.9',
        9999,
      );
      final failures = <(String, RemoteCommandAction)>[];
      controller.onCommandDeliveryFailed = (uuid, action) {
        failures.add((uuid, action));
      };

      controller.pauseClient('uuid-old');

      expect(receiver.sentCommands, isEmpty);
      expect(failures, [('uuid-old', RemoteCommandAction.pause)]);
      expect(
        container.read(hubStateProvider)['uuid-old']!.isPaused,
        isFalse,
      );
    });

    test('CMD 未達(再送尽き)で楽観反映が戻り通知される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;
      final failures = <(String, RemoteCommandAction)>[];
      controller.onCommandDeliveryFailed = (uuid, action) {
        failures.add((uuid, action));
      };

      controller.pauseClient('uuid-a');
      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isTrue);

      // 再送キューが諦めたことを模擬
      receiver.onCommandFailed!(RemoteCommand(
        clientId: id,
        commandSeq: 1,
        action: RemoteCommandAction.pause,
      ));

      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isFalse);
      expect(failures, [('uuid-a', RemoteCommandAction.pause)]);
    });

    test('一時停止中のクライアントから音声が届いたら isPaused を解除する(後勝ち)', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      controller.pauseClient('uuid-a');
      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isTrue);

      // クライアント側ローカル操作で再開され、音声が再び届いた
      receiver.onAudioPacket!(
        AudioPacket(
          clientId: id,
          sequence: 0,
          opusBytes: Uint8List.fromList([1]),
        ),
        '10.0.0.1',
      );

      expect(container.read(hubStateProvider)['uuid-a']!.isPaused, isFalse);
    });

    test('pauseAll / resumeAll はアクティブな v2 クライアントに一括送信する', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      await sendHello(helloV2('uuid-b'), '10.0.0.2', 2222);

      controller.pauseAll();
      expect(
        receiver.sentCommands.where((c) => c.$2 == RemoteCommandAction.pause),
        hasLength(2),
      );
      final state = container.read(hubStateProvider);
      expect(state.values.every((c) => c.isPaused), isTrue);

      controller.resumeAll();
      expect(
        receiver.sentCommands.where((c) => c.$2 == RemoteCommandAction.resume),
        hasLength(2),
      );
      expect(
        container
            .read(hubStateProvider)
            .values
            .every((c) => !c.isPaused),
        isTrue,
      );
    });
  });

  group('HubController ジッターバッファプリセット', () {
    test('setJitterPreset で既存クライアントのバッファが作り直され永続化される', () async {
      await startController();
      await sendHello(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;
      final addCountBefore = mixer.addedClients.length;

      await controller.setJitterPreset(JitterBufferPreset.wan);

      expect(controller.jitterPreset, JitterBufferPreset.wan);
      expect(mixer.removedClients, contains(id));
      expect(mixer.addedClients.length, addCountBefore + 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('hub_jitter_preset'), 'wan');
    });

    test('保存済みプリセットは start 時に復元される', () async {
      SharedPreferences.setMockInitialValues({'hub_jitter_preset': 'wan'});
      await startController();
      expect(controller.jitterPreset, JitterBufferPreset.wan);
    });

    test('不明なプリセット名は lan にフォールバックする', () {
      expect(JitterBufferPreset.fromName('wan'), JitterBufferPreset.wan);
      expect(JitterBufferPreset.fromName('unknown'), JitterBufferPreset.lan);
      expect(JitterBufferPreset.fromName(null), JitterBufferPreset.lan);
    });
  });

  group('HubController 停止', () {
    test('stop でコールバックが外れタイマーとサービスが止まる', () async {
      await startController();
      await controller.stop();

      expect(receiver.stopped, isTrue);
      expect(beacon.stopped, isTrue);
      expect(mdns.stopped, isTrue);
      expect(backgroundKeeper.stopped, isTrue);
      expect(receiver.onClientHello, isNull);
      expect(receiver.onAudioPacket, isNull);
      expect(controller.isRunning, isFalse);
    });
  });
}
