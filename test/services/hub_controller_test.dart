import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';
import 'package:local_audio_sync/models/control_messages.dart';
import 'package:local_audio_sync/providers/hub_state_provider.dart';
import 'package:local_audio_sync/services/audio_mixer_service.dart';
import 'package:local_audio_sync/services/discovery_service.dart';
import 'package:local_audio_sync/services/hub_controller.dart';
import 'package:local_audio_sync/services/udp_receiver_service.dart';

/// ソケットを張らないフェイク受信サービス。
/// コールバックをテストから直接叩いて UDP 受信をシミュレートする。
class _FakeReceiver extends UdpReceiverService {
  bool started = false;
  bool stopped = false;
  final List<(String ip, int port, int id)> ackHellos = [];
  final List<(String ip, int port, int id)> resyncs = [];

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
  bool stopped = false;

  @override
  Future<void> start(String hubName) async {
    startedWithName = hubName;
  }

  @override
  void stop() {
    stopped = true;
  }
}

void main() {
  late ProviderContainer container;
  late _FakeReceiver receiver;
  late _FakeMixer mixer;
  late _FakeBeacon beacon;
  late HubController controller;

  Future<void> startController({
    Duration staleCheckInterval = const Duration(seconds: 10),
    Duration staleTimeout = const Duration(seconds: 10),
  }) async {
    container = ProviderContainer();
    receiver = _FakeReceiver();
    mixer = _FakeMixer();
    beacon = _FakeBeacon();
    final provider = Provider<HubController>((ref) => HubController(
          ref,
          receiver: receiver,
          mixer: mixer,
          beacon: beacon,
          staleCheckInterval: staleCheckInterval,
          staleTimeout: staleTimeout,
        ));
    controller = container.read(provider);
    await controller.start('TestHub');
  }

  ClientHello helloV2(String uuid, {String name = 'Dev', String platform = 'ios'}) =>
      ClientHello(
        name: name,
        uuid: uuid,
        platform: platform,
        protocolVersion: kProtocolVersion,
      );

  tearDown(() async {
    await controller.stop();
    container.dispose();
  });

  group('HubController 接続ライフサイクル', () {
    test('start で受信・ビーコンが開始される', () async {
      await startController();
      expect(receiver.started, isTrue);
      expect(beacon.startedWithName, 'TestHub');
      expect(controller.isRunning, isTrue);
    });

    test('HELLO2 でクライアントが登録され ACKHELLO とミキサー登録が行われる', () async {
      await startController();

      receiver.onClientHello!(helloV2('uuid-a'), '192.168.1.20', 50000);

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

      receiver.onClientHello!(helloV2('uuid-a'), '192.168.1.20', 50000);
      final firstId = controller.clientIdOf('uuid-a');

      // BYE なしの再接続(ポートが変わるケース)
      receiver.onClientHello!(helloV2('uuid-a'), '192.168.1.20', 50123);
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

      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      receiver.onClientHello!(helloV2('uuid-b'), '10.0.0.2', 2222);

      expect(controller.clientIdOf('uuid-a'),
          isNot(controller.clientIdOf('uuid-b')));
      expect(container.read(hubStateProvider), hasLength(2));
    });
  });

  group('HubController v1/v2 共存', () {
    test('HELLO2 の後に v1 HELLO が届いても platform が退行しない', () async {
      await startController();

      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      // 併送された v1 HELLO が後から届く
      receiver.onClientHello!(
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

      receiver.onClientHello!(
        const ClientHello(name: 'Old', uuid: 'uuid-old'),
        '10.0.0.9',
        9999,
      );

      final client = container.read(hubStateProvider)['uuid-old']!;
      expect(client.platform, 'unknown');
      expect(client.protocolVersion, kProtocolVersionLegacy);
    });
  });

  group('HubController PING / BYE / stale', () {
    test('PING で lastSeen が更新され inactive から復帰する', () async {
      await startController();
      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      container.read(hubStateProvider.notifier).markInactive('uuid-a');
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isFalse);

      receiver.onClientPing!(id);
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isTrue);
    });

    test('BYE でクライアントが削除される', () async {
      await startController();
      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
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
      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      await Future<void>.delayed(const Duration(milliseconds: 150));

      final client = container.read(hubStateProvider)['uuid-a']!;
      expect(client.isActive, isFalse);
      expect(mixer.removedClients, contains(id));
      // uuid → clientId の対応は保持され、再接続では同じ番号を再利用する
      expect(controller.clientIdOf('uuid-a'), id);

      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1112);
      expect(controller.clientIdOf('uuid-a'), id);
      expect(container.read(hubStateProvider)['uuid-a']!.isActive, isTrue);
    });
  });

  group('HubController 音声パケット', () {
    AudioPacket packet(int clientId, int seq) => AudioPacket(
          clientId: clientId,
          sequence: seq,
          opusBytes: Uint8List.fromList([1, 2, 3]),
        );

    test('音声パケットが音量つきでミキサーへ流れる', () async {
      await startController();
      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      container.read(hubStateProvider.notifier).setVolume('uuid-a', 0.5);
      receiver.onAudioPacket!(packet(id, 0), '10.0.0.1');

      expect(mixer.volumes[id], closeTo(0.5, 0.001));
      expect(mixer.pushedPackets, contains((id, 0)));
    });

    test('ミュート中は音量 0 で流れる', () async {
      await startController();
      receiver.onClientHello!(helloV2('uuid-a'), '10.0.0.1', 1111);
      final id = controller.clientIdOf('uuid-a')!;

      container.read(hubStateProvider.notifier).setMuted('uuid-a', muted: true);
      receiver.onAudioPacket!(packet(id, 1), '10.0.0.1');

      expect(mixer.volumes[id], 0.0);
    });
  });

  group('HubController 停止', () {
    test('stop でコールバックが外れタイマーとサービスが止まる', () async {
      await startController();
      await controller.stop();

      expect(receiver.stopped, isTrue);
      expect(beacon.stopped, isTrue);
      expect(receiver.onClientHello, isNull);
      expect(receiver.onAudioPacket, isNull);
      expect(controller.isRunning, isFalse);
    });
  });
}
