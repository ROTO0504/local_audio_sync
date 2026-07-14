# Mac の VSCode で local-audio-sync をビルドする手順

> 対象: Mac から **iOS / iPadOS / macOS** をビルド・実行したい開発者向け。
> Hub は Windows なので、Mac 側でビルドするのはクライアント(送信側)です。
> Windows ハブ自体のビルドは Windows マシンで [README.md](../README.md#ビルド方法) を参照。

---

## 0. 必要環境の早見表

| 項目 | バージョン / 内容 |
| --- | --- |
| macOS | 13(Ventura)以上を強く推奨。**macOS ビルドには 13 必須**(ScreenCaptureKit 要件) |
| Xcode | 15 以上(App Store からインストール) |
| CocoaPods | 1.13 以上 |
| Flutter SDK | 3.24 以上 |
| Dart SDK | Flutter 同梱(3.5 以上) |
| VSCode | 最新版 |
| VSCode 拡張 | `Flutter`(Dart-Code.flutter)+ `Dart`(Dart-Code.dart-code) |
| Apple Developer 登録 | 実機テストには無料 Apple ID で OK(7 日ごとに再署名)。App Store 配布には有償($99/年) |

---

## 1. ベース環境のインストール

### 1.1 Xcode

App Store から **Xcode** を入れ、初回起動でライセンスに同意します。続けてターミナルで Command Line Tools の選択を Xcode 同梱版に合わせる:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

### 1.2 Homebrew(未導入なら)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Apple Silicon 機ではインストール後にメッセージで案内される `eval $(/opt/homebrew/bin/brew shellenv)` を実行(または `~/.zshrc` に追記)。

### 1.3 CocoaPods

```bash
brew install cocoapods
pod --version   # 1.13 以上を確認
```

### 1.4 Flutter SDK

公式手順で zip 展開しても良いが、Mac は Homebrew が手軽:

```bash
brew install --cask flutter
flutter --version       # 3.24+
flutter doctor          # ✓ が全部つくまで指示に従って修正
```

`flutter doctor` で出やすい指摘と対応:

- **Xcode**: Command Line Tools が違う場合は 1.1 のコマンドを再実行。
- **CocoaPods**: 1.3 を未実行ならインストール。
- **iOS toolchain**: `sudo gem install ffi` が要求されることがある(Apple Silicon の場合)。
- **Connected device**: 後で実機を繋ぐので今は無くて OK。

### 1.5 VSCode と拡張機能

```bash
brew install --cask visual-studio-code
```

VSCode を起動し、左の拡張機能タブから以下をインストール:

- **Flutter**(Dart-Code.flutter)— Dart 拡張も自動で入ります
- **Dart**(Dart-Code.dart-code)

確認:

- コマンドパレット(`⌘ Shift P`)→ `Flutter: New Project` が出れば OK
- `⌘ Shift P` → `Flutter: Run Flutter Doctor` で 1.4 と同じチェックが VSCode 内で走る

---

## 2. リポジトリの取得

```bash
git clone <repository-url> local-audio-sync
cd local-audio-sync
flutter pub get
```

VSCode で当該フォルダを開く:

```bash
code .
```

---

## 3. iOS / iPadOS 向けセットアップ

### 3.1 CocoaPods のインストール

```bash
cd ios
pod install
cd ..
```

`Podfile.lock` と `Pods/` ディレクトリが生成されれば OK。失敗する場合:

```bash
cd ios
pod repo update
pod install --repo-update
cd ..
```

### 3.2 Xcode で signing と Broadcast Upload Extension を設定

iOS の **Broadcast Upload Extension**(他アプリの音をキャプチャする別プロセス)は、Flutter からは自動生成できず Xcode 上で手動追加が必要です。詳細手順:

→ **[docs/ios/setup-xcode.md](../docs/ios/setup-xcode.md)**

ざっくり流れ:

```bash
open ios/Runner.xcworkspace    # .xcworkspace を開くこと(.xcodeproj ではない)
```

Xcode で:

1. **Runner ターゲット → Signing & Capabilities** で自分の Apple ID(Team)を選ぶ。Bundle ID は `com.roto0504.localAudioSync` のままで実機テストは可能。
2. **「+ Capability」→ App Groups** を追加し、`group.com.roto0504.localAudioSync` を有効化。
3. **「+」ボタン → Broadcast Upload Extension** ターゲットを追加(`docs/ios/setup-xcode.md` の §2〜5 通り)。
4. Extension ターゲットにも同じ App Group を有効化。

> **既に pbxproj 整備済みの新規 Swift ファイル**(`AudioSessionManager.swift` / `BroadcastReceiverPlugin.swift` / `BroadcastPickerView.swift`)は Runner ターゲットに登録済みなので、ユーザーが Xcode で追加する必要はありません。

### 3.3 実機接続と信頼

1. iPhone / iPad を Lightning / USB-C で Mac に接続
2. デバイス側で「このコンピュータを信頼」をタップ
3. デバイス側 **設定 → 一般 → VPN とデバイス管理** で、自分の Apple ID 開発者証明書を「信頼」

確認:

```bash
flutter devices
# 例: iPhone (mobile) • 00008110-XXXX-XXXXXXXXXXXX • ios • iOS 17.5
```

---

## 4. macOS 向けセットアップ

### 4.1 ScreenCaptureKit の許可(初回のみ、ビルド後)

macOS クライアントは `ScreenCaptureKit` で内部音声を取得するため、初回実行時に「画面録画」許可ダイアログが出ます。

```text
システム設定 → プライバシーとセキュリティ → 画面録画 → local_audio_sync をオン
```

このダイアログが出るのはビルド後の初回起動時なので、今の段階では何もしなくて OK。

### 4.2 CocoaPods(macOS 側)

```bash
cd macos
pod install
cd ..
```

---

## 5. VSCode からビルド & 実行

### 5.1 ターゲットデバイスを選ぶ

VSCode 右下のステータスバーに現在のデバイス名が表示されます(例:`macOS (desktop)`)。

クリックするとデバイス選択メニューが開くので、目的のデバイスを選択:

- `iPhone` / `iPad`(USB 接続中の実機)
- `macOS`(自分の Mac)
- `iOS Simulator`(シミュレータ起動中なら)

シミュレータを起動するには:

```bash
open -a Simulator
```

または VSCode コマンドパレット → `Flutter: Launch Emulator`。

### 5.2 デバッグ実行(F5)

VSCode で `F5` または `Run → Start Debugging`。初回は `.vscode/launch.json` を自動生成するか聞かれるので Yes。

ホットリロード:

- `r`(VSCode の Debug Console にフォーカスして)
- ファイル保存時の自動 Hot Reload は VSCode 設定の `dart.flutterHotReloadOnSave` で `always` に。

### 5.3 リリースビルド(コマンドライン)

```bash
# iOS(コードサイン不要のコンパイル確認)
flutter build ios --release --no-codesign

# iOS(実機にインストール、署名あり)
flutter build ios --release
flutter install -d <device-id>

# macOS(リリース)
flutter build macos --release
# 出力: build/macos/Build/Products/Release/local_audio_sync.app
```

### 5.4 シミュレータでの注意点

- iOS シミュレータでは **Broadcast Upload Extension は動きません**(実機必須)。
- macOS では ScreenCaptureKit が動くので、Mac 上で自分の音を Hub に送る検証はできます。

---

## 6. 動作テスト(クライアント側)

1. **Windows ハブ**側で `local_audio_sync.exe` を起動し、「Hub として起動」
2. Mac / iOS デバイスを **同一 Wi-Fi** に接続
3. Mac の VSCode から `F5` で実行
4. 「クライアントとして起動」を選ぶ
5. Hub を自動検出すると接続が成立(画面に Hub IP が表示)
6. 配信開始:
   - **iOS / iPadOS**: 画面の「タップして配信開始」→ システムシートで「Local Audio Sync 配信」を選択
   - **macOS**: 自動でキャプチャ開始(初回は画面録画許可ダイアログを承認)
7. Mac / iOS で Spotify などを再生し、Windows ハブから音が出れば成功

---

## 7. トラブルシューティング

### `pod install` が失敗する(Apple Silicon)

```bash
sudo gem install ffi -- --enable-libffi-alloc
cd ios && pod install
```

### `flutter run -d ios` で codesign エラー

- Xcode の Runner ターゲット → Signing & Capabilities で Team が選択されているか確認
- Bundle ID が他人と衝突している場合は `com.roto0504.localAudioSync` を自分のドメインに変更
- 一度 Xcode から `Cmd + B` でビルドを通してから VSCode に戻ると署名キャッシュが効いて成功することがある

### `App Group コンテナが取得できません` エラー(iOS 実機)

- Runner と BroadcastExtension の両ターゲットで App Group が一致しているか確認
- 詳細: [docs/ios/setup-xcode.md のトラブルシューティング](../docs/ios/setup-xcode.md#トラブルシューティング)

### macOS で `ScreenCaptureKit が見つからない` ビルドエラー

- ターゲットの **Deployment Target が 13.0 以上** か確認
- Xcode の Runner → General → Minimum Deployments を 13.0 に

### `flutter devices` に実機が出ない

- USB ケーブルをデータ通信対応のものに交換(充電専用ケーブルだと表示されない)
- デバイスのロックを解除して「信頼」をタップ
- `xcrun xctrace list devices` で Xcode 側からも見えるか確認

### VSCode で Dart の補完が効かない

- コマンドパレット → `Dart: Restart Analysis Server`
- それでも直らないときは VSCode 再起動 → `flutter pub get`

### Hub に音が届かない

- Mac / iOS と Hub(Windows)が **同一 Wi-Fi** か再確認
- Windows ファイアウォールで UDP **9999 / 7777** の受信許可
- ルーターの **AP 分離(AP Isolation)** が無効か確認
- 6 秒間ビーコン未受信で自動再探索になるので、しばらく待つ

---

## 8. 参考リンク

- [README.md](../README.md) — プロジェクト全体の概要
- [docs/PLAN.md](../docs/PLAN.md) — アーキテクチャ判断の背景
- [docs/ios/setup-xcode.md](../docs/ios/setup-xcode.md) — Broadcast Upload Extension の Xcode 手順
- [Flutter 公式: macOS install](https://docs.flutter.dev/get-started/install/macos)
- [Flutter 公式: iOS deployment](https://docs.flutter.dev/deployment/ios)
