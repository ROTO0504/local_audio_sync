import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';
import 'package:local_audio_sync/models/control_messages.dart';
import 'package:local_audio_sync/services/udp_sender_service.dart';

/// ローカル UDP でも遅延やバースト時のドロップが起こり得るため、
/// 固定待ちではなく条件成立までポーリングする。
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// モック Hub。loopback で UDP を bind し、HELLO/ACKHELLO の挙動と
/// 受信した音声パケットの seq を観測する。
class _MockHub {
  RawDatagramSocket? socket;
  StreamSubscription? sub;

  /// HELLO を受け取ったときに ACKHELLO で返す clientId。
  int ackClientId = 1;

  /// v1 HELLO に対して ACKHELLO を返すかどうか(false ならタイムアウトを模擬)。
  bool replyAckHello = true;

  /// v2 HELLO2 に対して ACKHELLO を返すかどうか(新 Hub の模擬)。
  bool replyAckHelloOnV2 = false;

  /// PING に PONG を返すかどうか(v2 Hub の模擬)。
  bool replyPong = false;

  /// 直近に受け取った送信側の (address, port)。RESYNC 等を返すのに使う。
  InternetAddress? lastSenderAddr;
  int? lastSenderPort;

  /// 受信した seq の履歴。
  final List<int> receivedSeqs = [];

  /// 受信した制御テキストの履歴(HELLO/PING/BYE/RESYNC など)。
  final List<String> receivedTexts = [];

  Future<int> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    socket = s;
    sub = s.listen((event) {
      if (event != RawSocketEvent.read) return;
      // 実装側と同じく、1 回の read イベントに複数データグラムが
      // 溜まっていても取りこぼさないよう null までドレインする。
      while (true) {
        final dg = s.receive();
        if (dg == null) break;
        _handleDatagram(s, dg);
      }
    });
    return s.port;
  }

  void _handleDatagram(RawDatagramSocket s, Datagram dg) {
    {
      lastSenderAddr = dg.address;
      lastSenderPort = dg.port;

      // テキスト系を先に判定
      if (dg.data.isNotEmpty && dg.data[0] < 128) {
        final text = String.fromCharCodes(dg.data);
        if (text.startsWith('HELLO2:')) {
          receivedTexts.add(text);
          if (replyAckHelloOnV2) {
            s.send(
              'ACKHELLO:$ackClientId'.codeUnits,
              dg.address,
              dg.port,
            );
          }
          return;
        }
        if (text.startsWith('HELLO:')) {
          receivedTexts.add(text);
          if (replyAckHello) {
            s.send(
              'ACKHELLO:$ackClientId'.codeUnits,
              dg.address,
              dg.port,
            );
          }
          return;
        }
        if (text.startsWith('PING:')) {
          receivedTexts.add(text);
          if (replyPong) {
            final id = int.tryParse(text.substring(5));
            if (id != null) {
              s.send('PONG:$id'.codeUnits, dg.address, dg.port);
            }
          }
          return;
        }
        if (text.startsWith('BYE:') || text.startsWith('CMDACK:')) {
          receivedTexts.add(text);
          return;
        }
      }

      // バイナリ音声パケット
      final packet = AudioPacket.fromBytes(dg.data);
      if (packet != null) {
        receivedSeqs.add(packet.sequence);
      }
    }
  }

  /// 送信側に RESYNC を返す。lastSenderAddr/Port が判明している前提。
  void sendResyncTo(int clientId) {
    final s = socket;
    final addr = lastSenderAddr;
    final port = lastSenderPort;
    if (s == null || addr == null || port == null) return;
    s.send('RESYNC:$clientId'.codeUnits, addr, port);
  }

  /// 送信側に CMD(リモート制御)を送る。
  void sendCommandTo(int clientId, int commandSeq, String action) {
    final s = socket;
    final addr = lastSenderAddr;
    final port = lastSenderPort;
    if (s == null || addr == null || port == null) return;
    s.send('CMD:$clientId:$commandSeq:$action'.codeUnits, addr, port);
  }

  void stop() {
    sub?.cancel();
    sub = null;
    socket?.close();
    socket = null;
  }
}

void main() {
  group('UdpSenderService 接続フロー', () {
    late _MockHub hub;
    late UdpSenderService sender;

    setUp(() async {
      hub = _MockHub();
      sender = UdpSenderService();
    });

    tearDown(() {
      sender.disconnect();
      hub.stop();
    });

    test('connect で HELLO を送り、ACKHELLO 受信で isConnected が true になる', () async {
      hub.ackClientId = 42;
      final port = await hub.start();

      await sender.connect('127.0.0.1', port, 'tester', 'uuid-aaa');

      expect(sender.isConnected, isTrue);
      expect(sender.clientId, 42);
      // HELLO のフォーマットも検証
      expect(hub.receivedTexts, contains('HELLO:tester:uuid-aaa'));
    });

    test('ACKHELLO が返らないと connect は TimeoutException で失敗する', () async {
      hub.replyAckHello = false;
      final port = await hub.start();

      await expectLater(
        sender.connect('127.0.0.1', port, 'tester', 'uuid-noack'),
        throwsA(isA<TimeoutException>()),
      );
      expect(sender.isConnected, isFalse);
      expect(sender.consecutiveFailures, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('sendAudio で連続 seq が Hub に届く', () async {
      hub.ackClientId = 7;
      final port = await hub.start();
      await sender.connect('127.0.0.1', port, 'tester', 'uuid-seq');

      // バースト送信はループバックでも稀にドロップするため、
      // 実運用(20ms ペーシング)と同様に 1 発ずつ到着を確認する
      for (int i = 0; i < 5; i++) {
        sender.sendAudio(Uint8List.fromList([i & 0xFF]));
        await waitFor(() => hub.receivedSeqs.length >= i + 1);
      }

      expect(hub.receivedSeqs, equals([0, 1, 2, 3, 4]));
    });
  });

  group('UdpSenderService RESYNC ハンドリング', () {
    test('Hub から RESYNC を受信すると次の sendAudio が seq=0 から始まる', () async {
      final hub = _MockHub()..ackClientId = 11;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect('127.0.0.1', port, 'tester', 'uuid-resync');

        // 既に何発か送って seq を進める
        for (int i = 0; i < 3; i++) {
          sender.sendAudio(Uint8List.fromList([i & 0xFF]));
          await waitFor(() => hub.receivedSeqs.length >= i + 1);
        }
        expect(hub.receivedSeqs, equals([0, 1, 2]));

        // Hub から RESYNC を返す
        hub.sendResyncTo(11);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        // ここから seq は再び 0 起点
        hub.receivedSeqs.clear();
        sender.sendAudio(Uint8List.fromList([0xAA]));
        await waitFor(() => hub.receivedSeqs.isNotEmpty);
        sender.sendAudio(Uint8List.fromList([0xBB]));
        await waitFor(() => hub.receivedSeqs.length >= 2);

        expect(hub.receivedSeqs, equals([0, 1]));
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('他クライアント宛 RESYNC は自分の seq に影響しない', () async {
      final hub = _MockHub()..ackClientId = 5;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect('127.0.0.1', port, 'tester', 'uuid-other');

        sender.sendAudio(Uint8List.fromList([0x01]));
        await waitFor(() => hub.receivedSeqs.isNotEmpty);
        sender.sendAudio(Uint8List.fromList([0x02]));
        await waitFor(() => hub.receivedSeqs.length >= 2);

        // 別の clientId 宛 RESYNC
        hub.sendResyncTo(99);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        hub.receivedSeqs.clear();
        sender.sendAudio(Uint8List.fromList([0x03]));
        await waitFor(() => hub.receivedSeqs.isNotEmpty);

        // seq は途切れず継続(2 → 3)
        expect(hub.receivedSeqs, equals([2]));
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });
  });

  group('UdpSenderService プロトコル v2', () {
    test('connect で HELLO2 と v1 HELLO が併送される', () async {
      final hub = _MockHub()..ackClientId = 21;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-v2',
          platform: 'windows',
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(hub.receivedTexts, contains('HELLO2:tester:uuid-v2:windows:2'));
        expect(hub.receivedTexts, contains('HELLO:tester:uuid-v2'));
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('HELLO2 にだけ応答する新 Hub でも接続できる', () async {
      final hub = _MockHub()
        ..ackClientId = 22
        ..replyAckHello = false
        ..replyAckHelloOnV2 = true;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-v2only',
          platform: 'macos',
        );
        expect(sender.isConnected, isTrue);
        expect(sender.clientId, 22);
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('CMD を受けると CMDACK を返し、再送では重複実行しない', () async {
      final hub = _MockHub()..ackClientId = 23;
      final sender = UdpSenderService();
      final actions = <RemoteCommandAction>[];
      sender.onRemoteCommand = actions.add;

      int ackCount() =>
          hub.receivedTexts.where((t) => t == 'CMDACK:23:1').length;

      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-cmd',
          platform: 'windows',
        );

        // 同じ commandSeq の CMD を 2 回(再送間隔を空けて模擬)
        hub.sendCommandTo(23, 1, 'PAUSE');
        await waitFor(() => ackCount() >= 1);
        hub.sendCommandTo(23, 1, 'PAUSE');
        await waitFor(() => ackCount() >= 2);

        // 実行は 1 回だけ
        expect(actions, equals([RemoteCommandAction.pause]));
        // ACK は再送分にも毎回返す(Hub の再送を止めるため)
        expect(ackCount(), 2);

        // 新しい commandSeq は実行される
        hub.sendCommandTo(23, 2, 'RESUME');
        await waitFor(() => actions.length >= 2);
        expect(
          actions,
          equals([RemoteCommandAction.pause, RemoteCommandAction.resume]),
        );
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('別 clientId 宛の CMD は無視する', () async {
      final hub = _MockHub()..ackClientId = 24;
      final sender = UdpSenderService();
      final actions = <RemoteCommandAction>[];
      sender.onRemoteCommand = actions.add;
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-other-cmd',
          platform: 'windows',
        );

        hub.sendCommandTo(99, 1, 'STOP');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(actions, isEmpty);
        expect(
          hub.receivedTexts.where((t) => t.startsWith('CMDACK:')),
          isEmpty,
        );
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('CMD PAUSE で送信ゲートが閉じ、RESUME で seq 0 から再開する', () async {
      final hub = _MockHub()..ackClientId = 26;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-gate',
          platform: 'windows',
        );

        // 通常送信で seq が進む
        sender.sendAudio(Uint8List.fromList([0x01]));
        sender.sendAudio(Uint8List.fromList([0x02]));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hub.receivedSeqs, equals([0, 1]));
        expect(sender.isPaused, isFalse);

        // PAUSE 受信 → 送信されなくなる
        hub.sendCommandTo(26, 1, 'PAUSE');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(sender.isPaused, isTrue);

        hub.receivedSeqs.clear();
        sender.sendAudio(Uint8List.fromList([0x03]));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hub.receivedSeqs, isEmpty);

        // RESUME 受信 → seq 0 から再開
        hub.sendCommandTo(26, 2, 'RESUME');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(sender.isPaused, isFalse);

        sender.sendAudio(Uint8List.fromList([0x04]));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hub.receivedSeqs, equals([0]));
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('CMD STOP でも送信ゲートが閉じ、ローカルの setPaused(false) で再開できる', () async {
      final hub = _MockHub()..ackClientId = 27;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-stop',
          platform: 'windows',
        );

        hub.sendCommandTo(27, 1, 'STOP');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(sender.isPaused, isTrue);

        // ローカル操作の再開(後勝ちルール)
        sender.setPaused(false);
        expect(sender.isPaused, isFalse);

        sender.sendAudio(Uint8List.fromList([0x05]));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hub.receivedSeqs, equals([0])); // seq はリセット済み
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });

    test('PONG が途絶えると onHubUnresponsive が一度だけ発火する', () async {
      final hub = _MockHub()
        ..ackClientId = 25
        ..replyPong = true;
      final sender = UdpSenderService(
        pingInterval: const Duration(milliseconds: 80),
        pongTimeout: const Duration(milliseconds: 200),
      );
      var unresponsiveCount = 0;
      sender.onHubUnresponsive = () => unresponsiveCount++;
      try {
        final port = await hub.start();
        await sender.connect(
          '127.0.0.1',
          port,
          'tester',
          'uuid-pong',
          platform: 'windows',
        );

        // PONG が返っている間は発火しない
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(unresponsiveCount, 0);

        // Hub が PONG を返さなくなる(プロセスは生きているがハング状態を模擬)
        hub.replyPong = false;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(unresponsiveCount, 1);
      } finally {
        sender.disconnect();
        hub.stop();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('UdpSenderService disconnect', () {
    test('disconnect で BYE が送られ、isConnected が false になる', () async {
      final hub = _MockHub()..ackClientId = 3;
      final sender = UdpSenderService();
      try {
        final port = await hub.start();
        await sender.connect('127.0.0.1', port, 'tester', 'uuid-bye');
        expect(sender.isConnected, isTrue);

        sender.disconnect();
        // BYE 送信は同期的に呼ばれるが、Hub の listen ループは非同期なので待つ
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(sender.isConnected, isFalse);
        expect(
          hub.receivedTexts.any((t) => t.startsWith('BYE:3')),
          isTrue,
        );
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });
  });
}
