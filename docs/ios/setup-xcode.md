# iOS Broadcast Upload Extension セットアップ手順

> このドキュメントは、Xcode で **Broadcast Upload Extension** ターゲットを `local-audio-sync` プロジェクトに追加するための手順書です。
> ソースファイル(`ios/BroadcastExtension/SampleHandler.swift` など)は既に用意されているので、Xcode 側で「ターゲットの作成」と「既存ファイルの組み込み」を行うだけです。

## 前提

- macOS + Xcode 15 以上
- Apple Developer アカウント(無料の Apple ID で OK、ただし 7 日ごとに再署名が必要)
- このリポジトリを `flutter pub get` 済みであること

## 1. Xcode を開く

```bash
open ios/Runner.xcworkspace
```

> **重要**: `Runner.xcodeproj` ではなく `Runner.xcworkspace` を開いてください(CocoaPods が必要)。

## 2. Broadcast Upload Extension ターゲットを追加

1. 左ペインのプロジェクトナビゲータで **Runner** プロジェクト(青いアイコン)を選択。
2. 中央エディタの左下にある **「+」(Add Target)** ボタンを押す。
3. テンプレート選択ダイアログで **iOS** タブの **「Broadcast Upload Extension」** を選択し **Next**。
4. オプション入力:
   - **Product Name**: `BroadcastExtension`
   - **Team**: 自分の Apple Developer Team
   - **Organization Identifier**: `com.roto0504.localAudioSync`(あるいは独自のドメイン)
   - **Bundle Identifier**: 自動で `com.roto0504.localAudioSync.BroadcastExtension` になる
   - **Language**: Swift
   - **Project**: Runner
   - **Embed in Application**: Runner
   - **Include UI Extension**: **チェックを外す**(音声配信のみで UI Extension は不要)
5. **Finish** をクリック。
6. 「Activate "BroadcastExtension" scheme?」と聞かれたら **Cancel**(Runner スキームを使い続ける)。

## 3. 自動生成された SampleHandler.swift を、リポジトリ提供のものに差し替える

Xcode が自動で `BroadcastExtension/SampleHandler.swift` を生成しますが、この内容は使わず、リポジトリ既存の実装に差し替えます。

1. Finder で `ios/BroadcastExtension/` フォルダを開き、自動生成された `SampleHandler.swift` を、リポジトリの同名ファイル(`ios/BroadcastExtension/SampleHandler.swift`)に **上書き** します。
   - リポジトリには `Info.plist` と `BroadcastExtension.entitlements` も既に存在するので、Xcode が生成した同名ファイルが衝突する場合は **リポジトリ側を残す**(Xcode で "Replace" を選択)。
2. Xcode に戻り、`SampleHandler.swift` を開いて内容が `@objc(SampleHandler) class SampleHandler: RPBroadcastSampleHandler` で始まっていれば差し替え成功。

## 4. App Group を有効化

Extension とメインアプリの両方で同じ App Group を有効化します。

### Runner ターゲット側

1. プロジェクトナビゲータで Runner プロジェクトを選択。
2. **TARGETS** から **Runner** を選択。
3. **Signing & Capabilities** タブを開く。
4. 左上の **「+ Capability」** をクリックし、**App Groups** を追加。
5. **「+」** ボタンで新規 App Group を作成、ID は `group.com.roto0504.localAudioSync` を入力(チェックを入れる)。
6. **Code Signing Entitlements** が `Runner/Runner.entitlements` を指していることを確認(リポジトリ既存のファイル)。

### BroadcastExtension ターゲット側

1. **TARGETS** から **BroadcastExtension** を選択。
2. **Signing & Capabilities** タブを開く。
3. 同じく **「+ Capability」** → **App Groups**。
4. 既に作成した `group.com.roto0504.localAudioSync` に **チェック** を入れる。
5. **Code Signing Entitlements** が `BroadcastExtension/BroadcastExtension.entitlements` を指していることを確認。

> App Group が両ターゲットで一致していないと、UNIX Domain Socket でのメインアプリ ↔ Extension 通信が確立せず、音声が届きません。

## 5. Extension の Info.plist を上書き

Xcode が自動生成した `BroadcastExtension/Info.plist` を、リポジトリ提供のものに置き換えます(差分は `CFBundleDisplayName` を日本語化している程度ですが、念のため統一)。

- **置換元**: `ios/BroadcastExtension/Info.plist`(リポジトリの内容)
- **置換先**: Xcode が生成した同パスのファイル

## 6. メインアプリに Bundle ID を伝える(オプションだが推奨)

メインアプリ(Runner)の `pubspec.yaml` から渡したい場合は、`ios/Runner/Info.plist` に以下のキーを追加するなどして、Dart 側の `client_screen.dart` で `preferredExtension` を取得できるようにします(現状は Dart 側で文字列リテラル指定でも可)。

```xml
<key>BroadcastExtensionBundleId</key>
<string>com.roto0504.localAudioSync.BroadcastExtension</string>
```

## 7. ビルドして確認

1. Runner スキームを選択。
2. デバイス選択を実機(Apple ID で署名された iPhone / iPad)にする。
3. **Cmd + R** でビルド & 実行。
4. アプリの画面に **「ブロードキャスト開始」** ボタンが表示されたら、それをタップ。
5. iOS のシステムシートで **「Local Audio Sync 配信」**(BroadcastExtension の表示名)を選択し、**「ブロードキャストを開始」**。
6. アプリは Hub に音声を流し始める。Spotify などで音楽を再生すると Hub の方で聴こえれば成功。

## トラブルシューティング

### ボタンを押しても何も起きない / Picker に Extension が出ない

- App Group 設定が両ターゲットで一致しているか再確認。
- Extension の bundle ID が `pubspec.yaml` / Dart 側コードで指定している `preferredExtension` と一致しているか確認。
- 一度アプリを削除してから再インストール(古い App Group 設定が残ることがある)。

### `App Group コンテナが取得できません` エラー

- `Runner/Runner.entitlements` と `BroadcastExtension/BroadcastExtension.entitlements` の `com.apple.security.application-groups` の値が同一かを確認。
- 実機の Apple ID が、その App Group ID を使う権限を持っているか確認(Personal Team でも作成可能)。

### Extension が起動した直後にクラッシュする

- メモリ 50MB 制限を超えていないか。本実装では Opus エンコードなどはメインアプリ側で行うため、通常は問題なし。
- Xcode の Console でログを確認(`[BroadcastExtension]` プレフィックス付きで NSLog 出力)。

### DRM コンテンツが配信されない

- Apple Music、Netflix、Amazon Prime Video などは iOS の仕様で配信されません(画面ブロードキャストでも音声が消える)。これは取得不可です。

### 配信中にアプリを閉じると配信が止まる

- iOS の仕様で、メインアプリがバックグラウンドに移っても Extension は別プロセスとして動き続けます。ただし、メインアプリが完全に終了(スワイプして閉じる)すると、UDP 送信用のメインアプリが消えるため Hub に届かなくなります。**メインアプリは起動したまま** にしてください。
