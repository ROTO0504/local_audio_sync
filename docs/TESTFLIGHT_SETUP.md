# TestFlight 配信セットアップ(iOS / macOS)

GitHub Actions(`.github/workflows/testflight.yml`)から署名付きビルドを
App Store Connect(TestFlight)へアップロードするための手順書です。

証明書と Provisioning Profile は Xcode の **cloud signing**
(`-allowProvisioningUpdates` + App Store Connect API キー)に任せるため、
ローカルで証明書を書き出して Secrets に登録する作業は不要です。

> Bundle ID は `com.roto0504.localAudioSync`、
> App Group は `group.com.roto0504.localAudioSync` に統一済み
> (旧 `com.example.*` は App Store Connect に登録できないため変更した)。

---

## 1. 事前準備(Apple 側、初回のみ)

### 1-1. App Store Connect API キーの発行

1. [App Store Connect](https://appstoreconnect.apple.com/) → **ユーザとアクセス** → **統合** タブ → **App Store Connect API**
2. **チームキー** で「+」→ 名前は任意(例: `github-actions`)、アクセス権は **App Manager**
3. 生成された **AuthKey_XXXXXXXXXX.p8 をダウンロード**(1 回しかダウンロードできない。安全な場所に保管)
4. 画面に表示される **Key ID** と **Issuer ID** を控える

### 1-2. Identifier と App Group の登録

[Apple Developer](https://developer.apple.com/account/resources/identifiers/list) → Certificates, Identifiers & Profiles:

1. **Identifiers → 「+」→ App IDs → App** で以下を登録:
   - `com.roto0504.localAudioSync`(メインアプリ)
     - Capabilities: **App Groups** にチェック
   - `com.roto0504.localAudioSync.BroadcastExtension`(iOS の配信 Extension を入れる場合)
     - Capabilities: **App Groups** にチェック
2. **Identifiers → 種類を App Groups に切替 → 「+」** で
   `group.com.roto0504.localAudioSync` を作成
3. 1 で作った各 App ID の App Groups 設定を Edit/Configure し、
   作成した App Group を割り当てる

> cloud signing は App ID 自体の自動登録もある程度やってくれますが、
> **App Group の作成と紐付けは手動でやっておくのが確実**です。

### 1-3. App Store Connect でアプリを作成

1. App Store Connect → **マイ App** → 「+」→ **新規 App**
2. プラットフォーム: **iOS と macOS の両方にチェック**(1 レコードで両対応)
3. 名前: 任意(例: Local Audio Sync)※ ストア上でユニークである必要あり
4. プライマリ言語: 日本語、Bundle ID: `com.roto0504.localAudioSync`、SKU: 任意(例: `local-audio-sync`)

## 2. GitHub Secrets の登録

リポジトリの **Settings → Secrets and variables → Actions → New repository secret** で 4 つ登録:

| Secret 名 | 値 |
| --- | --- |
| `ASC_KEY_ID` | 1-1 の Key ID(例: `A1B2C3D4E5`) |
| `ASC_ISSUER_ID` | 1-1 の Issuer ID(UUID 形式) |
| `ASC_KEY_P8` | ダウンロードした .p8 ファイルの**中身をテキストのまま**貼り付け(`-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` まで全部) |
| `APPLE_TEAM_ID` | Team ID(10 桁英数。developer.apple.com → Membership で確認) |

## 3. iOS の Broadcast Upload Extension について(重要)

現状、Extension は Xcode プロジェクトに**手動追加する構成**のため、
CI がビルドする IPA には含まれていません。つまり:

- **Extension なしの TestFlight ビルド** → Hub(集約・再生)としては完全動作。
  クライアント(送信)は接続はできるが「配信開始」ができない
- **クライアント配信も TestFlight で試したい場合** → Mac で 1 回だけ
  [docs/iOS_BROADCAST_SETUP.md](iOS_BROADCAST_SETUP.md) の手順で
  Extension ターゲットを追加し、`ios/Runner.xcodeproj` の変更を**コミット**する。
  以後は同じワークフローで Extension も署名・同梱される
  - ターゲット追加時の Bundle ID: `com.roto0504.localAudioSync.BroadcastExtension`
  - App Group: `group.com.roto0504.localAudioSync`
  - Signing は **Automatically manage signing** を選ぶこと(cloud signing の前提)

## 4. 配信の実行

1. GitHub → **Actions** タブ → **TestFlight** ワークフロー → **Run workflow**
2. `platform` を選ぶ(`both` / `ios` / `macos`)→ **Run workflow**
3. 15〜30 分ほどでアップロードまで完了。その後 App Store Connect 側の
   処理(数分〜1 時間)が終わると TestFlight に現れる

ビルド番号は GitHub Actions の Run 番号で自動採番されます(重複しない)。

## 5. 実機へのインストール

1. App Store Connect → 対象 App → **TestFlight** タブ
2. **内部テスト** → 「+」でグループ作成(例: `internal`)→ 自分の Apple ID をテスターに追加
3. ビルドの処理が終わったらグループにビルドを割り当て
4. 端末側:
   - **iPhone / iPad**: App Store から **TestFlight** アプリを入れ、招待メールまたは TestFlight アプリ内からインストール
   - **Mac**: macOS 12 以降の **TestFlight** アプリ(App Store から入手)で同様にインストール

> 内部テスター(App Store Connect のユーザー)への配信は **Apple の審査なし**で即配信されます。

## 6. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| `No profiles for 'com.roto0504.localAudioSync' were found` | 1-2 の App ID 登録と App Group 紐付けを確認。cloud signing の初回はプロファイル生成に失敗することがあるので再実行も試す |
| macOS のアーカイブ/検証で entitlement エラー | `macos/Runner/Release.entitlements` の `com.apple.security.screen-recording` は正式な entitlement ではないため弾かれる可能性がある。その場合はこのキーを削除して再実行(ScreenCaptureKit は実行時の TCC 許可で動くため削除しても機能は失われない) |
| `The bundle version must be higher than the previously uploaded version` | 同じ Run 番号で再実行した場合に起きる。ワークフローを新規実行(Run 番号が進む)すれば解消 |
| アップロードは成功したが TestFlight に出ない | App Store Connect 側の処理待ち(最大 1 時間程度)。「輸出コンプライアンス」の質問が出た場合は Info.plist の `ITSAppUsesNonExemptEncryption=false` が効いているか確認 |
| iOS 実機で「配信開始」ボタンが反応しない | Extension が同梱されていない(§3 参照)。Hub 用途なら問題なし |
