# Durepo 設計・コードレビューと修正プラン

レビュー日: 2026-09-16

レビューモデル: GPT-6 Astra (`gpt-6-astra`)

対象: `ef8fa97` / 1.1.0

初回レビュー時は製品コードを変更せず、本書を作成した。
その後の依頼に基づく1.1.1の修正・実行結果は末尾に記録する。
以下の根拠行はレビュー対象commitの行番号である。

## 初回レビューの結論

**修正が必要。特に、保存中の排他制御、不完全なスキャンの扱い、
障害後の整合性判定・削除処理を、次のリリースに先立って直すべきである。**

CAS、SQLite WAL、ファイル単位のAPFS clone、新規ディレクトリ優先の復元、
イベントの永続化という基本構成は維持できる。全面的な作り直しは不要。
問題は個々のAPI選択よりも、複数の処理をまたぐ操作の境界にある。
`actor` は `await` をまたぐ操作全体の排他を保証せず、JSONとSQLiteの
双方に情報が残るだけでは異常検知や削除の安全性は保証されない。

本レビューは実装モデルの比較評価ではなく、現行コードの挙動に対する評価である。
同一ユーザーによる意図的な改ざんへの耐性や、オフラインバックアップは要求しない。

指摘は **P1が8件、P2が6件**。
CoreのR1〜R7は隔離したストアで挙動を再現した。
GUI/AgentのR8〜R14は主にコードの呼び出し順序と状態遷移を根拠とし、
R10はCore側の再起動状態も再現した。実際の署名済みGUI/Agentでの再現とは区別する。

## 優先度

- **P1**: 復旧可能なデータの喪失、復元不能な保存結果、保護機能の停止につながる。次回リリース前に修正。
- **P2**: 特定の構成や障害後の処理で保証・表示が崩れる。P1に続いて修正。

## 保存・復元エンジンの指摘

### R1 / P1: 保存途中のオブジェクトを並行GCが削除できる

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:80-82,130,514-541,599-611,727-741`

`createSnapshot` はストアロックを取得してから `await captureFiles` する。
この中断中に同じactorへ別の保存・GC処理が入れる。
`lockf` のロックはプロセス単位なので、同一プロセス内の呼び出し同士の排他にはならない。
先行保存がCASへ移動済みでもmanifest未確定のオブジェクトは、後続GCから未参照に見える。

隔離したストアで次の両方を再現した。

- 保存の最初の進捗通知後に同じストアでGCを開始すると、1オブジェクトが削除される。
  保存は成功を返すが、そのmanifestの検証は `missingObject` で失敗する。
- 異なる2リポジトリを同じストアへ並行保存し、後続保存の容量retentionを作動させると、
  **両方の保存が成功したのに、先行snapshotの検証が失敗する。**

容量上限を小さくしたのは発生条件を少ないデータで作るためであり、
既定の上限でも上限到達時には同じ排他の欠陥が存在する。

Agent側の実行中ガードもrepository ID単位であり、異なる登録の保存は並行して
同じストアへ到達する (`Sources/DurepoAgent/main.swift:254-268`)。
GUIでも削除ボタンは処理中に無効化されず
(`Sources/DurepoApp/ContentView.swift:166-174`)、
復元と対象snapshotの削除が競合する経路がある。

**修正:** 保存・retention・GC・削除・起動時reconcileに共通の操作単位の排他を導入する。
同一プロセス内の複数 `SnapshotStore` とGUI/Agent間の双方を対象にする。
ロック待ちはactorの実行スレッドを同期的に塞がない方式にする。
復元中のmanifest/objectにも読み取り中の保護を設け、retention対象から外す。

**受け入れ条件:** 並行保存、保存中GC、保存中削除、復元中retentionの組み合わせで、
成功したsnapshotの全参照が残る。プロセスを分けた競合でも停止・相互待ちを起こさない。

### R2 / P1: manifest欠落をdeep診断が正常扱いし、GCが残存データを削除する

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:411-425,443-454,476-510,514-541,670-687`

軽量診断はSQLiteに登録されたmanifest一覧と実ファイルを比較するが、
deep診断は実在するJSONだけを読むため、消えたmanifestを検出しない。
GCもSQLiteの構造的な `integrity_check` と保護警告の有無だけを入口条件とし、
実在するJSONだけから参照集合を作る。

正常snapshot作成後にそのmanifestだけを削除すると、
軽量診断は異常、deep診断は正常となる。
さらにGCはSQLiteにsnapshotが1件残っている状態で、その内容オブジェクトを削除した。
本来SQLiteのentry索引とCASから救出できたデータまで失われる。

**修正:** 軽量・deep・GCの共通入口として、DBとmanifestの集合・ID・形式・参照の
整合性確認を実施する。deepは軽量の確認を省略せず、その上にハッシュ確認を追加する。
参照集合を完全に確定できない場合、GC・容量retention・purgeは削除前に停止する。
欠落・破損の情報を永続化し、復旧または明示的な処置まで削除を再開しない。

**受け入れ条件:** DBにだけ残るsnapshot、JSONにだけ残るsnapshot、不正な参照、
欠落objectに対して診断結果が矛盾せず、安全性不明時の削除件数は0となる。

### R3 / P1: 元位置復元で、バックアップ除外された現在のファイルも消える

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:338-366`,
`Sources/DurepoCore/SnapshotRestorer.swift:113-144`

復元前snapshotにも通常の除外ルールを適用し、その後に現在のディレクトリ全体を
置換してrollbackディレクトリを削除する。
したがって「通常snapshotに含めない」という指定が、
「元位置復元時には退避なしで消してよい」という別の意味に変わっている。

`private/` を除外し、現在の `private/notes.txt` にだけデータを置いて元位置復元すると、
当該ファイルは現物からも復元前snapshotからも失われた。
除外対象が再生成可能なキャッシュだけとは限らず、ユーザーの独自ルールにも発生する。
さらにGUIの確認文は「完全なpre-restore snapshot」を作ると説明しており
(`Sources/DurepoApp/ContentView.swift:585`)、この挙動と矛盾する。

**修正:** 当面は元位置復元を制限する。恒久対応では除外パスを新しいツリーへ保持するか、
通常の除外設定とは独立した退避を作成する。
残存データを回収できるまでrollbackを自動削除しない。
ファイルとディレクトリの型衝突など、保持不能な場合は交換前に停止して説明する。

**受け入れ条件:** `.env`、任意の除外ディレクトリ、入れ子の除外、
古いsnapshotとの型衝突において、現在の除外データが無断で失われない。

### R4 / P2: 破損した既存CASを、次の保存でも成功扱いで再利用する

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:1122-1164`

同じハッシュ名のobjectが存在すると、内容を確認せず既存objectを使い、
新しく正常なソースから取得した一時objectを捨てる。
既存CASの内容だけが破損した状態で再保存すると、
ソースが正常なのに新しいsnapshotも復元不能になり、保存自体は成功する。

**修正:** 既存objectを採用する際の検証方針を定める。
サイズ確認だけでは同サイズ破損を検出できない。
ハッシュ不一致の場合は、排他制御下で正常な一時objectから安全に修復するか、
破損として保存を失敗させ、通知・隔離する。
同一処理内での重複検証を省くことと、未検証の既存objectを信用することを区別する。

**受け入れ条件:** 同じサイズで内容だけ変えた既存CASを用意して再保存すると、
正常に修復されるか明示的に失敗し、復元不能な新規snapshotを正常扱いしない。

### R5 / P2: Git配下のサブディレクトリを選ぶと追跡ファイル保護を迂回する

**根拠:** `Sources/DurepoCore/RepositoryExclusionOptimizer.swift:184-200,487-518`

選択ディレクトリ直下に `.git` がないだけでGit管理外とみなす。
Gitリポジトリ内のサブディレクトリにも追跡ファイルは存在するため、この判定は不十分。

`nested/target/source.rs` をGitで追跡し、`nested/Cargo.toml` を置いたうえで
`nested/` を選んで除外ルールなしから最適化すると、
`target/` が提案され、追跡確認失敗のフラグも立たなかった。

**修正:** Gitによるworktree探索を利用し、選択パスとGitルートを区別する。
パスの基準を選択ディレクトリへそろえて追跡情報を照合する。
Git管理外と追跡確認不能も区別し、確認不能ならルールを追加しない。

**受け入れ条件:** Gitルート、サブディレクトリ、linked worktree、submodule、
Git管理外フォルダで追跡中の内容を新規の自動除外に含めない。

### R6 / P1: 読み取り不能を削除と同等に扱い、不完全なsnapshotが正常な復旧点を置き換える

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:135-157,818-857`,
`Sources/DurepoCore/SQLiteMetadata.swift:193-215`

ディレクトリ列挙中のエラーはwarningに変えて処理を継続する。
読み取れなかった配下のentryが欠落しても、保存結果には「不完全」という状態がなく、
削除件数が異常検知の閾値未満なら正常扱いでcurrent index更新とretentionを実行する。

1ファイルを保存した後、その親ディレクトリを `000` にして再保存すると、
ファイル数0、warning数1、health=`normal` のsnapshotが成功した。
保持数1では直前の完全なsnapshotも削除された。
既定の保持数でも、同じ不完全な保存を繰り返せば古い復旧点は順に失われる。

**修正:** 読み取り・列挙失敗を、存在しないことを確認できた削除と区別する。
少なくとも不完全な走査では正常snapshotへの昇格、current indexの置換、
イベント完了扱い、旧復旧点のpruneを禁止する。
部分的な救出結果を残すなら、明示的な状態と利用者への通知を付ける。

**受け入れ条件:** 小規模repositoryの権限エラーでも完全な復旧点が維持される。
復元前snapshotが不完全な場合は元位置交換を開始しない。
本当の削除イベントの処理は維持する。

### R7 / P1: クラッシュ後にmanifestを復旧すると異常判定が失われ、旧復旧点がpruneされる

**根拠:** `Sources/DurepoCore/SnapshotStore.swift:148-157,1237-1258`,
`Sources/DurepoCore/SQLiteMetadata.swift:182-187`

manifestの永続化とSQLite commitには間隔があり、その間の異常終了は発生し得る。
起動時reconcileは未登録manifestを `index()` で `normal` として取り込み、
current indexを無効化した後にretentionする。
元の保存処理が検出していたはずの異常、前のsnapshotの保護、保護警告は復元されない。

正常な `.git` を持つsnapshotの後に、SQLite未登録の空manifestが残る
クラッシュ状態を隔離環境で再構成した。
再起動相当の新しいストアで読み出すと、空snapshotはnormal、
警告数0、保持数1では正常だった旧snapshotが削除された。
これは実際のプロセス強制終了ではなく、永続化境界の状態を再構成した再現である。

**修正:** committed / pending / deletingの扱いと正本を明確にする。
未commitのmanifestを、そのまま正常でprune可能なsnapshotへ昇格させない。
回復中は関連repositoryのretentionを停止し、
以前のcurrent indexを参照して異常検知・保護状態を確定してから公開する。
削除側にもtombstone等を設け、DB削除後に残ったJSONを新規snapshotとして復活させない。

**受け入れ条件:** object確定、manifest確定、DB commit、manifest削除の各境界で
異常終了しても、最後の完全な復旧点と保護状態を失わない。

## GUI・Agent・登録情報の指摘

### R8 / P1: 登録情報の全体書き戻しでbookmarkや他の登録更新を失う

**根拠:** `Sources/DurepoCore/RepositoryRegistry.swift:21-42`,
`Sources/DurepoApp/AppModel.swift:341-345`,
`Sources/DurepoAgent/main.swift:206-208`

GUIが古い `RepositoryRecord` を保持した後、Agentが自分のbookmarkを保存しても、
GUIで除外ルールを変更すると古いレコード全体が書き戻され、
新しい `agentBookmark` が `nil` に戻り得る。
このケースは厳密な同時実行を必要としない。

さらにJSONのread-modify-writeにプロセス間排他がなく、GUIとAgentの追加・更新・削除が
競合すると登録を失う。`update` は対象が消えていれば再追加するため、
削除済み登録の復活も起こり得る。atomic file replacementは更新競合の解決にはならない。

**修正:** フィールド単位の更新を、最新データに対するトランザクションとして行う。
JSONを維持するなら共通のRMWロックと世代確認を設ける。
SQLiteへ移す場合もフィールド更新と削除競合を明示的に扱う。
未登録IDに対する通常updateを暗黙の追加にしない。

**受け入れ条件:** Agent bookmark保存後の古いGUIレコード編集でもbookmarkを保持する。
別プロセスで追加・更新・削除を交差させても登録の消失・復活を起こさない。

### R9 / P1: 監視ルートの移動後に監視セッションを作り直さない

**根拠:** `Sources/DurepoAgent/main.swift:113-120,422-457,476,512-517`

`RootChanged` をfull scan要求へ変換するだけで、bookmark再解決、
監視URL更新、watcher再作成を行わない。
登録の再確認でも除外ルールが同じなら既存sessionを使い続ける。
ルートまたは親フォルダをrename/moveすると、古いURLの取得を再試行し、
移動後の編集の保護へ復帰できない経路となる。

**修正:** root変更をsession再構築として扱う。
bookmarkから現在位置を解決し、volume/root identityを更新し、
イベント継続点を再評価して監視とfull scanを再開する。
解決不能なら「監視中」とせず、利用者に再選択を求める。

**受け入れ条件:** ルートrename、親rename、移動後の編集を取得できる。
元位置復元によるルートinode交換も別ケースとして確認する。

### R10 / P1: cursorが0のまま正常終了したAgentは、停止中の変更を再開時に取りこぼす

**根拠:** `Sources/DurepoAgent/main.swift:130-151`,
`Sources/DurepoCore/SQLiteMetadata.swift:907-913,1060-1086`

初回scan中にイベントを受信しなければ、`commitEvents(through: 0)` により
cursor=0、pending=false、needsFullScan=falseとなり得る。
同じroot/volumeで再開した場合、Coreはその状態をそのまま返す。
Agentはcursor=0を `SinceNow` に変換する一方、
pendingもfull scan要求もないため起動時scanを予約しない。

この順序でAgent停止中に変更したファイルは、再開時に履歴再生もscanもされず、
少なくとも該当パスが再度走査されるまでsnapshotに反映されない。
Coreを新しいインスタンスで開き直してもcleanなcursor=0が残ることを再現した。
FSEventsを含む実プロセス再起動は未実施。

**修正:** 履歴再開に利用できるcursorを初回取得前に確保してstreamを開始し、
その境界までの取得をcommitする。
最低限cursor=0での起動はfull scanを必須にし、走査中のイベントも保持する。

**受け入れ条件:** 初回取得後にイベントが一件もない状態でAgent停止、
停止中に編集・削除、再起動という順序で変更を取りこぼさない。

### R11 / P2: 一件のbookmark障害が全登録の表示と既存snapshotの復旧導線を妨げる

**根拠:** `Sources/DurepoApp/AppModel.swift:92-98,593-618`,
`Sources/DurepoApp/ContentView.swift:540`

Agent bookmark未作成の登録でhandoff準備が失敗すると、
`repositories` への代入前に起動時load全体が中断する。
正常な他の登録も一覧に出ず、問題の登録を削除する導線も失われる。
snapshot一覧だけが後から戻っても、登録不在を理由に全体復元メニューが無効になる。
元リポジトリへのアクセス不能と、保存済みデータを新規場所へ復元できるかは別の問題である。

**修正:** 登録一覧・snapshot一覧の読み込みをアクセス権の準備から分離する。
bookmark障害は登録単位で表示し、削除・再選択を可能にする。
新規場所への復元は元リポジトリの存在やアクセス権を条件にしない。

**受け入れ条件:** 正常登録と解決不能bookmarkが混在しても、
正常登録の表示、問題登録の削除、保存済みsnapshotの新規場所への復元が可能。

### R12 / P2: Agentの監視開始失敗が通常のhealth経路へ届かない

**根拠:** `Sources/DurepoAgent/main.swift:122-154`,
`Sources/DurepoApp/AppModel.swift:506-507`

bookmark解決、root identity取得、watcher開始の失敗はログ出力だけであり、
snapshot作成時の失敗で利用する永続health/通知経路を通らない。
Agentが登録済み・起動済みであることと、各repositoryを実際に監視していることを
利用者が区別できない。

**修正:** setup失敗も登録ごとに永続化し、再試行成功時に解消する。
サービスの登録・承認状態とrepositoryの監視状態を分けて表示する。
再試行時の同一エラー通知は重複抑制する。

**受け入れ条件:** bookmark拒否、volume不在、watcher開始失敗がGUIに表示され、
再接続・再選択・監視開始成功で正しく解消する。

### R13 / P2: 新規登録直後から既定除外ルールの継承が切れる

**根拠:** `Sources/DurepoApp/AppModel.swift:152-156,319-325`,
`Sources/DurepoApp/ContentView.swift:768-770`

自動最適化の追加提案がなくても、現在のglobal rulesを含む結果を
`customExclusionRules` として保存する。
以降その登録はglobal rulesを継承しないため、設定で既定ルールを変更しても反映されない。
「個別ルールを保存するまで継承する」という表示と一致せず、継承へ戻す操作もない。

**修正:** 継承／独立モードを明示し、global rulesと自動提案の追加ルールを区別する。
現在の独立ルールを勝手に上書きせず、既存登録の移行方法と継承復帰操作を用意する。

**受け入れ条件:** 提案なし・提案ありの登録、明示的な個別設定、継承復帰の各状態で、
画面の説明と実際の除外対象が一致する。

### R14 / P2: 差分の表示モード変更中に古い応答を新しい一覧へ混入させる

**根拠:** `Sources/DurepoApp/ContentView.swift:699-703,717-729`

ページ取得中にChangesからAll Filesへ切り替えると、新しい取得は
`isLoading` のガードで開始されない。
その後、旧モードの応答が現在の一覧へ追加され、次ページのoffsetも旧データに基づく。
全件表示のつもりでも復元したいファイルが出ない状態になる。

**修正:** リクエストにsnapshot ID・表示モード・世代を持たせ、
応答時に現在の要求と一致するものだけを反映する。
モード変更後の先頭ページ取得を必ず実行する。

**受け入れ条件:** 応答を意図的に遅延させたモード連続切替で古い応答を破棄し、
新しいモードの先頭から欠落・重複なく表示する。

## 設計方針

| 維持するもの | 修正すべき境界 |
|---|---|
| SHA-256 CAS、bounded I/O、ファイル単位のclone | objectを作成中・参照中・削除可能のどれとみなすか |
| SQLite WALとイベントjournal | snapshot公開・保護判定・recovery・retentionの確定順序 |
| 新規ディレクトリ優先の復元 | 元位置交換を破壊的なトランザクションとして扱うこと |
| GUIとAgentの分離、Sandbox | 操作の排他と状態の所有者をプロセス間でも一貫させること |
| 除外候補の根拠表示と追跡ファイル保護 | Gitルート、選択ルート、除外範囲の区別 |

一度にXPCへの全面移行やストレージ形式の全面刷新を行う必要はない。
まず共通操作ゲートと削除前の整合性条件を確立し、その後に回復処理を整理する。

## 修正プラン

| 順序 | 対象 | 作業 | 完了条件 |
|---|---|---|---|
| 1 | R1、R2、R3、R6、R7 | 危険な削除・元位置復元を制限し、不完全な取得・回復中のpruneを停止する暫定ガード | データを失う成功扱いを止める。制限はUIと日英説明へ明示 |
| 2 | R1 | 保存、reconcile、GC、削除、retention共通の操作排他。復元中の読み取り保護も実装 | 同一actor、複数actor、GUI/Agentの競合で参照切れとdeadlockがない |
| 3 | R2、R6、R7 | 共通の整合性確認、不完全状態、manifest/DB回復状態、削除状態を実装 | 欠落・権限エラー・クラッシュ後も最後の完全な復旧点が残る |
| 4 | R3 | 除外データの保持、rollback寿命、元位置交換の中断回復を実装 | 現在データの回収経路を確保してから旧ディレクトリを削除 |
| 5 | R8〜R10 | 登録情報のトランザクション化、ルート再解決、初回cursorと再開処理を修正 | GUI/Agentの状態競合、移動後停止、停止中変更の取りこぼしを防止 |
| 6 | R4、R5、R11〜R14 | CAS検証・修復、Gitルート判定、障害の局所化、監視health、設定継承、ページ要求世代を修正 | 保存・復元の保証とUIの表示・設定が一致 |
| 7 | 全体 | 回帰ケースを恒久化し、README・設計文書・品質レビュー・リリースゲートを現行保証に更新 | 保存成功と実際の復旧可能性が一致することをリリース条件にする |

順序2は順序3・4の排他の土台になる。暫定ガードを残したまま段階的に直し、
各機能の受け入れ条件を満たしたものだけを再度有効化する。
R8〜R10はストレージ修正とは別の変更単位で進められるが、
プロセス間のロック順序は順序2の設計とそろえる。

## 保証範囲と留保

リポジトリ全体の同一時点取得は、ファイルごとのcloneだけでは保証できない。
この制約は既存の設計にも明記されており、本レビューでは新規不具合として数えない。
一方、成功したmanifestの参照objectが存在することや、
不完全な読み取りで既存の完全な復旧点を失わないことは、通常の保存契約として必要である。

実機のStore署名、security-scoped bookmark、SMAppService、再起動・sleep復帰について、
本レビューによる新しい合格判定は行っていない。
ソースから確認できる問題と、隔離したストアで再現した問題を、
これらの実機受け入れ結果と混同しない。

## 1.1.1 修正・実行記録

実施日: 2026-09-16 / バージョン: 1.1.1 / ビルド: 7

R1〜R14の修正を実装した。通常機能の無条件な停止ではなく、
操作全体の排他と異常時の明示的な停止条件を恒久対応として入れている。

| 指摘 | 実装した対応 |
|---|---|
| R1 | `FileOperationLock` の非同期取得とfd単位の `flock`。保存、起動処理、削除、GC、retention、復元の参照寿命を保護。処理中のGUI削除も抑止 |
| R2 | 軽量・deep共通のDB/manifest照合、削除前の参照集合検証、SQLite読取エラーの伝播、deep成功まで残す永続integrity failure |
| R3 | 除外中の現在データを新treeへ保持。`RENAME_SWAP` で原子的に交換し、元treeをrollback先に残す。pre-restore snapshotも保護 |
| R4 | 既存CASをハッシュ確認し、正常な新規取得内容で原子的に修復。既知のintegrity failure中は再利用entryも検証 |
| R5 | Gitの選択サブディレクトリ基準で追跡情報を取得。祖先探索のルート終了を明示し、Git管理外と確認不能を区別 |
| R6 | 列挙エラーを保存失敗として返し、current index更新・snapshot公開・retentionへ進めない |
| R7 | 回復snapshotを保護済み・anomalousとして警告。起動時pruneを撤廃し、削除tombstoneで残存JSONの復活を防止 |
| R8 | Registry RMWの排他、フィールド別更新、削除済みID拒否、旧handoffの世代確認 |
| R9 | RootChangedによるsession再構築とbookmark再解決。元位置交換後は新rootへbookmarkを再発行し、失敗時は停止・再接続導線を提供 |
| R10 | cleanなcursor=0も起動時full scan対象にする純粋ポリシーを導入 |
| R11 | 登録一覧とhandoff準備を分離し、障害を登録ごとに表示。元登録なしでも保存済みsnapshotを新規場所へ復元可能 |
| R12 | 監視開始失敗をhealthへ永続化。サービス登録・承認・監視状態を区別 |
| R13 | 自動提案なしの新規登録はglobal rulesを継承。個別ルール適用時は独立状態を表示し、継承復帰操作を追加 |
| R14 | ページ要求の世代・表示モードを照合し、旧応答と旧エラーを破棄。取得失敗時の再試行導線も追加 |

### 実行結果

- `swift test --parallel`: Swift Testing 60件とXCTest 8件が成功。
- Xcode 27 / Release / arm64 / warnings-as-errors: ビルド成功。
- Xcode Release tests (`ENABLE_TESTABILITY=YES`): 68テスト、失敗0、skip 0。
  パラメーター付きテストを展開した実行件数は69。
- `swift run durepo-smoke`: 成功。
- `FileOperationLock` をSwift親プロセスで保持し、独立したC子プロセスで
  nonblocking取得を試みる確認: 保持中は拒否、解放後は取得成功。
- 日英localizationとplistのlint、および差分の空白検査: 成功。

`StorageSafetyTests.swift` と `RegistrySafetyTests.swift` を恒久的な回帰ケースとして追加した。
失敗した初回の除外テストは、macOS 27のURLでルートの親が `/..` になるケースを
終端判定できていなかったためで、ルート判定を修正して再実行した。
Releaseでの `@testable` 読み込みには `ENABLE_TESTABILITY=YES` が必要なため、
製品用ビルドとは分けてReleaseテストを実行した。

### 利用者に見える変更とリリース範囲

- 元位置復元後の `.durepo-rollback-…` は自動削除しない。
  アプリに退避先とFinderで開く操作を表示する。結果確認後にその退避先だけを手動で削除する。
- 復元前snapshotには従来どおり除外設定を適用する。
  除外データは復元後のtreeと元treeの両方に残すため、退避のためにCASへ無断で取り込まない。
- 回復時の保護警告は利用者の確認まで保持する。
  永続integrity failureによる削除停止は、成功したdeep診断で解除する。
- SQLite schemaは7へ更新する。更新前のGUI/Agentを終了してから同じバージョンを使用し、
  古いバージョンと同じストアへ同時に書き込まない。
- この実行結果はGitHubのソースリリースの根拠であり、
  Store署名済みアプリの実機再起動、root移動、交換後bookmark再発行、
  App Store Connectへのアップロード・審査完了を意味しない。
