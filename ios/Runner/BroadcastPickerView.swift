import Flutter
import ReplayKit
import UIKit

/// `RPSystemBroadcastPickerView` を Flutter に埋め込むためのプラットフォームビュー。
///
/// iOS のブロードキャスト(画面/音声配信)はユーザー操作で Picker を呼び出し、
/// そこから配信先 Extension を選んでもらう必要がある。
///
/// 利用方法(Dart 側):
///   UiKitView(
///     viewType: 'com.example.local_audio_sync/broadcastPicker',
///     creationParams: { 'preferredExtension': 'com.example.localAudioSync.BroadcastExtension' },
///     creationParamsCodec: const StandardMessageCodec(),
///   )
///
/// `preferredExtension` には Broadcast Upload Extension のバンドル ID を渡す。
/// 一致する Extension があれば 1 タップで配信開始できる。
@objc class BroadcastPickerViewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger

    @objc init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let params = args as? [String: Any]
        return BroadcastPickerPlatformView(frame: frame, params: params)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

class BroadcastPickerPlatformView: NSObject, FlutterPlatformView {

    private let containerView: UIView
    private let pickerView: RPSystemBroadcastPickerView

    init(frame: CGRect, params: [String: Any]?) {
        self.containerView = UIView(frame: frame)
        self.pickerView = RPSystemBroadcastPickerView(frame: containerView.bounds)

        super.init()

        pickerView.translatesAutoresizingMaskIntoConstraints = false
        if let prefer = params?["preferredExtension"] as? String, !prefer.isEmpty {
            pickerView.preferredExtension = prefer
        }
        pickerView.showsMicrophoneButton = false

        // Apple のデフォルトボタンは小さくて目立たないので、
        // 内部の UIButton にアクセスして見栄えを少し整える(失敗しても無害)。
        for sub in pickerView.subviews {
            if let btn = sub as? UIButton {
                btn.imageView?.tintColor = .systemBlue
                btn.setTitle("", for: .normal)
            }
        }

        containerView.addSubview(pickerView)
        NSLayoutConstraint.activate([
            pickerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            pickerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            pickerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            pickerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    func view() -> UIView {
        return containerView
    }
}
