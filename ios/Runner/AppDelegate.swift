import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // AVAudioSession の設定は AudioSessionManager に一元化し、ここでは行わない。
    // 起動直後のセッション起動は BroadcastReceiverPlugin / BroadcastPicker 経由で
    // 実際に配信が始まるタイミングまで遅延させる(余計な再生経路を確保しない)。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Broadcast Upload Extension からの音声を受け取るプラグイン
    BroadcastReceiverPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "BroadcastReceiverPlugin")!
    )

    // RPSystemBroadcastPickerView を Flutter に埋め込むためのプラットフォームビュー
    if let pickerRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "BroadcastPickerViewFactory"
    ) {
      let factory = BroadcastPickerViewFactory(messenger: pickerRegistrar.messenger())
      pickerRegistrar.register(
        factory,
        withId: "com.example.local_audio_sync/broadcastPicker"
      )
    }

    // Hub(集約・再生)モード用: miniaudio ミキサーの出力を裏で維持するため、
    // AVAudioSession の activate / deactivate を Flutter から制御する。
    if let hubRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "HubPlaybackChannel"
    ) {
      let channel = FlutterMethodChannel(
        name: "com.example.local_audio_sync/hubPlayback",
        binaryMessenger: hubRegistrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "start":
          AudioSessionManager.shared.activate()
          result(nil)
        case "stop":
          AudioSessionManager.shared.deactivate()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
