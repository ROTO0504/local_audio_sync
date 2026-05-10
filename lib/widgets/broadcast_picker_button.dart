import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iOS の `RPSystemBroadcastPickerView` を埋め込むためのウィジェット。
///
/// iOS では Apple の制約により、ブロードキャスト(画面・音声配信)を
/// プログラムから自動開始することはできない。ユーザーが必ずこのボタンを
/// タップして、システムシートから配信先 Extension を選んで開始する必要がある。
///
/// このウィジェットは見た目をアプリのテーマに合わせて整えつつ、
/// 内部に隠した `RPSystemBroadcastPickerView` の小さなボタンに対する
/// クリックを伝搬させる仕組みを取る代わりに、`UiKitView` をそのまま
/// 表示する。`preferredExtension` を指定すると iOS のシートで対象 Extension が
/// 最上段に来るので、ユーザーはほぼ 1 タップで配信を始められる。
///
/// iOS 以外のプラットフォームでは何も表示しない(レイアウト潰さないために
/// `SizedBox.shrink()` を返す)。
class BroadcastPickerButton extends StatelessWidget {
  /// `RPSystemBroadcastPickerView.preferredExtension` に渡すバンドル ID。
  /// 例: `com.example.localAudioSync.BroadcastExtension`
  final String preferredExtensionBundleId;

  /// ボタンの大きさ。`RPSystemBroadcastPickerView` 本体のサイズと一致させる。
  final double size;

  const BroadcastPickerButton({
    super.key,
    required this.preferredExtensionBundleId,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: size,
      height: size,
      child: UiKitView(
        viewType: 'com.example.local_audio_sync/broadcastPicker',
        creationParams: <String, Object?>{
          'preferredExtension': preferredExtensionBundleId,
        },
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          // 親の Scrollable などで握りつぶされないように
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      ),
    );
  }
}
