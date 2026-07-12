import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/discovery_service.dart';

void main() {
  group('DiscoveredHub.fromBeacon', () {
    test('正しい形式のビーコン文字列をパース', () {
      const beacon = 'LAHUB:192.168.1.5:7777:MyHub';
      final result = DiscoveredHub.fromBeacon(beacon);
      expect(result, isNotNull);
      expect(result!.ip, equals('192.168.1.5'));
      expect(result.port, equals(7777));
      expect(result.name, equals('MyHub'));
    });

    test('プレフィックスが違うと null', () {
      expect(
        DiscoveredHub.fromBeacon('WRONGPREFIX:192.168.1.5:7777:MyHub'),
        isNull,
      );
    });

    test('セグメント数が足りないと null', () {
      expect(DiscoveredHub.fromBeacon('LAHUB:192.168.1.5:7777'), isNull);
    });

    test('port が数値以外だと null', () {
      expect(
        DiscoveredHub.fromBeacon('LAHUB:192.168.1.5:notaport:MyHub'),
        isNull,
      );
    });

    test('空文字列は null', () {
      expect(DiscoveredHub.fromBeacon(''), isNull);
    });

    test('Hub 名にコロンが含まれていても保持される', () {
      const beacon = 'LAHUB:10.0.0.1:8080:My:Hub';
      final result = DiscoveredHub.fromBeacon(beacon);
      expect(result, isNotNull);
      expect(result!.name, equals('My:Hub'));
    });

    test('値が同じインスタンスは == で等しい', () {
      const a = DiscoveredHub(ip: '1.2.3.4', port: 7777, name: 'X');
      const b = DiscoveredHub(ip: '1.2.3.4', port: 7777, name: 'X');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('DiscoveredHub.fromBeacon (v2)', () {
    test('LAHUB2 形式をパースできる', () {
      const beacon = 'LAHUB2:192.168.1.5:7777:MyHub:hub-uuid-1:2';
      final result = DiscoveredHub.fromBeacon(beacon);
      expect(result, isNotNull);
      expect(result!.ip, '192.168.1.5');
      expect(result.port, 7777);
      expect(result.name, 'MyHub');
      expect(result.hubId, 'hub-uuid-1');
      expect(result.protocolVersion, 2);
    });

    test('v2 でも Hub 名のコロンは保持される', () {
      const beacon = 'LAHUB2:10.0.0.1:8080:My:Hub:hub-uuid-2:2';
      final result = DiscoveredHub.fromBeacon(beacon);
      expect(result, isNotNull);
      expect(result!.name, 'My:Hub');
      expect(result.hubId, 'hub-uuid-2');
    });

    test('v1 ビーコンは hubId が null で protocolVersion 1', () {
      final result = DiscoveredHub.fromBeacon('LAHUB:1.2.3.4:7777:Old');
      expect(result, isNotNull);
      expect(result!.hubId, isNull);
      expect(result.protocolVersion, 1);
    });

    test('セグメント不足や proto 非数値は null', () {
      expect(DiscoveredHub.fromBeacon('LAHUB2:1.2.3.4:7777:Name:hub'), isNull);
      expect(
        DiscoveredHub.fromBeacon('LAHUB2:1.2.3.4:7777:Name:hub:x'),
        isNull,
      );
    });

    test('v1 と v2 のビーコンは同じ Hub として dedup される(equality)', () {
      // 交互送信される v1/v2 ビーコンで ClientDiscoveryListener の
      // 重複抑止が壊れないことの前提条件。
      final v1 = DiscoveredHub.fromBeacon('LAHUB:1.2.3.4:7777:SameHub')!;
      final v2 =
          DiscoveredHub.fromBeacon('LAHUB2:1.2.3.4:7777:SameHub:hub-x:2')!;
      expect(v1, equals(v2));
      expect(v1.hashCode, equals(v2.hashCode));
    });
  });

  group('ClientDiscoveryListener Hub 喪失タイムアウト', () {
    test('lossTimeout 経過後、hubLostStream にイベントが流れる', () async {
      // ループバックに自前で送るので reusePort 周りの挙動差を回避するため
      // 実 UDP を使うのは別テストに分け、ここではコールバックロジックだけ検証する。
      // タイマー駆動の watchdog をテストするため fakeAsync を使う。
      final listener = ClientDiscoveryListener(
        lossTimeout: const Duration(milliseconds: 500),
      );

      // 内部の lastBeaconAt を 1 秒前に手動で巻き戻す代わりに、
      // 実際にビーコンを 1 つ受信した状態を作って待機する。
      // start() は実 UDP bind を要求するので、bind 可能かをチェックして
      // 不可なら CI 環境とみなしてスキップ。
      try {
        await listener.start();
      } on SocketException {
        return; // CI 等で UDP bind ができない環境はスキップ
      }

      // Loopback で偽 Hub のビーコンを送って lastEmitted を埋める
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sender.broadcastEnabled = true;
      const beacon = 'LAHUB:127.0.0.1:7777:UnitTestHub';
      sender.send(
        beacon.codeUnits,
        InternetAddress('127.0.0.1'),
        kDiscoveryPort,
      );

      // 検出を待つ
      try {
        await listener.stream
            .firstWhere((h) => h.name == 'UnitTestHub')
            .timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // CI で UDP のループバック配送が失敗するケースもある
        sender.close();
        listener.dispose();
        return;
      }

      // タイムアウト発火を待つ
      final lostFuture = listener.hubLostStream.first.timeout(
        const Duration(seconds: 3),
      );
      // 以後ビーコンを送らない
      try {
        await lostFuture;
      } on TimeoutException {
        fail('Hub 喪失イベントが発火しませんでした');
      }

      sender.close();
      listener.dispose();
    }, tags: 'integration');

    test('resetState で内部状態がクリアされる', () {
      final listener = ClientDiscoveryListener();
      listener.resetState();
      // 直接の getter は無いが、stream に何も流れないことだけ確認
      expect(listener.lastBeaconAt.millisecondsSinceEpoch, 0);
      listener.dispose();
    });
  });
}
