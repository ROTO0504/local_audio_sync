import 'dart:ffi';
import 'dart:io';

/// audio_mixer ネイティブライブラリを OS に応じてロードする。
///
/// - Windows: `audio_mixer_plugin.dll`(Runner と同じディレクトリに出力される)
/// - Android: `libaudio_mixer_plugin.so`(APK に同梱される)
/// - iOS / macOS: CocoaPods がビルドする `audio_mixer_ffi` framework。
///   静的リンク構成ではプロセス本体から解決する。
///
/// ロードに失敗した場合は例外がそのまま伝播する。呼び出し側で捕捉して
/// 「ミキサーなし(無音)」のフォールバックに落とすこと。
DynamicLibrary openAudioMixerLibrary() {
  if (Platform.isWindows) {
    return DynamicLibrary.open('audio_mixer_plugin.dll');
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libaudio_mixer_plugin.so');
  }
  if (Platform.isIOS || Platform.isMacOS) {
    try {
      return DynamicLibrary.open('audio_mixer_ffi.framework/audio_mixer_ffi');
    } catch (_) {
      // use_frameworks! なしの静的リンク構成ではプロセスに含まれている。
      return DynamicLibrary.process();
    }
  }
  throw UnsupportedError(
    'audio_mixer はこのプラットフォーム(${Platform.operatingSystem})に対応していません',
  );
}
