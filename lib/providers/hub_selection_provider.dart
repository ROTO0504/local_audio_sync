import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hub のテーブルで複数選択中のクライアント uuid 集合を保持する。
///
/// 一括操作(pauseSelected / muteSelected 等)の対象を UI から HubController へ
/// 渡すための単一ソース。状態はイミュータブルに新しい Set で置き換える。
class HubSelectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  /// uuid の選択をトグルする(あれば除去、なければ追加)。
  void toggle(String uuid) {
    final next = Set<String>.from(state);
    if (!next.remove(uuid)) {
      next.add(uuid);
    }
    state = next;
  }

  /// 指定 uuid 群をすべて選択状態にする。
  void selectAll(Iterable<String> uuids) {
    state = uuids.toSet();
  }

  /// 選択をすべて解除する。
  void clear() {
    state = {};
  }

  bool isSelected(String uuid) => state.contains(uuid);
}

final hubSelectionProvider =
    NotifierProvider<HubSelectionNotifier, Set<String>>(
  HubSelectionNotifier.new,
);
