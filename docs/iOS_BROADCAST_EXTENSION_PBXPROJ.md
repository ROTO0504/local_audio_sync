# iOS Broadcast Extension を Xcode を使わず pbxproj へ追加する

> Windows など Mac/Xcode が手元に無い環境から、Broadcast Upload Extension
> (や任意の app-extension)ターゲットを `Runner.xcodeproj` へ**プログラム的に**
> 追加する手順。手書きの pbxproj 編集は破損リスクが高いため、公式ツール
> **`xcodeproj` gem**(CocoaPods も内部で使う)を macOS CI 上で実行し、
> 「署名なしビルドが通ったものだけ」を採用する安全ゲート付き PDCA で行う。

## 背景 / 症状

`ios/BroadcastExtension/`(`SampleHandler.swift` / `Info.plist` /
`*.entitlements`)を用意しても、**Xcode プロジェクトの「ターゲット」に
登録していない**と、Extension はアプリにビルド・同梱されない。すると
`RPSystemBroadcastPickerView` の `preferredExtension` が指す Extension が実在せず、
**配信ボタンを押しても何も起きない**。`project.pbxproj` の
`isa = PBXNativeTarget` が Runner / RunnerTests の2つだけ、
`com.apple.product-type.app-extension` が無ければこの状態。

## 手順(このリポジトリでの実績)

### 1. 追加スクリプト `ios/scripts/add_broadcast_extension.rb`

`xcodeproj` gem で以下を行う(冪等: 既にターゲットがあれば何もしない):

- `project.new_target(:app_extension, 'BroadcastExtension', :ios, '13.0', nil, :swift)`
- `SampleHandler.swift` を Sources に追加、`Info.plist` / `entitlements` を参照追加
- `ReplayKit` をリンク
- ビルド設定(`PRODUCT_BUNDLE_IDENTIFIER` / `INFOPLIST_FILE` /
  `CODE_SIGN_ENTITLEMENTS` / `IPHONEOS_DEPLOYMENT_TARGET` / `SWIFT_VERSION` /
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` など)
- Flutter は Debug/Release に加え **Profile** 構成を使うので、Release を複製して
  Profile 構成を追加
- Runner が Extension に依存(`runner.add_dependency(ext)`)
- **Embed App Extensions** コピーフェーズを追加し `.appex` を埋め込む
  (`ATTRIBUTES = [RemoveHeadersOnCopy, CodeSignOnCopy]`)

**最重要の落とし穴**: 「Embed App Extensions」フェーズは Flutter の
**"Thin Binary" スクリプトフェーズより前**に挿入する。末尾に置くと新ビルド
システムが `Cycle inside Runner; building could produce unreliable results`
(appex コピーと Thin Binary が相互依存)で失敗する。

```ruby
thin_idx = runner.build_phases.index { |p| p.display_name == 'Thin Binary' }
runner.build_phases.insert(thin_idx, embed)   # 末尾 << ではなく Thin Binary の前へ
```

### 2. 検証ワークフロー `.github/workflows/setup-broadcast-extension.yml`

macOS ランナーで:
`gem list -i xcodeproj || sudo gem install xcodeproj` →
`ruby ios/scripts/add_broadcast_extension.rb` →
**生成された `project.pbxproj` を artifact アップロード(常時)** →
`flutter build ios --no-codesign` で検証。

ビルドが通ったら artifact を手元に落とし、`ios/Runner.xcodeproj/project.pbxproj`
へ反映してコミットする(壊れた pbxproj を main に載せない安全ゲート)。

### 3. 検証コマンド

```bash
gh workflow run setup-broadcast-extension.yml --ref main
gh run download <run-id> -n pbxproj-with-extension -D /tmp/pbx
# 妥当性: PBXNativeTarget が 3(Runner/RunnerTests/BroadcastExtension)、
#         app-extension productType が 1 になっていること
grep -c "isa = PBXNativeTarget" /tmp/pbx/project.pbxproj            # => 3
grep -c "com.apple.product-type.app-extension" /tmp/pbx/project.pbxproj  # => 1
```

## TestFlight 署名(別問題・要 Apple アカウント操作)

ターゲット追加とビルドが通っても、**TestFlight へ上げるには Extension 用の
プロビジョニングプロファイルが必要**。手動署名のままだと
`No profiles for '...BroadcastExtension' were found` で archive が失敗する。

このリポジトリでは iOS を macOS と同じ**自動署名**へ寄せて対応した:

- `ios/ExportOptions.plist` を `signingStyle = automatic` に
- archive/export に `-allowProvisioningUpdates` + App Store Connect API キー認証 +
  `CODE_SIGN_STYLE=Automatic` を付与
- `project.pbxproj` の **Runner Release** に焼き込まれていた手動署名
  (`CODE_SIGN_STYLE = Manual` / `CODE_SIGN_IDENTITY = "Apple Distribution"` /
  `PROVISIONING_PROFILE_SPECIFIER`)を除去し自動署名へ正規化

### 実際に通った構成(2026-07-13、TestFlight アップロード成功)

xcodebuild の `-allowProvisioningUpdates` は Extension の新規 App ID 作成で
`Authentication failed: bearer token` を出して**使えなかった**(API キーは
App Manager でアップロードには使えるのに、xcodebuild 内部の自動プロビジョニング
認証だけ通らない)。代わりに **fastlane + Spaceship::ConnectAPI(同じ API キー)
で署名資産を事前作成し、手動署名で使う**構成にしたら通った:

1. **`ios/fastlane/Fastfile` の `provision_extension` lane**(archive 前に実行):
   - `app_store_connect_api_key` でキーをコンテキストへ設定
   - `Spaceship::ConnectAPI::Token.create` + `Spaceship::ConnectAPI.token = ...` で認証
   - `Spaceship::ConnectAPI::BundleId.create(name:, identifier:, seed_id:, platform: "IOS")`
     で Extension の Bundle ID を作成(**`platform` 必須**)
   - `bundle.create_capability(Spaceship::ConnectAPI::BundleIdCapability::Type::APP_GROUPS)`
     で App Groups capability を有効化
   - `sigh(app_identifier:, platform: "ios", force: true, api_key:)` で App Store
     プロファイルを作成・インストール。**名前は既定の `"<bundleid> AppStore"`**
     (`provisioning_name` は既存プロファイルがあると無視される)
2. **pbxproj**: Runner / Extension の Release を**手動署名**に(`add_broadcast_extension.rb`
   末尾で設定):`CODE_SIGN_STYLE = Manual` / `CODE_SIGN_IDENTITY = "Apple Distribution"` /
   `PROVISIONING_PROFILE_SPECIFIER`(Runner=`"Local Audio Sync App Store"`、
   Extension=`"com.roto0504.localAudioSync.BroadcastExtension AppStore"`)。
   自動署名は archive で「開発用」プロファイルを探して失敗するため手動が必須。
3. **archive**: `-allowProvisioningUpdates` を付けず `DEVELOPMENT_TEAM=...` のみ。
   **ExportOptions**: `signingStyle = manual` + `provisioningProfiles` に両ターゲット分。

**唯一の手作業(Apple の制約)**: App Group の**特定グループの関連付け**は
App Store Connect API(API キー)では操作できず**ポータル専用**。Bundle ID は
自動作成されるので、ポータルの Identifiers → その Bundle ID → App Groups を
Edit して `group.<...>` にチェック→Save する **1 回だけ**の手作業が要る。
これをやると `Provisioning profile "..." doesn't support the ... App Group` が消える。
以降の配信は `gh workflow run testflight.yml -f platform=ios` だけで全自動。
