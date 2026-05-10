# local-audio-sync リアーキテクチャ計画

> 作成日: 2026-05-10
> ブランチ: `claude/blissful-banzai-64e124`
> ステータス: 実行中

## 1. 背景と目的

本プロジェクトは LAN 内の複数デバイス(iPhone / iPad / macOS / Windows / Android)から音声を WiFi 経由で 1 台の **Hub**(現状 Windows)に集約し、まとめて再生するアプリです。

ユーザーから報告された主な不具合:

1. **iPhone / iPad で「内部音声(他アプリの音)」が取れない** — Spotify や YouTube の音をキャプチャしたいが、現状の実装では拾えない。
2. **iPad がすぐクラッシュする**。
3. **収録開始後に同期が外れる、アプリ再起動しないと直らない**。

これらは旧アーキテクチャ(マイク前提 + 自前 UDP/Opus + 手作りジッターバッファ)の根深い問題に起因しており、今回のリアーキテクチャで根治します。

## 2. 要件(2026-05-10 確定)

| 項目 | 内容 |
| --- | --- |
| 音源モード | **内部音声のみ**(マイクは廃止) |
| 対応 OS | Windows / macOS / iOS / iPadOS(リリース必須)、Android(動作維持) |
| Hub | Windows |
| DRM コンテンツ | 取れなくて許容(Apple Music / Netflix 等) |
| iOS Broadcast Picker UX | 許容(ユーザー手動で開始) |
| 通信路 | LAN 限定、WAN は対象外 |
| ネットワーク方式 | 既存の Opus + 自前 UDP を継続(WebRTC は採用しない) |

### WebRTC を採用しない理由

- 内部音声に WebRTC の Audio Track を流すと AEC / NS / AGC が音楽を歪める。flutter_webrtc では完全無効化が困難。
- LAN 内なら Opus 128kbps + 軽量ジッターバッファで音質は十分。
- 既存資産(Opus エンコーダ、UDP プロトコル、miniaudio ミキサー)をそのまま活用できる。
- マイクが廃止されたため、WebRTC のマイク向け機能(エコーキャンセル等)は不要。

## 3. アーキテクチャ全景

```text
┌──────────────────────────────────────────────────────────────────┐
│  Client(送信側)                                                 │
│                                                                  │
│  [OS 別の内部音声キャプチャ]                                      │
│   - iOS/iPadOS: Broadcast Upload Extension(別プロセス)          │
│       └ App Group 共有ソケット → メインアプリへ PCM IPC          │
│   - Android: MediaProjection + AudioPlaybackCaptureConfiguration │
│   - macOS: ScreenCaptureKit(SCStream + capturesAudio)            │
│   - Windows: WASAPI loopback                                      │
│                                                                  │
│  ↓ PCM16 / 48kHz / stereo / 20ms フレーム(3840 byte)             │
│  Opus エンコード(128kbps)                                        │
│  ↓                                                               │
│  UDP ユニキャスト(ポート 7777)                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  Hub(Windows、現状維持)                                         │
│                                                                  │
│  UDP 受信 → クライアントごとのジッターバッファ                    │
│  → Opus デコード → float32 PCM                                    │
│  → 個別音量調整                                                   │
│  → miniaudio ミキサー(C++ FFI)                                  │
│  → スピーカー出力                                                 │
└──────────────────────────────────────────────────────────────────┘
```

### 自動検出は据え置き

```text
Hub → UDP ブロードキャスト(ポート 9999)で 2 秒ごとにビーコン
Client → ビーコン受信 → 自動接続
```

ただし以下を追加:

- Client 側: **Hub 喪失タイムアウト**(6 秒未受信で再探索)
- Client 側: 接続中も Hub IP を監視、変更時は自動再接続
- 双方: ソケット例外時の自動再生成

## 4. 既存技術スタック(維持するもの)

| レイヤ | 技術 | 役割 |
| --- | --- | --- |
| Flutter UI | Flutter 3.24+ / Dart 3.5+ | クロスプラットフォーム UI |
| 状態管理 | flutter_riverpod 2.6 | プロバイダパターン |
| 画面遷移 | go_router 14.6 | ルーティング |
| 永続化 | shared_preferences 2.3 | ロール・デバイス名保存 |
| 音声コーデック | Opus(opus_dart 3.0 / opus_flutter 3.0) | エンコード / デコード |
| ローカル IP | network_info_plus 6.0 | LAN IP 取得 |
| FFI | ffi 2.1 | C++ ミキサー連携 |
| Windows ミキサー | miniaudio.h(シングルヘッダ C ライブラリ) | フロート PCM ミックス + 出力 |
| Android 内部音声 | MediaProjection + AudioPlaybackCaptureConfiguration | 既実装、API 29+ |

## 5. 新規 / 変更点

| レイヤ | 旧 | 新 |
| --- | --- | --- |
| iOS 音声取得 | `RPScreenRecorder`(自アプリ内のみ) | **Broadcast Upload Extension**(デバイス全体) |
| iOS IPC | なし(プラグイン直接) | **App Group + UNIX Domain Socket** |
| iOS Picker UX | なし | **`RPSystemBroadcastPickerView`** ボタン |
| macOS 音声取得 | `record` パッケージのマイク | **ScreenCaptureKit + SCStream** |
| Windows Client 音声取得 | `record` パッケージのマイク | **WASAPI loopback** |
| マイク経路 | 全プラットフォーム | **削除** |
| `AudioCaptureService` | マイクキャプチャ | **削除** |
| `audio_capture_service.dart` の RMS 計算 | サービス内 | 共通ユーティリティへ移動 |
| AVAudioSession | AppDelegate と Plugin で二重設定 | **`AudioSessionManager`(Swift) で一元化** |
| JitterBuffer | reset で sender seq とリンクしない | **再同期トークン**で送信側と協調 |
| DiscoveryService | タイムアウトなし | **6 秒タイムアウト + 再探索ループ** |
| UdpSender | 例外時にソケット死亡 | **再生成 + 指数バックオフ** |
| UdpReceiver | 例外時にソケット死亡 | **再バインド** |

## 6. フェーズ別実装計画

### フェーズ 1: iOS / iPadOS 内部音声キャプチャ(Broadcast Upload Extension)

**目的**: iPhone / iPad で他アプリ(Spotify、YouTube 等)の音を取れるようにする。

**サブタスク**:

1. Xcode プロジェクトに **Broadcast Upload Extension ターゲット** を追加(`BroadcastExtension/` ディレクトリ、`Info.plist`、`SampleHandler.swift`)。
2. **App Group**(`group.com.example.local_audio_sync`)を有効化、メインアプリと共有。
3. `SampleHandler.swift` で `processSampleBuffer(_:with: .audioApp)` を実装。Float32 → PCM16 変換、UNIX Domain Socket でメインアプリへ転送。
4. メインアプリ側に **`BroadcastReceiverService`(Swift)** を追加。App Group コンテナ内のソケットを listen し、PCM を Flutter に EventChannel で渡す。
5. Dart 側 `screen_audio_capture_service.dart` を新方式に対応(既存インターフェース維持)。
6. `client_screen.dart` に **`RPSystemBroadcastPickerView` ボタン**(日本語ラベル「ブロードキャスト開始」)を追加。
7. ユニットテスト追加(Dart 側): PCM チャンク化ロジックの再検証。

**コミット境界**:
- :sparkles: `Broadcast Upload Extension のターゲット骨格と App Group を追加`
- :sparkles: `SampleHandler に PCM 変換と App Group ソケット送信を実装`
- :sparkles: `メインアプリに BroadcastReceiverService を追加し EventChannel に接続`
- :sparkles: `client_screen に BroadcastPicker ボタンを追加(日本語UI)`
- :white_check_mark: `Broadcast 経路のチャンク化テストを追加`

### フェーズ 2: 既存安定性問題の根治

**目的**: iPad クラッシュ・同期外れ・接続喪失を直す。

**サブタスク**:

1. **`AudioSessionManager`(Swift)** クラスを新設し、`setCategory` / `setActive` を一元化。AppDelegate / Plugin / Extension すべてここを通す。
2. **`silentPlayer`** を `AudioSessionManager` 配下に移動、生存管理を明示化。アプリ終了時の解放も保証。
3. `JitterBuffer` に **`onResyncRequired` コールバック** を追加。受信側でシーケンス断絶を検出したら、送信側に `RESYNC` 制御メッセージを送って seq を初期化させる。
4. `ClientDiscoveryListener` に **6 秒タイムアウト** を実装。タイムアウトしたら `setSearching()` 状態へ戻し再探索する。
5. `UdpSenderService` / `UdpReceiverService` に **ソケット再生成** と **指数バックオフ再接続** を実装。
6. ユニットテスト追加: 再同期ロジック、Hub タイムアウト、UDP 再接続。

**コミット境界**:
- :recycle: `AudioSessionManager で AVAudioSession の二重設定を解消`
- :bug: `iPad クラッシュ防止: silentPlayer の生存管理を修正`
- :sparkles: `JitterBuffer に再同期トークンを導入し送信側 seq とリンク`
- :sparkles: `Discovery に Hub 喪失タイムアウトと再探索ループを追加`
- :sparkles: `UDP ソケットの再生成と指数バックオフ再接続を追加`
- :white_check_mark: `安定性修正のユニットテストを追加`

### フェーズ 3: macOS 内部音声(ScreenCaptureKit)

**目的**: MacBook の音(Spotify 等)を Hub に送れるようにする。

**サブタスク**:

1. macOS 13.0+ をデプロイメントターゲットに設定確認。
2. `macos/Runner/ScreenAudioPlugin.swift` を新規実装。`SCStream` を使い `SCStreamConfiguration.capturesAudio = true` で内部音声取得。
3. CMSampleBuffer → PCM16 変換(iOS と共通化可能なら共通化)。
4. EventChannel(`com.example.local_audio_sync/screenAudio`)に PCM を流す。
5. `Release.entitlements` / `DebugProfile.entitlements` に必要な権限(`com.apple.security.device.audio-input`、画面録画許可)を追加。
6. ユニットテスト: PCM チャンク化のクロスプラットフォーム共通テスト。

**コミット境界**:
- :sparkles: `macOS で ScreenCaptureKit ベースの内部音声キャプチャを実装`
- :white_check_mark: `macOS キャプチャの単体テストを追加`

### フェーズ 4: Windows クライアント内部音声(WASAPI loopback)

**目的**: Windows もクライアントになれるようにする(現状は Hub のみ)。

**サブタスク**:

1. `windows/audio_mixer_plugin/` 配下に **`audio_loopback.cpp`** を追加(またはサブディレクトリ分割)。miniaudio の loopback デバイスモード(`ma_device_type_loopback`)を使用。
2. FFI で Dart に PCM ストリームを公開(コールバックベース)。
3. `screen_audio_capture_service.dart` に Windows 分岐を追加。
4. ユニットテスト。

**コミット境界**:
- :sparkles: `Windows クライアントで WASAPI loopback による内部音声キャプチャを実装`
- :white_check_mark: `Windows 内部音声キャプチャのテストを追加`

### フェーズ 5: UI 整理 + README 更新

**サブタスク**:

1. `client_screen.dart` から SegmentedButton(マイク / 画面の音 切替)を削除し、内部音声経路に一本化。
2. `audio_capture_service.dart` 削除、参照箇所を整理。
3. UI を全面的に日本語化(現状は英語混在)。エラーメッセージ・ボタン・ステータス全部。
4. README を全面書き直し:新アーキテクチャ、新セットアップ手順、内部音声キャプチャの注意事項(DRM 不可等)、トラブルシューティング更新。

**コミット境界**:
- :fire: `マイク関連のサービスと UI を削除`
- :globe_with_meridians: `UI を全面的に日本語化`
- :memo: `README を新アーキテクチャに合わせて全面更新`

### フェーズ 6: GitHub Actions 調整

**サブタスク**:

1. `build-ios.yml` に Broadcast Extension ターゲットのビルドを追加。Provisioning Profile 不要のコンパイル確認のみ(`--no-codesign`)。
2. `build-macos.yml` を新設(現状なし)。ScreenCaptureKit 用の macOS 13+ runner を指定。
3. `build-windows.yml` で audio_loopback 含む新コードがビルドされることを確認。
4. `ci.yml` で `flutter test` が新テストを含めて全て通ることを確認。

**コミット境界**:
- :construction_worker: `GitHub Actions に Broadcast Extension と macOS ビルドを追加`

### フェーズ 7: 最終ビルド検証

- ローカルで Windows ビルド検証(`flutter build windows --release`)
- ローカルで Android ビルド検証(可能なら)
- iOS / macOS は CI 経由でコンパイル確認
- 動作テストはユーザーに依頼(実機が必要なため)

## 7. コミット規約

| 絵文字 | 用途 |
| --- | --- |
| `:sparkles:` ✨ | 新機能 |
| `:bug:` 🐛 | バグ修正 |
| `:recycle:` ♻️ | リファクタリング |
| `:fire:` 🔥 | コード削除 |
| `:memo:` 📝 | ドキュメント |
| `:white_check_mark:` ✅ | テスト追加 |
| `:construction_worker:` 👷 | CI / ビルド |
| `:globe_with_meridians:` 🌐 | 国際化 / 翻訳 |
| `:lipstick:` 💄 | UI / スタイル |

メッセージは日本語、1 行目は 50 字目安、本文は必要に応じて。

## 8. テスト方針

- **ユニットテスト**(`test/`): フェーズ毎にテスト追加。
  - PCM チャンク化(共通ユーティリティ)
  - JitterBuffer 再同期
  - Discovery タイムアウト / 再探索状態遷移
  - UDP 再接続トリガ条件
- **ネイティブ層**: 当面はビルド通過確認のみ(実機テストはユーザー依頼)。
- **静的解析**: `flutter analyze` の警告ゼロを維持。

## 9. リスクと軽減策

| リスク | 軽減策 |
| --- | --- |
| Broadcast Extension の 50MB メモリ制限超過 | Extension 内では PCM 変換と転送のみ。Opus エンコード等はメインアプリで実施。 |
| App Group 設定漏れによる IPC 不通 | 起動時にコンテナ書き込みテストを行いログ出力。 |
| ScreenCaptureKit の権限 UI 待ち | 初回起動時に明示的に「画面録画権限」案内を出す。 |
| Windows loopback デバイスが見つからない | `ma_context_get_devices` で列挙してフォールバック。 |
| Hub IP の変更追従ミス | Discovery タイムアウト + IP 不一致検出時の強制再接続。 |
| iOS 実機テストが CI 不可能 | 開発者の実機テストを README に明記、AltStore / Sideloadly フローを残す。 |

## 10. 進行ルール

- 各フェーズ完了時にコミット(粒度はサブタスクごとを基本に、論理的に近接するものはまとめる)。
- README は変更があれば毎回更新。
- 静的解析と既存テストが通ることを各コミット前に確認(`flutter analyze` + `flutter test`)。
- ユニットテストは新コード追加と同じコミット、または直後のコミット。
