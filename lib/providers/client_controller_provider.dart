import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/client_controller.dart';

/// [ClientController] のシングルトン Provider。
/// 画面側は `ref.read(clientControllerProvider)` で取得して start / stop を呼ぶ。
final clientControllerProvider = Provider<ClientController>((ref) {
  final controller = ClientController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});
