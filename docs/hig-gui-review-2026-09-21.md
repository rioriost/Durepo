# Durepo GUI — HIGを用いた修正と検証（2026-09-21）

## 対象と設計方針

基準コミットは `3c1140f`。開始時の作業ツリーはクリーン。macOSネイティブのSwiftUIアプリとして、リポジトリの登録、保存済みスナップショットの確認、復元への導線を整理した。

既存の3画面のサイドバーを維持し、画面名はウインドウのナビゲーションタイトルに表示する。日常操作を見つけやすくし、補助操作と削除は名前付きメニューにまとめる。空の画面にも次の操作を用意する。標準のList、Table、Menu、TabView、Form、セマンティックな文字スタイルを使用し、独自のガラス表現やアニメーションは追加しない。日本語・英語の追加文言をそろえる。

最低OSはmacOS 26.0のまま。AppModel、保存・復元・除外ルールの処理、Sandbox、App Group、security-scoped bookmark、権限要求の実装は変更していない。確認ダイアログも維持した。

## 参照した一次資料

取得日はいずれも2026-09-21。HIGのHTMLはJavaScriptのみだったため、スキル付属の取得スクリプトでAppleのDocC本文を読んだ。これは設計上の助言であり、App Reviewの承認や全面的な適合判定ではない。

| 分類 | 資料・該当箇所 | 今回の判断 |
| --- | --- | --- |
| APPLE-HIG | [Designing for macOS — Best practices](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | リサイズを考慮した情報密度、メニューバーからの操作、キーボードショートカットを重視する。 |
| APPLE-HIG | [Toolbars — Titles / Actions / macOS](https://developer.apple.com/design/human-interface-guidelines/toolbars) | 内容がわかるタイトル、標準ボタン、操作の絞り込み。ツールバーの「追加」をメニューバーからも実行できるようにする。 |
| ACCESSIBILITY / APPLE-HIG | [Accessibility — Vision](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 色だけに頼らない状態表示、読み上げ名、システムの色と文字スタイルを使用する。数値的なコントラスト適合は今回未測定。 |
| APPLE-SDK | [SwiftUI Form — Overview](https://developer.apple.com/documentation/swiftui/form) | 設定の入力項目を標準コンテナでまとめる。Markdown版の本文と利用可能OSを確認。 |
| バージョン確認 | [Apple Developer Releases](https://developer.apple.com/news/releases/) | 公開版macOS 27.0 (26A428)、Xcode 27 (27A266a)は9月14日付。27.2 betaも掲載されているが今回は使用していない。 |

ローカル環境はmacOS 27.0 (26A428)、Xcode 27.0 (27A266a)。SDKと実行環境を区別し、macOS 26での実行結果は主張しない。

## 修正内容と所見

| ID | 所見・影響 | 修正 | 検証状態 |
| --- | --- | --- | --- |
| GUI-01 | リポジトリ行の右側に多数のボタンがあり、長い名前と接続エラーの表示が窮屈になる。 | 主操作を情報の下へ移動し、除外ルール・スナップショット表示・削除を操作メニューへ整理。長い名前は最大2行とヘルプで確認可能。 | 部分描画でレイアウト改善を確認。実操作は未確認。 |
| GUI-02 | 7列のスナップショット表では狭い表示で日時が省略され、操作列が見えなくなる。 | 名前と状態、日時と理由、ファイル数と容量、操作の4列にまとめる。保護・異常はアイコンと文字で表示し、同時に成立する場合は両方を表示。 | 860×560のサンプル描画で4列と操作アイコンを確認。途中で発見した操作メニュー名のはみ出しも修正して再描画。 |
| GUI-03 | 設定画面に全機能が縦に並び、除外ルールの編集欄が幅を取り合う。保存先は無効な入力欄になっている。 | 一般・除外ルール・診断の3タブへ整理。除外ルールの操作をリスト下へ移動。保存先は選択・コピーできるテキストにする。 | ビルドおよび一般タブの部分描画を確認。タブ切替とコピーの実操作は未確認。 |
| GUI-04 | ページ名と進行状況の置き場所がばらばらで、追加操作がツールバーにしかない。 | ナビゲーションタイトルと下部の進行状況表示、サイドバーのバックグラウンド保護状態と設定導線を追加。メニューコマンドを追加。 | コンパイルとコード確認済み。ウインドウ装飾、メニュー、キーボード操作は未確認。 |
| GUI-05 | 空のダッシュボードから登録に進むボタンがなく、ファイル選択チェックボックスの名前が空。 | データの有無に応じた追加・スナップショット作成ボタンを表示。チェックボックスに対象パス、アイコン操作に名前を設定。 | ソース確認済み。VoiceOverでの読み上げは未確認。 |

新しいキー操作は、Command-O（リポジトリ追加）、Command-Shift-S（全リポジトリのスナップショット）、Command-1/2/3（画面移動）。選択変更と処理中の無効化には既存モデルを使用する。

## 実施した検証

| チェック | 結果 | 根拠と限界 |
| --- | --- | --- |
| 修正前ビルド | pass | Debug / CODE_SIGNING_ALLOWED=NO。`build/gui-review/baseline-build.log`。 |
| 修正後ビルド | pass | 同じ構成で成功。`build/gui-review/final-build.log`。配布署名・インストールの検証ではない。 |
| 既存テスト | pass | `swift test --parallel`：60件、2スイート成功。`build/gui-review/tests.log`。GUI操作のテストではない。 |
| 英語・日本語の文字列ファイル | pass | `plutil -lint`。新規キーの重複も確認。 |
| 差分の空白検査 | pass | `git diff --check`。 |
| ネイティブビューの部分描画 | pass（限定的） | 実際のContentView / SettingsViewをNSHostingViewに配置し、サンプルの長い名前、停止状態、保護状態、異常状態を描画して画像を開いた。モデルのrun/loadや保存・復元操作は実行しない。 |
| 実ウインドウ全体の見た目 | blocked | Computer Useが2回とも `Sky Computer Use native pipe closed before response`。補助レンダラーにも黒く欠落するSwiftUI領域があり、完全なスクリーンショットとして扱えない。画面収録権限も利用不可。 |
| 日本語 / Light・Dark / 最小幅 | 限定的 | 860×560で日本語の表と行を描画。Darkも生成・一部確認したが上記描画欠落があるため、色・全体レイアウトを合格とはしない。 |
| 最小OS macOS 26 | not-run | この環境はmacOS 27。 |
| VoiceOver・AXツリー・キーボード移動・フォーカス復帰 | blocked | 画面操作接続が利用不可。ソース上のラベル・ショートカット確認に限定。 |
| 文字拡大・コントラスト増加・透明度低下 | not-run | ユーザーのシステム設定は変更していない。 |
| モーション | not-applicable（独自演出なし） | 新しい独自アニメーションは追加していない。システム遷移のReduce Motion実行確認は未実施。 |

ビルド手順：

```sh
xcodebuild -project Durepo.xcodeproj -scheme Durepo \
  -configuration Debug -derivedDataPath build/GUIReview \
  CODE_SIGNING_ALLOWED=NO build
swift test --parallel
plutil -lint Resources/en.lproj/Localizable.strings Resources/ja.lproj/Localizable.strings
git diff --check
```

`build/gui-review/`のログと補助描画はローカル検証資料で、Gitの対象外。描画不備のある画像は成果物のプレビューとして配布しない。

## 未確認の実操作

画面操作が利用できる環境で、日本語・英語、通常サイズ・860×560、Light・Darkを確認する。サイドバーの画面移動、Command-Oとキャンセル、操作メニューからの除外ルール編集とキャンセル、3つの設定タブ、長い保存先のコピーを確認する。データ変更を避けた状態で削除・元位置復元の確認画面を開いてキャンセルし、フォーカスが元へ戻ることを確認する。VoiceOverでリポジトリ名、状態、操作メニュー名、ファイル選択チェックボックスのパスを読み上げられることを確認する。

実装とビルド検証は完了。全面的なHIG適合や、実画面・アクセシビリティの検証完了は主張しない。
