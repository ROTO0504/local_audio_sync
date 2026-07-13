import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iOS の配信(Broadcast Upload Extension)を開始するためのボタン。
///
/// iOS では Apple の制約により、ブロードキャストをプログラムから完全自動で
/// 開始することはできず、`RPSystemBroadcastPickerView` 由来のシステムシートを
/// ユーザー操作で開く必要がある。
///
/// 以前は `RPSystemBroadcastPickerView` を `UiKitView` として埋め込んでいたが、
/// iOS 18/26 では内部の UIButton が描画されない・タップが伝搬しないことがあり、
/// 「ボタンが押せない/テキストしか無い」状態になっていた。
///
/// そこで本ウィジェットは **通常の Flutter ボタン** として描画し、タップ時に
/// MethodChannel 経由でネイティブ側([BroadcastPickerController])に配信シートを
/// プログラム起動させる。描画とタップ判定は完全に Flutter 側で行うため確実に動く。
///
/// iOS 以外では何も表示しない(`SizedBox.shrink()`)。
class BroadcastPickerButton extends StatelessWidget {
  /// `RPSystemBroadcastPickerView.preferredExtension` に渡すバンドル ID。
  /// 例: `com.roto0504.localAudioSync.BroadcastExtension`
  final String preferredExtensionBundleId;

  /// 現在ブロードキャスト中かどうか。ラベルの出し分けに使う。
  final bool broadcasting;

  const BroadcastPickerButton({
    super.key,
    required this.preferredExtensionBundleId,
    this.broadcasting = false,
  });

  static const MethodChannel _channel =
      MethodChannel('com.example.local_audio_sync/broadcastControl');

  Future<void> _presentPicker() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('presentBroadcastPicker', {
        'preferredExtension': preferredExtensionBundleId,
      });
    } on PlatformException {
      // シートを開けなくても致命的ではないので握りつぶす。
      // (再タップで再試行できる)
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const SizedBox.shrink();
    }

    return FilledButton.icon(
      icon: const Icon(Icons.cell_tower),
      label: Text(
        broadcasting ? 'ブロードキャストを管理' : 'タップして配信を開始',
      ),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
      ),
      onPressed: _presentPicker,
    );
  }
}
