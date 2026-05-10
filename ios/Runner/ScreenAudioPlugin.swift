import Flutter

/// 旧 In-App Recording 用プラグインの空スタブ。
///
/// このプラグインは BroadcastReceiverPlugin に置き換わったため、
/// 内部音声(他アプリの音)取得には使われない。pbxproj からのファイル参照は
/// 後続のクリーンアップコミットで除去予定。
///
/// AppDelegate からの登録はすでに削除済み。
@objc class ScreenAudioPlugin: NSObject {
    @objc static func register(with registrar: FlutterPluginRegistrar) {
        // No-op. BroadcastReceiverPlugin が新しい実装を提供する。
    }
}
