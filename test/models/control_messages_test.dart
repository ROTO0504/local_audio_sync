import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/control_messages.dart';

void main() {
  group('ClientHello.parse (v1 HELLO)', () {
    test('HELLO:{name}:{uuid} をパースできる', () {
      final hello = ClientHello.parse('HELLO:MyPhone:uuid-1234');
      expect(hello, isNotNull);
      expect(hello!.name, 'MyPhone');
      expect(hello.uuid, 'uuid-1234');
      expect(hello.platform, 'unknown');
      expect(hello.protocolVersion, kProtocolVersionLegacy);
    });

    test('name にコロンが含まれても uuid は末尾から取れる', () {
      final hello = ClientHello.parse('HELLO:PC:Living:uuid-xyz');
      expect(hello, isNotNull);
      expect(hello!.name, 'PC:Living');
      expect(hello.uuid, 'uuid-xyz');
    });

    test('要素が足りなければ null', () {
      expect(ClientHello.parse('HELLO:onlyname'), isNull);
      expect(ClientHello.parse('HELLO:'), isNull);
    });
  });

  group('ClientHello.parse (v2 HELLO2)', () {
    test('HELLO2 をパースできる', () {
      final hello =
          ClientHello.parse('HELLO2:MyMac:uuid-abcd:macos:2');
      expect(hello, isNotNull);
      expect(hello!.name, 'MyMac');
      expect(hello.uuid, 'uuid-abcd');
      expect(hello.platform, 'macos');
      expect(hello.protocolVersion, 2);
    });

    test('name にコロンが含まれても末尾 3 要素は固定で取れる', () {
      final hello =
          ClientHello.parse('HELLO2:PC:Living:uuid-abcd:windows:2');
      expect(hello, isNotNull);
      expect(hello!.name, 'PC:Living');
      expect(hello.uuid, 'uuid-abcd');
      expect(hello.platform, 'windows');
    });

    test('encodeHello2 と parse がラウンドトリップする', () {
      const original = ClientHello(
        name: 'iPad mini',
        uuid: 'uuid-round',
        platform: 'ios',
        protocolVersion: kProtocolVersion,
      );
      final parsed = ClientHello.parse(original.encodeHello2());
      expect(parsed, isNotNull);
      expect(parsed!.name, original.name);
      expect(parsed.uuid, original.uuid);
      expect(parsed.platform, original.platform);
      expect(parsed.protocolVersion, original.protocolVersion);
    });

    test('encodeHelloV1 は旧形式になる', () {
      const hello = ClientHello(name: 'Dev', uuid: 'u1');
      expect(hello.encodeHelloV1(), 'HELLO:Dev:u1');
    });

    test('proto が数値でなければ null', () {
      expect(ClientHello.parse('HELLO2:n:u:ios:abc'), isNull);
    });

    test('HELLO でも HELLO2 でもなければ null', () {
      expect(ClientHello.parse('PING:3'), isNull);
      expect(ClientHello.parse('GOODBYE:x'), isNull);
    });
  });

  group('RemoteCommand', () {
    test('parse と encode がラウンドトリップする', () {
      const cmd = RemoteCommand(
        clientId: 7,
        commandSeq: 42,
        action: RemoteCommandAction.pause,
      );
      expect(cmd.encode(), 'CMD:7:42:PAUSE');
      final parsed = RemoteCommand.parse(cmd.encode());
      expect(parsed, isNotNull);
      expect(parsed!.clientId, 7);
      expect(parsed.commandSeq, 42);
      expect(parsed.action, RemoteCommandAction.pause);
    });

    test('全アクションをパースできる', () {
      expect(RemoteCommand.parse('CMD:1:1:PAUSE')!.action,
          RemoteCommandAction.pause);
      expect(RemoteCommand.parse('CMD:1:2:RESUME')!.action,
          RemoteCommandAction.resume);
      expect(RemoteCommand.parse('CMD:1:3:STOP')!.action,
          RemoteCommandAction.stop);
    });

    test('未知のアクションや欠損は null', () {
      expect(RemoteCommand.parse('CMD:1:1:DANCE'), isNull);
      expect(RemoteCommand.parse('CMD:1:PAUSE'), isNull);
      expect(RemoteCommand.parse('CMD:x:1:PAUSE'), isNull);
    });
  });

  group('CommandAck', () {
    test('parse と encode がラウンドトリップする', () {
      const ack = CommandAck(clientId: 3, commandSeq: 99);
      expect(ack.encode(), 'CMDACK:3:99');
      final parsed = CommandAck.parse(ack.encode());
      expect(parsed, isNotNull);
      expect(parsed!.clientId, 3);
      expect(parsed.commandSeq, 99);
    });

    test('不正な形式は null', () {
      expect(CommandAck.parse('CMDACK:3'), isNull);
      expect(CommandAck.parse('CMDACK:a:b'), isNull);
      expect(CommandAck.parse('CMD:3:99'), isNull);
    });
  });

  group('PONG', () {
    test('encodePong / parsePong がラウンドトリップする', () {
      expect(encodePong(12), 'PONG:12');
      expect(parsePong('PONG:12'), 12);
    });

    test('PONG 以外は null', () {
      expect(parsePong('PING:12'), isNull);
      expect(parsePong('PONG:abc'), isNull);
    });
  });
}
