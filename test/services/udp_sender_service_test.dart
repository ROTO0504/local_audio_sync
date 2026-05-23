import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/audio_packet.dart';
import 'package:local_audio_sync/services/udp_sender_service.dart';

/// モック Hub。loopback で UDP を bind し、HELLO/ACKHELLO の挙動と
/// 受信した音声パケットの seq を観測する。
class _MockHub {
  RawDatagramSocket? socket;
  StreamSubscription? sub;

  /// HELLO を受け取ったときに ACKHELLO で返す clientId。
  int ackClientId = 1;

  /// HELLO に対して ACKHELLO を返すかどうか(false ならタイムアウトを模擬)。
  bool replyAckHello = true;

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
      final dg = s.receive();
      if (dg == null) return;
      lastSenderAddr = dg.address;
      lastSenderPort = dg.port;

      // テキスト系を先に判定
      if (dg.data.isNotEmpty && dg.data[0] < 128) {
        final text = String.fromCharCodes(dg.data);
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
        if (text.startsWith('PING:') || text.startsWith('BYE:')) {
          receivedTexts.add(text);
          return;
        }
      }

      // バイナリ音声パケット
      final packet = AudioPacket.fromBytes(dg.data);
      if (packet != null) {
        receivedSeqs.add(packet.sequence);
      }
    });
    return s.port;
  }

  /// 送信側に RESYNC を返す。lastSenderAddr/Port が判明している前提。
  void sendResyncTo(int clientId) {
    final s = socket;
    final addr = lastSenderAddr;
    final port = lastSenderPort;
    if (s == null || addr == null || port == null) return;
    s.send('RESYNC:$clientId'.codeUnits, addr, port);
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

      for (int i = 0; i < 5; i++) {
        sender.sendAudio(Uint8List.fromList([i & 0xFF]));
      }
      // ソケットの非同期受信に余裕を持たせる
      await Future<void>.delayed(const Duration(milliseconds: 100));

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
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hub.receivedSeqs, equals([0, 1, 2]));

        // Hub から RESYNC を返す
        hub.sendResyncTo(11);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        // ここから seq は再び 0 起点
        hub.receivedSeqs.clear();
        sender.sendAudio(Uint8List.fromList([0xAA]));
        sender.sendAudio(Uint8List.fromList([0xBB]));
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        sender.sendAudio(Uint8List.fromList([0x02]));
        await Future<void>.delayed(const Duration(milliseconds: 80));

        // 別の clientId 宛 RESYNC
        hub.sendResyncTo(99);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        hub.receivedSeqs.clear();
        sender.sendAudio(Uint8List.fromList([0x03]));
        await Future<void>.delayed(const Duration(milliseconds: 80));

        // seq は途切れず継続(2 → 3)
        expect(hub.receivedSeqs, equals([2]));
      } finally {
        sender.disconnect();
        hub.stop();
      }
    });
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
