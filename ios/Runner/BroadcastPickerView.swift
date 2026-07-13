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
///     creationParams: { 'preferredExtension': 'com.roto0504.localAudioSync.BroadcastExtension' },
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

/// `RPSystemBroadcastPickerView` を **プログラム的に** 起動するコントローラ。
///
/// UiKitView としてボタンを埋め込む方式は、iOS 18/26 で
/// `RPSystemBroadcastPickerView` 内部の UIButton が描画されない・タップが
/// 伝搬しないことがあり、ユーザーからは「押せない・ボタンが無い」状態になる。
///
/// そこで、通常の Flutter ボタンから MethodChannel 経由でこのコントローラを呼び、
/// キーウィンドウにほぼ不可視で追加した Picker の内部ボタンへ `touchUpInside` を
/// 送ることでシステムの配信シートを開く。これで描画・タップは Flutter 側で完全に
/// 制御でき、確実に配信を開始できる。
@objc class BroadcastPickerController: NSObject {

    /// 生成した Picker を保持(再利用 & 解放防止)。
    private var picker: RPSystemBroadcastPickerView?

    /// 配信シートを表示する。`preferredExtension` があれば対象 Extension を優先。
    @objc func present(preferredExtension: String?) {
        DispatchQueue.main.async {
            guard let window = BroadcastPickerController.keyWindow() else { return }

            let picker: RPSystemBroadcastPickerView
            if let existing = self.picker {
                picker = existing
            } else {
                // 画面外・ほぼ透明でウィンドウ階層に置く(ビュー階層に居ないと
                // 内部ボタンの sendActions がシートを提示できない)。
                picker = RPSystemBroadcastPickerView(
                    frame: CGRect(x: -2000, y: -2000, width: 1, height: 1)
                )
                picker.showsMicrophoneButton = false
                picker.alpha = 0.01
                window.addSubview(picker)
                self.picker = picker
            }

            if let ext = preferredExtension, !ext.isEmpty {
                picker.preferredExtension = ext
            }

            // 内部の UIButton を再帰的に探して touchUpInside を送る。
            // iOS のバージョンでボタンの入れ子の深さが変わるため再帰で探索する。
            if let button = BroadcastPickerController.findButton(in: picker) {
                button.sendActions(for: .touchUpInside)
            }
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }

    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
        }
        // フォールバック: 最初のシーンの最初のウィンドウ
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first
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
