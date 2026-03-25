import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure audio session so iOS keeps the app alive in the background
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
      )
      try session.setActive(true)
    } catch {
      print("[AppDelegate] Audio session setup failed: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register native screen-audio plugin (RPScreenRecorder + EventChannel)
    ScreenAudioPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "ScreenAudioPlugin")!
    )
  }
}
