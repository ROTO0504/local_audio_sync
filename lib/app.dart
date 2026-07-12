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

class LocalAudioSyncApp extends ConsumerStatefulWidget {
  const LocalAudioSyncApp({super.key});

  @override
  ConsumerState<LocalAudioSyncApp> createState() => _LocalAudioSyncAppState();
}

class _LocalAudioSyncAppState extends ConsumerState<LocalAudioSyncApp> {
  late final GoRouter _router;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Restore persisted settings before routing
    await ref.read(deviceNameProvider.notifier).restoreName();
    await ref.read(themeModeProvider.notifier).restore();
    final mode = await ref.read(appModeProvider.notifier).restoreMode();
    _router = _buildRouter(mode);
    if (mounted) setState(() => _ready = true);
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
    if (!_ready) {
      return MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        localizationsDelegates: _localizationsDelegates,
        supportedLocales: _supportedLocales,
        locale: const Locale('ja', 'JP'),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

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
