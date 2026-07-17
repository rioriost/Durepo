# Durepo 実装プラン レビュー

レビュー日: 2026-07-17

## 結論

元のプランは、FSEventsを変更通知としてのみ扱い、最終状態を再スキャンで確定する点、CASを一時ファイル・fsync・renameで確定する点、復元を別ディレクトリ優先にする点が堅実です。一方で「Mac App Store配布」と「Sandbox無効案」が両立しないこと、同一ユーザー権限の誤操作からバックアップ領域自体を守れないこと、復元時のパス/リンク攻撃と読み取り中のファイル変更への対策が未確定でした。

smoke test段階では、App Store適合構成を先に固定し、安全な最小経路を実装します。高度な差分、SQLite journal、GC、元位置復元は、壊れ方が大きいため後続フェーズへ分離します。

## 優先度別の指摘

### P0: リリースまたはデータ安全性を阻害する項目

| 項目 | 問題 | 決定/対策 |
|---|---|---|
| App Sandbox | Mac App Storeでは必須。Sandbox無効案は審査前提と矛盾する | GUI/AgentともSandbox化する。GUIのapp-scoped bookmarkはAgentで流用せず、通常bookmarkで権限を引き渡してAgent自身の永続bookmarkを作る |
| 脅威モデル | AIエージェントが同じユーザーかつ広いアクセス権を持つ場合、Durepoの保存領域も削除できる | 1.0は偶発事故からの復旧。改ざん耐性は外付け/リモート/別資格情報への複製で提供 |
| 復元時path traversal | manifestに`..`、絶対パス、symlink親が混入すると復元先外へ書ける | 全相対パスを検証し、symlinkは最後に作り、symlink配下のentryを拒否。新規の兄弟一時ディレクトリへ復元後rename |
| TOCTOU | ハッシュ中にファイルが変更・置換されると、hashと内容/metadataが不整合になる | `O_NOFOLLOW`でopenし、前後の`fstat`でdevice/inode/size/mtimeを比較。変化時は1回retry後に失敗 |
| LaunchAgent packaging | plist配置と実行ファイル配置が曖昧で、旧式の`~/Library/LaunchAgents`書込はSandbox/App Storeに不向き | plistを`Contents/Library/LaunchAgents`、実行ファイルをbundle内へ置き、`BundleProgram`と`SMAppService`を使用 |
| Notarization | App Store版とDeveloper ID直接配布版が混同されている | App Store uploadは個別notarization不要。直接配布だけDeveloper ID + Hardened Runtime + `notarytool` + staple |

### P1: MVPの信頼性・性能に重要な項目

| 項目 | 問題 | 推奨 |
|---|---|---|
| FSEvents ID | event IDだけではvolume変更、journal欠落、root移動を十分識別できない | volume UUID、root file resource identifier、last committed event IDを同じtransactionで保存。Dropped/MustScan/RootChangedはfull scan |
| 初回scan競合 | 「現在ID取得→scan」だけではscan中変更の扱いが難しい | streamを先に開始してqueueし、baseline確定後にqueueをreconcileする方式を優先 |
| イベントjournal | event書込前にクラッシュすると再開根拠を失う | SQLite WAL、busy timeout、schema migration、batch stateを使用。event IDをsnapshot commitより先へ進めない |
| CAS commit | 単なる`Data.write(.atomic)`では耐久性の保証が弱い | object tempとmanifestをfsync、rename後に親directoryもfsync。SQLite commitを最後に行う |
| 読み取り負荷 | ファイルごとのTask乱立はSSDとメモリを圧迫する | bounded task group、volume別I/O semaphore、1 MiB程度のstreaming buffer、QoS utility。最初は直列で正しさを測る |
| 大量一覧GUI | snapshot entry全件をMainActorへ載せると停止する | database pagination、stable identity、SwiftUI Table/List。macOS 26の改善を活かしても100k件全ロードは避ける |
| `.git` locks | lockファイルを忠実復元するとGitが使用不能になる | 保存はしてよいが、復元時は既定除外/警告。Gitプロセスが動作中なら元位置復元を拒否 |
| hard link / clone | CASは内容重複を除くがhard-link topologyは失う | device+inode+link countをmanifestへ保存し、復元時のhard-link再構成をMVP 2で追加 |
| package / sparse file | packageを一ファイル扱い、sparseを通常copyすると欠落/容量膨張 | directoryとして列挙。allocated sizeとsparse extent対応をMVP 2で追加 |
| resource limits | 巨大repoでmanifest JSON全体をメモリに持つ | smokeではJSON、製品版はSQLite snapshot_entriesへstreaming insert |

### P2: 1.0前に詰める項目

- ACL、xattr、resource fork、birth time、Finder flagsの復元可否と、Sandbox下で許される範囲を実機試験する。
- UID/GIDは通常ユーザーが自由に復元できず、別ユーザーIDを持ち込む意味も薄いため、所有者の忠実復元を成功条件から外す。
- CAS暗号化を行う場合は鍵をKeychainに置く。ただし鍵喪失は全snapshot喪失になるため、回復設計なしに既定化しない。
- GCはmark-and-sweepのmark集合を確定してから行い、snapshot削除transactionとは分離する。異常検知時とintegrity error時は停止する。
- backup保存先の空き容量に加え、APFS purgeable spaceを過信しない。snapshot開始前とobject書込失敗時の両方でENOSPCを扱う。
- 元位置復元はDurepo自身の監視イベントを発生させるため、restore operation IDによる自己イベント抑制と、pre-restore snapshotのcommit完了が必要。
- XPCを導入する場合はaudit tokenからcalling applicationの署名要件を検証し、bookmark由来root外のURLを拒否する。汎用copy/delete APIは作らない。
- privacy manifestにはfile timestamp（`3B52.1`, `C617.1`）とAgentの経過時間計測（`35F9.1`）を宣言する。required-reason対象の変更をApp Store upload前にXcodeのPrivacy Reportで再確認する。

## macOS 26で反映する項目

1. Swift 6.2 strict concurrencyを有効にし、SnapshotStore/Restorer/Registryをactorで隔離する。
2. Snapshot一覧はSwiftUI Table/Listを採用する。macOS 26では大規模Listのload/update性能が改善されているが、paginationは維持する。
3. Xcode/Instruments 26のSwiftUI instrument、Time Profiler、Hangs and Hitches、System Traceを性能ゲートに追加する。
4. `Span`/`RawSpan`は安全な低allocation処理に有望。CASハッシュの`Data` chunk overheadを計測し、効果がある場合だけ採用する。
5. 標準SwiftUI control/navigationを使い、Liquid Glassを自動適用する。可読性を損なう独自glass overlayは置かない。
6. 1024px原画とasset catalogをsmoke版に同梱し、App Store提出前にIcon ComposerのDefault/Dark/Monoを含む多層 `.icon` を作成する。

Apple資料:

- [macOS Tahoe 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
- [What’s new in SwiftUI (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/256/)
- [Improve memory usage and performance with Swift (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/312/)
- [Optimize SwiftUI performance with Instruments (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/306/)
- [Icon Composer](https://developer.apple.com/icon-composer/)

## macOS 27で準備する項目

macOS 27 Golden Gateは2026-07-17時点でbeta 3であり、製品の最低要件や必須経路にはしません。

1. 新しいSwift Systemの`Stat`、`FilePath.stat()`、`FileDescriptor.stat()`は、現在のC `lstat/fstat` bridgeを型安全に置換できる。Xcode 27正式版でavailability分岐を追加する。
2. Xcode 27/Swift 6.4のSwift Executors instrumentと`@concurrent`を使い、hash/restore I/OがMainActorを占有していないことを検証する。
3. 新Document APIと`FileDocument`非推奨化は、将来snapshot manifest/diffをdocumentとしてexportする場合だけ対応する。コア保存形式には使わない。
4. DiskImageKitのASIF APIはVirtualization向けで、Durepo CASの高速化には直接採用しない。
5. betaのknown issueを避けるため、CIの必須jobはXcode 26 stableのままとし、Xcode 27 beta jobはallow-failureで追加する。

Apple資料:

- [macOS Golden Gate 27 Beta Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- [Xcode 27 Beta Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [Profile, fix, and verify: Improve app responsiveness with Instruments (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/268/)
- [What’s new in Swift (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/262/)

## 実装可能性評価

| 機能 | 評価 | 理由 |
|---|---|---|
| ユーザー選択rootの継続監視 | 条件付きで実装可能 | GUIから通常bookmarkを引き渡し、Agentが自分用のsecurity-scoped bookmarkを作成する実機検証が必要。app-scoped bookmarkの直接共有は不可 |
| `.git`を含むfull snapshot | 実装可能 | `.git`を明示除外しない。変化の激しいobject/lockはretry/warningが必要 |
| CAS dedup | 実装可能 | SHA-256 streamingとatomic object commitで開始可能 |
| GUI終了後の監視 | 実装可能 | embedded LaunchAgent + SMAppService + user approval |
| 完全に破壊不能なローカルbackup | 同一ユーザー内では不可能 | Full Disk Access/ユーザー自身はbackupを削除可能 |
| repo全体の真のatomic置換 | 条件付き | 同一volume・同一parentのrenameが必要。open fileや外部processとの協調は別問題 |
| APFS volume snapshot | App Store MVPに不適 | volume-level権限と運用がrepo単位のsandbox appに合わない |

## smoke testの合格条件

- Swift Package unit testsが通る。
- `.git/HEAD`、未コミットファイル、symlinkをsnapshotし、CAS hash検証後、新規directoryへrestoreできる。
- 同一内容の2ファイルが1 CAS objectへdeduplicateされる。
- backup保存先がrepo配下なら拒否する。
- Xcode 26 stableでGUI、Core framework、Agentがbuildできる。
- `.app`内にSandbox entitlements付きmain app、embedded agent、LaunchAgent plist、日英localization、AppIconがある。
- 実署名/SMAppService登録の最終確認はApple Developer portalでApp Group identifierとprovisioning profileを有効化した署名buildで行う。
