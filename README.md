# local-audio-sync

ローカルネットワーク（LAN）上の複数デバイスのマイク音声を Windows PC に集約して再生するアプリです。
Android・iPhone・iPad・macOS・Windows の各デバイスがクライアントとして動作し、Opus コーデックで圧縮した音声を UDP で Windows ハブに送信します。

---

## 目次

1. [概要と構成](#概要と構成)
2. [動作要件](#動作要件)
3. [セットアップ手順](#セットアップ手順)
4. [使い方](#使い方)
5. [通信プロトコル詳細](#通信プロトコル詳細)
6. [プロジェクト構造](#プロジェクト構造)
7. [ビルド方法](#ビルド方法)
8. [テスト](#テスト)
9. [CI/CD](#cicd)
10. [トラブルシューティング](#トラブルシューティング)

---

## 概要と構成

```text
[Android / iPhone / iPad / macOS / Windows（クライアント）]
        マイク入力
          ↓
      Opus エンコード（128 kbps / 48 kHz / ステレオ）
          ↓
     UDP ユニキャスト → ポート 7777
          ↓
   [Windows ハブ（このアプリ）]
          ↓
      Opus デコード × クライアント数（最大 16 台）
          ↓
      クライアントごとの音量調整
          ↓
      float32 PCM ミキシング（C++ / miniaudio）
          ↓
      スピーカー出力
```

### ディスカバリー（自動検出）

- Hub が UDP ブロードキャスト（ポート **9999**）でビーコンを 2 秒ごとに送信
- クライアントはビーコンを受信すると自動的に Hub の IP を検出し接続を開始

---

## 動作要件

| プラットフォーム | バージョン要件 |
| --- | --- |
| Windows（Hub） | Windows 10 以降（x64） |
| Windows（Client） | Windows 10 以降（x64） |
| Android | API 24 (Android 7.0) 以降 |
| iOS | iOS 14 以降 |
| macOS | macOS 12 以降 |
| Flutter SDK | 3.24 以降 |
| Dart SDK | 3.5 以降 |

**すべてのデバイスが同一 LAN（Wi-Fi / 有線）に接続している必要があります。**

---

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone <repository-url>
cd local-audio-sync
```

### 2. 依存パッケージのインストール

```bash
flutter pub get
```

### 3. Android のビルド準備

`android/app/src/main/AndroidManifest.xml` に以下のパーミッションが設定済みです：

- `RECORD_AUDIO` — マイク使用
- `FOREGROUND_SERVICE_MICROPHONE` — バックグラウンド録音
- `CHANGE_WIFI_MULTICAST_STATE` — UDP ブロードキャスト受信
- `WAKE_LOCK` — 画面 OFF 時の継続動作

### 4. iOS / macOS の署名設定

iOS でビルドする際は Xcode で開発者アカウントと Provisioning Profile を設定してください。
`Info.plist` には以下が設定済みです：

- `NSMicrophoneUsageDescription` — マイク使用理由の説明
- `UIBackgroundModes: audio` — バックグラウンド音声処理

### 5. Windows のビルド準備（初回のみ）

`windows/audio_mixer_plugin/` ディレクトリに `miniaudio.h` が含まれています。
Visual Studio 2022 Build Tools（C++ ワークロード）が必要です。

Visual Studio Build Tools がない場合はインストールしてください：
<https://visualstudio.microsoft.com/ja/downloads/#build-tools-for-visual-studio-2022>

---

## 使い方

### アプリの起動

```bash
# Windows
flutter run -d windows

# Android（接続済みデバイス）
flutter run -d android

# iOS（接続済みデバイス）
flutter run -d ios
```

### Hub（受信・再生側）の設定

1. アプリを起動し、初期画面で **「Hub」** を選択
2. デバイス名を入力して **「Hub として起動」** をタップ
3. Hub 画面に切り替わり、LAN へのビーコン送信が始まります
4. クライアントが接続すると一覧に表示されます
5. 各クライアントの音量スライダーで個別に音量を調整できます

### Client（送信側）の設定

1. アプリを起動し、初期画面で **「Client」** を選択
2. デバイス名を入力して **「Client として起動」** をタップ
3. Client 画面に切り替わり、LAN 上の Hub を自動検索します
4. Hub が見つかると自動で接続してマイク音声の送信を開始します
5. VU メーターで現在の入力レベルを確認できます
6. **「Stop Broadcasting」** ボタンで送信を停止できます

### ロールの切り替え

画面右上の **「⇄」** アイコンをタップするとロール選択画面に戻ります。
選択したロールは次回起動時も保持されます。

---

## 通信プロトコル詳細

### ビーコン（UDP ブロードキャスト、ポート 9999）

Hub が 2 秒ごとに `255.255.255.255` へ送信するテキストメッセージ：

```text
LAHUB:{hubIPv4}:7777:{hubName}
例: LAHUB:192.168.1.10:7777:MyHub
```

### 音声パケット（UDP ユニキャスト、ポート 7777）

バイナリ形式：

| オフセット | サイズ | 内容 |
| --- | --- | --- |
| 0 | 2 byte | マジックバイト: `0xA1 0xA2` |
| 2 | 2 byte | クライアント ID（uint16、ビッグエンディアン） |
| 4 | 4 byte | シーケンス番号（uint32、ビッグエンディアン） |
| 8 | 可変 | Opus ペイロード（20ms フレーム、約 80〜320 byte） |

### 制御メッセージ（テキスト、ポート 7777）

| メッセージ | 方向 | 形式 | 説明 |
| --- | --- | --- | --- |
| HELLO | Client → Hub | `HELLO:{name}:{uuid}` | 接続開始 |
| ACKHELLO | Hub → Client | `ACKHELLO:{assignedId}` | ID の割り当て通知 |
| PING | Client → Hub | `PING:{clientId}` | 接続維持（5 秒ごと） |
| BYE | Client → Hub | `BYE:{clientId}` | 切断通知 |

### 音声仕様

| 項目 | 値 |
| --- | --- |
| コーデック | Opus |
| サンプルレート | 48,000 Hz |
| チャンネル | 2（ステレオ） |
| ビットレート | 128 kbps |
| フレームサイズ | 20 ms（960 サンプル/チャンネル） |
| ジッターバッファ | 固定遅延方式、最大 5 フレーム（100 ms） |

---

## プロジェクト構造

```text
local-audio-sync/
├── lib/
│   ├── main.dart                      # エントリポイント（Opus 初期化 + ProviderScope）
│   ├── app.dart                       # GoRouter ルーティング定義
│   ├── models/
│   │   ├── app_mode.dart              # enum AppMode { hub, client }
│   │   ├── client_info.dart           # クライアント情報（IP / 音量 / VU レベル等）
│   │   └── audio_packet.dart          # UDP パケットのシリアライズ / デシリアライズ
│   ├── providers/
│   │   ├── app_mode_provider.dart     # ロール選択の状態（SharedPreferences で永続化）
│   │   ├── hub_state_provider.dart    # 接続クライアント一覧 + 音量状態
│   │   └── client_state_provider.dart # 接続状態 / VU レベル
│   ├── services/
│   │   ├── discovery_service.dart     # UDP ビーコン送受信
│   │   ├── audio_capture_service.dart # マイク PCM16 ストリーム取得
│   │   ├── opus_encoder_service.dart  # PCM16 → Opus エンコード
│   │   ├── opus_decoder_service.dart  # Opus → float32 PCM デコード（PLC 対応）
│   │   ├── udp_sender_service.dart    # クライアント: 音声送信 + keepalive
│   │   ├── udp_receiver_service.dart  # Hub: 音声受信・振り分け
│   │   ├── audio_mixer_service.dart   # Hub: FFI 経由で Windows ミキサーを操作
│   │   └── jitter_buffer.dart         # 順序制御付きジッターバッファ
│   ├── screens/
│   │   ├── setup_screen.dart          # ロール選択 + デバイス名入力
│   │   ├── hub_screen.dart            # クライアント一覧 + 音量スライダー
│   │   └── client_screen.dart         # 接続状態 + VU メーター
│   └── widgets/
│       ├── client_tile.dart           # クライアント行ウィジェット
│       ├── vu_meter.dart              # VU メーター（CustomPainter）
│       └── connection_status_badge.dart # 接続状態バッジ
│
├── windows/
│   ├── CMakeLists.txt                 # audio_mixer_plugin をサブディレクトリ追加
│   └── audio_mixer_plugin/
│       ├── CMakeLists.txt             # DLL ビルド設定
│       ├── audio_mixer.h              # FFI 公開 API
│       ├── audio_mixer.cpp            # miniaudio + SPSC リングバッファ実装
│       └── miniaudio.h                # シングルヘッダ オーディオライブラリ
│
├── android/app/src/main/
│   ├── AndroidManifest.xml            # パーミッション宣言
│   └── kotlin/.../
│       ├── MainActivity.kt            # MethodChannel でフォアグラウンドサービス制御
│       └── AudioBroadcastService.kt   # バックグラウンド録音用フォアグラウンドサービス
│
├── ios/Runner/
│   └── Info.plist                     # UIBackgroundModes, マイク使用説明
│
├── macos/Runner/
│   ├── DebugProfile.entitlements      # マイク + ネットワーク権限
│   └── Release.entitlements           # マイク + ネットワーク権限
│
├── test/                              # ユニットテスト（21 件）
│   ├── models/audio_packet_test.dart
│   ├── services/discovery_service_test.dart
│   ├── services/jitter_buffer_test.dart
│   └── providers/hub_state_provider_test.dart
│
├── integration_test/
│   └── hub_client_loopback_test.dart  # 結合テスト（スケルトン）
│
└── .github/workflows/
    ├── ci.yml                         # lint + test（全ブランチ）
    ├── build-android.yml              # APK ビルド
    ├── build-windows.yml              # EXE ビルド
    └── build-ios.yml                  # IPA ビルド（macOS runner）
```

---

## ビルド方法

### Windows（推奨: リリースビルド）

```bash
flutter build windows --release
# 出力: build/windows/x64/runner/Release/
#   local_audio_sync.exe
#   audio_mixer_plugin.dll   ← miniaudio ベースのオーディオミキサー
#   flutter_windows.dll
```

### Android

```bash
flutter build apk --release
# 出力: build/app/outputs/flutter-apk/app-release.apk
```

### iOS（コードサイン不要のビルド確認）

```bash
flutter build ios --release --no-codesign
```

### macOS

```bash
flutter build macos --release
```

---

## テスト

### ユニットテスト

```bash
flutter test
# 21 件すべてパス
```

| テストファイル | 内容 |
| --- | --- |
| `audio_packet_test.dart` | バイナリシリアライズ、マジックバイト検証、シーケンスラップアラウンド |
| `jitter_buffer_test.dart` | 順序制御、パケットロス時の PLC トリガー、古いシーケンスの棄却 |
| `discovery_service_test.dart` | ビーコン文字列パース（正常系・異常系） |
| `hub_state_provider_test.dart` | クライアント追加 / 削除 / 音量変更のステート遷移 |

### 静的解析

```bash
flutter analyze
# No issues found.
```

---

## CI/CD

GitHub Actions で以下のワークフローが設定されています：

| ワークフロー | トリガー | 内容 |
| --- | --- | --- |
| `ci.yml` | 全ブランチの push / PR | `flutter analyze` + `flutter test --coverage` |
| `build-android.yml` | `main` / `develop` push | APK ビルド → Artifacts |
| `build-windows.yml` | `main` / `develop` push | EXE ビルド → Artifacts |
| `build-ios.yml` | `main` / `develop` push | コンパイル確認ビルド（署名なし）→ Artifacts |

### iOS/iPadOS を実機でテストする方法

CI はコンパイル確認のみ行います。実機へのインストールは以下の方法を使ってください。

#### 方法 1 — Mac + USB（最も手軽、無料）

iPhone を USB で Mac に接続し、プロジェクトディレクトリで実行するだけです。
Xcode が自動で開発証明書を作成します（7日間有効）。

```bash
flutter devices          # 接続デバイスを確認
flutter run -d <device-id>
```

#### 方法 2 — AltStore / Sideloadly（Windows / Mac 対応、無料）

CI の Artifacts からダウンロードしたビルドを、無料 Apple ID でサイドロードできます。

| ツール | OS | 特徴 |
| --- | --- | --- |
| [AltStore](https://altstore.io/) | Windows / Mac | PC と同一 Wi-Fi で自動再署名 |
| [Sideloadly](https://sideloadly.io/) | Windows / Mac | USB 接続で簡単インストール |

どちらも 7 日ごとに再署名が必要です（AltStore は自動更新できます）。

### ブランチ戦略

```text
main       ← リリースブランチ（PR 必須、CI 必須）
develop    ← 開発統合ブランチ
feature/*  ← 機能開発
fix/*      ← バグ修正
```

---

## トラブルシューティング

### Hub が見つからない（クライアント側）

- Hub と Client が **同一 Wi-Fi** に接続されているか確認してください
- Windows ファイアウォールで **UDP ポート 9999 および 7777** の受信を許可してください
  - コントロールパネル → Windows Defender ファイアウォール → 受信の規則 → 新しい規則
- Android で UDP ブロードキャストが届かない場合、ルーターの **AP 分離（AP Isolation）** を無効にしてください

### 音声が出ない（Hub 側）

- Windows の既定の再生デバイスが正しく設定されているか確認してください
- タスクマネージャーで `audio_mixer_plugin.dll` がロードされているか確認してください
- Hub 画面のクライアント一覧でクライアントが接続済みになっているか確認してください

### マイクの許可が得られない

#### Android の場合

- 設定 → アプリ → local-audio-sync → 権限 → マイク → 許可

#### iOS の場合

- 設定 → プライバシーとセキュリティ → マイク → local-audio-sync → ON

#### macOS の場合

- システム設定 → プライバシーとセキュリティ → マイク → local-audio-sync → ON

### Android でバックグラウンドに移ると音声が止まる

- フォアグラウンドサービスの通知（「Broadcasting Audio」）が表示されているか確認
- 端末のバッテリー最適化設定で local-audio-sync を **最適化しない** に設定してください
  - 設定 → バッテリー → バッテリーの最適化 → local-audio-sync → 最適化しない

### `flutter build windows` が失敗する

Visual Studio Build Tools（C++ によるデスクトップ開発）が必要です。
<https://visualstudio.microsoft.com/ja/downloads/#build-tools-for-visual-studio-2022>

---

## 依存ライブラリ

| パッケージ | バージョン | 用途 |
| --- | --- | --- |
| `flutter_riverpod` | ^2.6.1 | 状態管理 |
| `go_router` | ^14.6.2 | 画面遷移 |
| `record` | ^6.2.0 | マイク PCM ストリーム取得 |
| `opus_dart` | ^3.0.1 | Opus エンコード / デコード（FFI） |
| `opus_flutter` | ^3.0.1 | Opus ライブラリのロード |
| `permission_handler` | ^11.3.1 | マイク権限リクエスト |
| `network_info_plus` | ^6.0.1 | ローカル IP アドレス取得 |
| `uuid` | ^4.5.1 | クライアント UUID 生成 |
| `shared_preferences` | ^2.3.3 | ロール選択の永続化 |
| `ffi` | ^2.1.0 | C++ DLL へのメモリアクセス |
| `miniaudio.h` | latest | Windows オーディオ出力（C シングルヘッダ） |

---

## ライセンス

MIT License
