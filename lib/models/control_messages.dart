/// プロトコル v2 の制御メッセージ(UDP 7777、テキスト)。
///
/// v1 のメッセージ(HELLO / ACKHELLO / PING / BYE / RESYNC)はそのままに、
/// v2 で HELLO2 / PONG / CMD / CMDACK を追加する。未知のメッセージは
/// 受信側で無視されるため、新旧バージョンが混在してもプロトコルは壊れない。
///
/// パースとエンコードを純関数としてここに集約し、送受信サービス側は
/// 文字列組み立てを持たない。
library;

/// 本アプリが話すプロトコルバージョン。
const int kProtocolVersion = 2;

/// v1 クライアント(HELLO のみ)を表すバージョン値。
const int kProtocolVersionLegacy = 1;

/// HELLO / HELLO2 をパースした接続要求。
class ClientHello {
  final String name;
  final String uuid;

  /// `ios` / `android` / `macos` / `windows` / `linux` / `unknown`。
  final String platform;
  final int protocolVersion;

  const ClientHello({
    required this.name,
    required this.uuid,
    this.platform = 'unknown',
    this.protocolVersion = kProtocolVersionLegacy,
  });

  /// `HELLO:{name}:{uuid}` または `HELLO2:{name}:{uuid}:{platform}:{proto}`
  /// をパースする。失敗時は null。
  ///
  /// name にコロンが含まれても壊れないよう、可変長の name 以外
  /// (uuid / platform / proto)を末尾から固定個数で取り出す。
  static ClientHello? parse(String text) {
    if (text.startsWith('HELLO2:')) {
      final parts = text.substring('HELLO2:'.length).split(':');
      if (parts.length < 4) return null;
      final proto = int.tryParse(parts.last);
      if (proto == null) return null;
      final platform = parts[parts.length - 2];
      final uuid = parts[parts.length - 3];
      final name = parts.sublist(0, parts.length - 3).join(':');
      if (name.isEmpty || uuid.isEmpty) return null;
      return ClientHello(
        name: name,
        uuid: uuid,
        platform: platform,
        protocolVersion: proto,
      );
    }
    if (text.startsWith('HELLO:')) {
      final parts = text.substring('HELLO:'.length).split(':');
      if (parts.length < 2) return null;
      final uuid = parts.last;
      final name = parts.sublist(0, parts.length - 1).join(':');
      if (name.isEmpty || uuid.isEmpty) return null;
      return ClientHello(name: name, uuid: uuid);
    }
    return null;
  }

  /// v2 形式の HELLO2 文字列を組み立てる。
  String encodeHello2() =>
      'HELLO2:$name:$uuid:$platform:$protocolVersion';

  /// v1 形式の HELLO 文字列を組み立てる(旧 Hub へのフォールバック用)。
  String encodeHelloV1() => 'HELLO:$name:$uuid';
}

/// Hub → Client のリモート制御コマンド種別。
enum RemoteCommandAction {
  /// キャプチャは維持したまま音声送信を止める。
  pause('PAUSE'),

  /// 送信を再開する(送信側は seq を 0 に戻してから送出する)。
  resume('RESUME'),

  /// 配信自体を終了する(キャプチャ停止)。
  stop('STOP');

  const RemoteCommandAction(this.wire);

  /// ワイヤ上の表現。
  final String wire;

  static RemoteCommandAction? fromWire(String value) {
    for (final action in RemoteCommandAction.values) {
      if (action.wire == value) return action;
    }
    return null;
  }
}

/// Hub → Client のリモート制御コマンド。
/// `CMD:{clientId}:{cmdSeq}:{PAUSE|RESUME|STOP}`
class RemoteCommand {
  final int clientId;

  /// Hub が発番する単調増加値。再送しても同じ値のままなので、
  /// 受信側はこの値で重複実行を防ぐ。
  final int commandSeq;
  final RemoteCommandAction action;

  const RemoteCommand({
    required this.clientId,
    required this.commandSeq,
    required this.action,
  });

  static RemoteCommand? parse(String text) {
    if (!text.startsWith('CMD:')) return null;
    final parts = text.substring('CMD:'.length).split(':');
    if (parts.length != 3) return null;
    final clientId = int.tryParse(parts[0]);
    final commandSeq = int.tryParse(parts[1]);
    final action = RemoteCommandAction.fromWire(parts[2]);
    if (clientId == null || commandSeq == null || action == null) return null;
    return RemoteCommand(
      clientId: clientId,
      commandSeq: commandSeq,
      action: action,
    );
  }

  String encode() => 'CMD:$clientId:$commandSeq:${action.wire}';
}

/// Client → Hub のコマンド到達確認。
/// `CMDACK:{clientId}:{cmdSeq}`
class CommandAck {
  final int clientId;
  final int commandSeq;

  const CommandAck({required this.clientId, required this.commandSeq});

  static CommandAck? parse(String text) {
    if (!text.startsWith('CMDACK:')) return null;
    final parts = text.substring('CMDACK:'.length).split(':');
    if (parts.length != 2) return null;
    final clientId = int.tryParse(parts[0]);
    final commandSeq = int.tryParse(parts[1]);
    if (clientId == null || commandSeq == null) return null;
    return CommandAck(clientId: clientId, commandSeq: commandSeq);
  }

  String encode() => 'CMDACK:$clientId:$commandSeq';
}

/// `PONG:{clientId}` を組み立てる(Hub → Client、PING への応答)。
String encodePong(int clientId) => 'PONG:$clientId';

/// `PONG:{clientId}` をパースする。PONG でなければ null。
int? parsePong(String text) {
  if (!text.startsWith('PONG:')) return null;
  return int.tryParse(text.substring('PONG:'.length));
}
