import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'models/app_mode.dart';
import 'providers/app_mode_provider.dart';
import 'providers/theme_mode_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/hub_screen.dart';
import 'screens/client_screen.dart';
import 'theme/app_theme.dart';

/// アプリのルート。
///
/// 設定(デバイス名 / テーマ / 役割)の復元は [main] の runApp 前に済ませ、
/// ここでは最初のフレームから本番 UI(MaterialApp.router)を描画する。
/// 以前は `_ready` フラグでスプラッシュ用 MaterialApp → 本番 MaterialApp.router
/// へ**ルート Widget を丸ごと差し替え**ていたが、Windows でこの差し替えが
/// 初回フレームの合成とレースして画面が真っ白になることがあったため廃止した。
class LocalAudioSyncApp extends ConsumerStatefulWidget {
  /// 復元済みの初期役割(null = 未設定 → /setup へ)。
  final AppMode? initialMode;

  const LocalAudioSyncApp({super.key, required this.initialMode});

  @override
  ConsumerState<LocalAudioSyncApp> createState() => _LocalAudioSyncAppState();
}

class _LocalAudioSyncAppState extends ConsumerState<LocalAudioSyncApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = _buildRouter(widget.initialMode);
    // Windows の初回フレーム提示レース対策。負荷が高いと最初のフレームが
    // GPU に提示されず画面が真っ白になることがあるため、起動直後に一度だけ
    // 再描画を促して確実に提示させる(低リスクの保険)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) setState(() {});
      });
    });
  }

  GoRouter _buildRouter(AppMode? initialMode) {
    return GoRouter(
      initialLocation: _initialRoute(initialMode),
      routes: [
        GoRoute(
          path: '/setup',
          builder: (context, _) => const SetupScreen(),
        ),
        GoRoute(
          path: '/hub',
          builder: (context, _) => const HubScreen(),
        ),
        GoRoute(
          path: '/client',
          builder: (context, _) => const ClientScreen(),
        ),
      ],
      redirect: (context, state) {
        final mode = ref.read(appModeProvider);
        if (mode == null && state.fullPath != '/setup') return '/setup';
        return null;
      },
    );
  }

  static String _initialRoute(AppMode? mode) {
    return switch (mode) {
      AppMode.hub => '/hub',
      AppMode.client => '/client',
      null => '/setup',
    };
  }

  // Material/Cupertino の日本語ラベルを有効化するためのデリゲート群。
  static const List<LocalizationsDelegate<dynamic>> _localizationsDelegates = [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  static const List<Locale> _supportedLocales = [
    Locale('ja', 'JP'),
    Locale('en'),
  ];

  @override
  Widget build(BuildContext context) {
    // 役割(appMode)が変わったら go_router の redirect を再評価させる。
    // 設定画面からの「役割を切り替える」で mode を null に reset した際、これが
    // ないと redirect が発火せず /setup(役割選択)へ戻れない。
    ref.listen<AppMode?>(appModeProvider, (_, _) => _router.refresh());
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Local Audio Sync',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // 日本語対応のロケール指定。Material/Cupertino のデフォルト英語ラベルを抑止。
      locale: const Locale('ja', 'JP'),
      localizationsDelegates: _localizationsDelegates,
      supportedLocales: _supportedLocales,
      routerConfig: _router,
    );
  }
}
