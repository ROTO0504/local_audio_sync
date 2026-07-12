import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'app.dart';
import 'models/app_mode.dart';
import 'providers/app_mode_provider.dart';
import 'providers/theme_mode_provider.dart';

Future<DynamicLibrary> _loadOpus() async {
  // opus_flutter は macOS 実装を持たないため、opus_macos pod が
  // プロセスにリンクした opus.framework を直接参照する
  if (Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  return await opus_flutter.load() as DynamicLibrary;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Opus codec (required before creating any encoder/decoder)
  // opus_dart の条件付き export の都合で analyzer は web_ffi 側の
  // DynamicLibrary を解決するが、ネイティブ実行時は dart:ffi の型が実体。
  // ignore: argument_type_not_assignable
  initOpus(await _loadOpus());

  // 設定(デバイス名 / テーマ / 役割)は runApp の前に復元しておく。
  // こうすることで最初のフレームから本番 UI を描画でき、スプラッシュ用
  // MaterialApp → 本番 MaterialApp へのルート Widget 差し替えを避けられる
  // (Windows の初回フレーム白画面レース対策)。
  final container = ProviderContainer();
  await container.read(deviceNameProvider.notifier).restoreName();
  await container.read(themeModeProvider.notifier).restore();
  final AppMode? mode =
      await container.read(appModeProvider.notifier).restoreMode();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: LocalAudioSyncApp(initialMode: mode),
    ),
  );
}
