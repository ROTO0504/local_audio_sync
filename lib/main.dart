import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Opus codec (required before creating any encoder/decoder)
  initOpus(await opus_flutter.load());

  runApp(
    const ProviderScope(
      child: LocalAudioSyncApp(),
    ),
  );
}
