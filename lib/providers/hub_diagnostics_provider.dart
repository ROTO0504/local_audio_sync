import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_diagnostics.dart';

/// uuid → 接続品質診断のマップを保持する。
///
/// HubController が 1 秒周期でミキサー統計を集約し [setAll] で丸ごと差し替える。
/// UI(診断チップ・ダッシュボード)はこの provider を watch して描画する。
class HubDiagnosticsNotifier extends Notifier<Map<String, ClientDiagnostics>> {
  @override
  Map<String, ClientDiagnostics> build() => {};

  void setAll(Map<String, ClientDiagnostics> m) {
    state = m;
  }
}

final hubDiagnosticsProvider =
    NotifierProvider<HubDiagnosticsNotifier, Map<String, ClientDiagnostics>>(
  HubDiagnosticsNotifier.new,
);
