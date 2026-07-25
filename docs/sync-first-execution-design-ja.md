# Sync-first async execution design

## 1. 目的

async runtimeでも、resolverが実際にpending値を返すまでは同期fast laneと同じ実行コストに
近づける。Promise/Ticketが現れる可能性だけを理由に、同期fieldまでasync frame、pending
entry、scheduler、汎用completionへ載せない。

目標とする制御フロー:

```text
sync VM loop
  ├─ plain value / ready Ticket: 同期completionを続行
  └─ pending Ticket / Promise:
       現在位置をcontinuationへ退避
       subscriberを登録して呼び出し元へ戻る
       settle後にcontinuationをready queueへ積む
       保存した位置からsync VM loopを再開
```

本設計はPromiseの実行時間やI/O待ち時間を短縮するものではない。Houtou内部で同期処理にも
課しているasync対応コストを、実際のsuspension境界へ限定する。

## 2. 現状と問題

現在はrequest開始前にlaneを選択する。`async => 1`または`on_stall`があるrequestは、
resolver結果を調べる前からasync executorへ入る。

sync laneはblock内のopをその場でresolve/completeし、native valueへ格納する。cursor
snapshot、stack field frame、再帰呼び出しは関数が戻るまでに解放できる。

async laneはsuspension後も状態を保持するため、block frameとpending entryをheap上に作り、
resolver結果をpending表現へ変換し、callbackとschedulerでcompletionを再開する。この構造は
本当にpendingなfieldには必要だが、同期値しか返さないfieldも同じ経路を通る。

本質的に必要なasync固有処理は次に限られる。

- pending値を検出した時点の継続状態保存
- Ticket subscriberまたはPromise callbackの登録
- sibling/list itemの未解決数管理
- ready continuationのschedule
- suspensionをまたぐ値、path、frameのownership

request開始時から別executorを使うこと、同期completionをasync表現へ変換すること、
一度もsuspendしないblockにpending machineryを用意することは本質的要件ではない。

## 3. 既存実装から再利用する要素

mutation rootの`gql_runtime_vm_execute_serial_mutation_steps`は、同期opをloopで実行し、
Promiseが現れた時だけ`next_op_index`とframeを保持してcallback後に再開する。query用
continuationはこのモデルを、並行なsibling fieldとlist itemを扱える形へ一般化する。

既存の次の要素も維持する。

- native program、block、op、slot
- native valueとoutcome
- DataLoader Ticketのready同期取得
- async ready queueと再入抑止
- null/non-null、error path、abstract/list completionの共通helper
- `on_stall`によるDataLoader駆動とdeadlock検出

最初からschedulerやpending entryを全面置換しない。新continuationが扱えないshapeは現行async
executorへfallbackし、段階的に対象を増やす。

### 3.1 他言語処理系との対応

この設計は新しい方式ではなく、stackless coroutineをVM executorへ適用するものと整理できる。

- C# async methodは、未完了のawaitableへ到達するまで呼び出し元のthread上で同期実行する。
  awaitableが完了済みなら中断せず値を使う。Houtouのready Ticket fast pathに対応する。
- Kotlin coroutineはCPS変換後の関数が通常値または`COROUTINE_SUSPENDED` markerを返し、
  continuation objectにlocal変数とstate-machine位置を持つ。Houtouのop実行結果を
  completed outcomeまたはpending markerとして返すABIに最も近い。
- Rust `Future::poll`は`Ready(value)`ならそのまま進み、`Pending`なら状態を保持してwake後の
  pollで再開する。Houtouのready queueとblock continuationの関係に近い。
- LLVM coroutine loweringはsuspend pointをまたいでliveな値だけをcoroutine frameへspillし、
  start/resume/destroyへ分割する。continuationの最小状態と破棄関数を決める際のモデルになる。

静的なasync/await言語との主な違いは、suspend可能な構文位置がcompile時に既知なのに対し、
resolver call siteではplain valueとPromise/Ticketのどちらが返るかrequest時まで分からない
点である。これはHoutou固有ではなく、GraphQL.jsなどresolver結果を実行時にthenable判定する
GraphQL executorにも共通する。Houtouでは全blockを事前にcoroutine frame化せず、resolverが
pendingを返した時だけstack上の状態をheap continuationへ昇格する。CPS/state-machine
loweringを動的なlazy promotionとして実装する点が、静的async変換との相違になる。

参考となる一次資料:

- [C# Task-based asynchronous pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern)
- [Kotlin language specification: asynchronous programming with coroutines](https://kotlinlang.org/spec/asynchronous-programming-with-coroutines.html)
- [Rust Reference: await expressions](https://doc.rust-lang.org/reference/expressions/await-expr.html)
- [LLVM coroutine lowering](https://llvm.org/docs/Coroutines.html)

## 4. Continuationの最小状態

query block continuationはC stackを保存しない。再開に必要な明示状態だけを所有する。

```text
continuation
  state handle
  native program/block
  next op index
  source
  base path
  output/native block frame
  parent continuation + destination slot
  unresolved count
  pending slots[]
  resume state
```

pending slotはfieldごとの汎用resolve/reject CVを必須にしない。Houtou Ticketはslotへ直接値または
errorを格納できる。外部Promiseはadapter callbackから同じslotを更新する。

continuationはblock単位とする。sibling fieldが複数pendingでも、最後のslotがsettleした時だけ
block continuationをready queueへ一度積む。

## 5. 実行規則

### 5.1 通常実行

blockを同期loopで進める。plain valueとready Ticketは同期laneと同じcompletionを使用する。
blockが一度もsuspendしなければcontinuation、callback、deferredを作らない。

### 5.2 最初のpending

最初のpendingを検出した時点で、stack上のblock状態をheap continuationへ昇格する。現在までの
native outputを移し、pending fieldのdestination、path、completion metadataをslotへ保存する。

queryの残りのsibling opsは起動を続け、同じcontinuationへpending slotを追加する。これにより
GraphQL queryの並行性を維持する。mutation rootは既存どおり次のopを起動せず逐次再開する。

### 5.3 再開

pending slotのsettlementでは値の格納と`unresolved`の減算だけを行う。0になったcontinuationを
ready queueへ積み、drain側でcompletionを行う。subscriber callback内で再帰的にblockを
完走させない。

settled値をcompletionした結果、新しいpending child block/list itemが現れた場合は同じ
continuationを再度suspendできる。すべて同期ならsync loopへ戻り、そのままblockを完走する。

## 6. Ownershipと安全性

- continuationがsource、path、parent、output frameを明示的に所有する
- subscriberはcontinuation全体ではなくpending slotの安定した識別子を参照する
- slot配列の再配置後にraw pointerをsubscriberへ保持しない
- abandoned requestはexec stateからcontinuation treeを一括解放できる
- callback例外は現在のfield pathを持つerror outcomeへ変換する
- settle中のreentrancyではready queueへ積むだけとし、同じcontinuationを二重drainしない
- Promise/Ticketがself-resolutionまたは複数settleしてもslotを二重完成しない

request arenaはcontinuationの形と破棄規則が固まった後に導入する。最初の実装では既存の
refcountとframe poolを使い、性能差とownershipを独立に検証する。

## 7. 段階移行

1. sync/asyncで重複するop loopとresolve/completion境界をhelperへ抽出する
2. query rootで一度もpendingが出ないblockをsync loopで完走させる
3. root blockのpending field 1個をcontinuationとして中断・再開する
4. 複数sibling pendingをblock continuationへ集約する
5. resolved plain-hash objectのchild blockをsync loopで完走させる
6. object listのitem continuationを集約する
7. abstract、nested list、non-null propagationを新経路へ広げる
8. generic Promise adapterをTicket slotと同じ再開形式へ統合する
9. coverageと性能が揃った範囲から旧async frame処理を削除する
10. allocationが再び上位ならrequest arenaを導入する

各段階はfallback可能な独立PRとし、先に旧経路を削除しない。

## 8. 性能基準

比較対象は同じnative program、resolver、変数、出力形式を使う`strict_sync`とasync runtime。

- Promise/Ticketなしのasync runtime: sync比95%以上
- ready Ticket: sync比90%以上
- DataLoader dispatch 1回、その後同期child fields: sync比80%以上
- 対象workloadで最低5%改善
- generic Promise、repeated、primed、errorで2%以上の安定退行を出さない

width 1、10、20、100、unique/repeated/primed/cold、SV/JSONを測る。loader単体の改善だけでは
採用せず、GraphQL end-to-endを主指標にする。

## 9. ここまでの経緯

async高速化では、最初にPromise処理そのものとGraphQL executor内部のどちらが支配的かを
切り分けた。Promise::XSをTicketへ置き換える案、TicketをXS実装してPerl callback層をなくす案、
ready値を`AWAIT_IS_READY`/`AWAIT_GET`で同期取得する案を試した。

TicketはDataLoader内部のready cache entryには有効だった。一方、GraphQL request全体では
Ticket用のsubscription、settlement、Promise adapterと、既存Promise::XS経路の二系統を維持
する必要がある。Promise/Ticketの種類を変えるだけでは、async executorがrequest開始時から
作るexec state、frame、pending entry、callback、outcomeを除去できない。このためTicketを
request全体の非同期表現にする案は、性能差に対して実装・保守コストが大きいと判断した。

その後の計測で、同期resolverを含むasync runtimeも最初からasync executorへ入ることが主要な
固定費だと分かった。asyncとsyncの経路が異なる理由は、resolverがpending値を返した後も
source、path、出力先、次のopを保持する必要があるためである。ただし、その状態保持は実際に
pending値が現れるまで必要ない。ここから「async executorを軽量化する」より「sync executorを
開始点にして、pending時だけcontinuationへ昇格する」方針へ移った。

他言語処理系との比較では、この方式をHoutou固有の発明とは扱わないことにした。C#の完了済み
awaitable、Kotlinの`COROUTINE_SUSPENDED`、Rustの`Poll::Ready/Pending`、LLVM coroutineの
frame loweringと同型である。GraphQL固有の点はresolver call siteがsuspend候補だとcompile時に
分かっても、そのresolverがplain valueとPromiseのどちらを返すかはrequest時まで確定しない
ことである。したがってresolver call siteを動的なpromotion境界にする。

## 10. 現在までの実装

`perf/sync-first-continuation`ブランチでは、次の順番で実装した。

1. 本文書でsync-firstの状態遷移、ownership、段階移行を定義した。
2. fast lane stateへ`fast_lane_can_suspend`と`fast_lane_suspended_sv`を追加した。
3. Promiseを検出したresolverは、suspensionが許可されたlaneではPromiseの所有権をsuspension
   channelへ移し、block loopを安全にunwindできるようにした。strict sync laneのcroak動作は
   維持した。
4. settled値を受け取りresolverを再実行せずcompletionだけを行う
   `gql_runtime_vm_complete_resolved_current_fast_sv`を抽出した。
5. SV出力、rootが単一field、runtime directiveなし、nullableなgeneric leafという限定条件で
   root continuationを実装した。
6. Promiseが呼出し中にsettleする場合は完成したresponseを同期的に回収し、本当にpendingなら
   Promise callbackが保存したblock/op/slotからcompletionを再開するようにした。
7. resolve/reject callback、runtime、program、schema、root、context、prepared variablesの
   ownershipをmagic destructorへ集約した。

対応するコミットは次のとおり。

- `7a05e7f` `Document sync-first execution design`
- `a891f37` `Add fast lane suspension channel`
- `6170274` `Extract fast lane resume boundary`
- `4ca673a` `Resume pending root leaf fields`
- `94ce5ec` `Benchmark pre-resolved async leaves`

追加した回帰テストは、pre-resolved Promiseが同期responseになること、pending Promiseが
settle後にresponseへなること、suspend前とresume後を通じてresolverが一度しか呼ばれないことを
確認する。この時点で全486テストとXS ownership lintが通っていた。

8. GraphQL::HoutouはPSGI前提の同期Webアプリであり、Promise::XS/Ticketは実行時間の
   重畳ではなくDataLoaderバッチ解決のためだけに存在するという前提を踏まえ、汎用
   Promise::XSサポートより実際の主要トリガーであるDataLoader Ticketの統合を優先した
   (詳細は`docs/future-performance-investigation-ja.md`の§14.16)。
   `gql_runtime_vm_fast_lane_guard_promise_sv`にTicket認識を追加し、fulfilled/rejected
   なTicketはsuspension channelに触れず即座に値/errorへ展開する。genuinely pendingな
   Ticketのみ、Perlメソッド`then`経由ではなく`gql_runtime_vm_subscribe_dataloader_ticket`
   を直接呼ぶ経路へ合流させ、`Promise::XS::deferred()`を合成してAPI互換
   (`_settle_result`が見る`isa('Promise::XS::Promise')`契約)を保った。
9. 本節の次ステップ1に挙げていたresolve/reject継続ctxの共有を実施した。
   `gql_runtime_vm_pending_callback_ctx_t`と同じ`cv_refcnt`パターンを移植し、
   1 suspendあたりのctx確保を2回から1回(`newSVsv`は12回から6回)へ減らした。

追加した回帰テストは、単一root leaf fieldがfulfilled/pending/rejected Ticketをそれぞれ
返す3ケース、strict syncレーンでpending Ticketも引き続きactionableなcroakになること、
200回のpending Ticket駆動継続を連続実行してもframeがリークしないことを確認する。
現時点で全489テストとXS ownership lintが通る。

10. §13(旧稿)step 6として、settle callbackのresume経路を既存の汎用async executorの
    `block_frame_t` + scheduler(`enqueue_frame`/`drain`/`process_frame`/`resolve_frame`)
    へ委譲する試作を行った(詳細・計測値は`docs/future-performance-investigation-ja.md`
    §14.17)。正しさは検証できた(300件の独立したroot leaf継続が1回のDataLoader batch
    dispatchで一括settleするstress testも含めASanでクリーン)が、settleのたびに
    `exec_state_handle_t`/heap writer/block_frameを確保しnative_value_t経由の
    往復変換を追加するコストが、Promise::XS pre-resolvedケースで-7.0%、Ticket
    pending(on_stall経由)ケースで-2.6%の実測retreatとして現れた。「正しさの検証が
    目的」というPhase 2自身の位置づけに対して無視できない規模だったため、ユーザーの
    判断でこの試作は単独採用せず、複数sibling pending fieldへの拡張(旧稿の
    step 3-5、後述の複数siblingサポート)を実装する段階まで延期した。単一fieldの
    resumeはsettle_svによる直接構築(item 5-9の状態)へ戻している。副産物として
    見つかった`gql_runtime_vm_native_value_t`のUTF8フラグ欠落バグ(resolverが返した
    Unicode文字列がPromise/Ticket経由でこの型を通ると、rootリーフに限らず既存の
    汎用async executor全体でUTF8フラグが失われていた)の修正は、Phase 2の採否とは
    独立に価値があるため採用した。

11. §13(旧稿)step 3/5として、rootが複数のnullable scalar/enum leaf siblingを
    持つ場合への拡張を実装した(詳細は`docs/future-performance-investigation-ja.md`
    §14.18)。eligibility guardをop_count==1からop_count>=1へ緩和し、ブロック内の
    **全op**が既存の単一field条件を満たすことを要求、さらに「bundle上のop_countが
    native_program上のop_countと一致する」というblock単位のチェックを追加した
    (静的directiveでの部分的なop削除がbundle/native_program間のop_indexズレを
    起こしうるため)。suspendしたsiblingは既存の`GQL_VM_PENDING_PROMISE_(GENERIC|
    RESOLVED)_VALUE_SV`entryとしてpushし、最初のsuspend時にのみ実
    `exec_state_handle_t`/`block_frame_t`へ遅延promotionした上で、汎用async
    executor自身のroot frame finalizeが使っている`gql_runtime_vm_block_frame_finalize_sv`
    (arm前に`async_scheduler_draining`を立てる、という既存のreentrancy-safeな
    idiomを内包する)へそのまま委譲する設計とした。専用のctx/callback型は新設して
    いない。単一fieldの場合(Phase 2で退行が出た形)は引き続きitem 5-9の軽量な
    直接構築方式を使う。

    正しさは複数sibling同時pending・reject混在・pre-resolved Promise::XSと
    pending Ticketの混在(arm中の同期settleを経由)・50件の独立requestが1バッチで
    settle・non-null/directive/静的prune各fallback、で確認し、全492テスト・49
    ファイル個別実行でのASan(複数hash seed)がクリーン。全同期の場合は
    sync runtimeと完全に同速(sync-first原則は維持)。ただし、旧executorへの
    fallbackに対する測定可能な性能改善は確認できなかった(§14.18参照 —
    promotion時の`data_hv`→`native_value_t`一括変換コストが、fast laneでの
    安価な resolver 呼び出しの利益を相殺していると見られる)。ユーザーの判断で、
    正しさ・将来の最適化の土台としての価値を優先しこのまま採用した。

## 11. 試行から分かった境界条件

root fieldが1個で`child_block_index == -1`という条件だけでは、leaf continuationとして安全では
ない。listはchild blockを持たなくても、各itemがPromiseの場合やabstract item completionを
持つ場合がある。最初の試作でlistまで同じ経路へ入れたところ、Star Wars/DataLoaderとunion
searchのitemがnullになり、batchも起動しなかった。

この退行は、root resolverのPromiseがsettleしたことと、その戻り値のlist全体が同期completion
可能であることを同一視したために起きた。list内のpending itemは新しいsuspension pointであり、
root continuationからitem continuationまたは既存async schedulerへ部分昇格する必要がある。
現在は`complete_code == GQL_VM_COMPLETE_GENERIC`へ限定してlistを従来経路へfallbackしている。

もう一つの境界はpre-resolved Promiseである。Promise::XSの`then`はcallbackをその場で実行しても
derived Promiseを返す。そのderived Promiseをそのままpublic APIへ返すと、従来はHashRefだった
pre-resolved requestがPromiseへ変わる。callback pairと共有する小さなsettlement stateを使い、
`then`登録中にresponseまで完成した場合はderived Promiseを破棄して同期responseを返すことで
API互換を維持した。

## 12. 現在の性能

既存の`async_preresolved`はrootがobject listなので、現在の限定continuationには入らない。
計測値は次のとおりで、変更前とほぼ同等である。

```text
async items SV   27.9k/s
async SV         64.5k/s
async JSON       66.0k/s
sync JSON        96.8k/s
sync SV         101.2k/s
```

root leaf専用の`async_preresolved_leaf` benchmarkを追加した。変数を使うresolverが
pre-resolved Promise::XSを返すcaseである。

```text
async leaf SV   274.9k/s
sync leaf SV    414.4k/s
```

現在のasync leafはsync leafの約66%である。汎用async exec stateを作らずに正しく
suspend/resumeできる足場はできたが、sync同等という目標には未到達である。残る固定費の候補は
Promise::XSの`then`、resolve/reject CV、continuation contextと所有SVの割当である。

Ticket統合(本節8, 9)後の5標本中央値は次のとおり(詳細は
`docs/future-performance-investigation-ja.md`の§14.16)。

```text
sync leaf                      412.9k/s (100%)
async leaf (Promise::XS, 既存)  277.7k/s (67.3%)
async leaf (Ticket ready, 新規) 321.5k/s (77.9%)
async leaf (Ticket pending, 新規, on_stall経由) 139.5k/s (33.8%)
```

Ticket readyはPromise::XS pre-resolvedに対して約+15.8%改善した。Promise::XSの`then()`が
既に決着したpromiseに対しても呼び出しごとにderived promise objectを生成するのに対し、
fulfilled Ticketの認識はsuspension channelにもderived objectにも触れず値を直接返すためである。

## 13. 次に進める順序

1. ~~resolve/rejectが別々に保持しているroot continuation contextを共有し、所有SVのrefcount操作と
   heap allocationを減らす。~~ 実施済み(本節9)。
2. leaf benchmarkをallocation profileと合わせて測り、Promise::XS自体の下限とHoutou側の固定費を
   分離する。
3. settled root listを走査し、全itemがplainならfast completion、pending itemが1個でもあれば
   item continuationまたは既存async schedulerへ部分昇格する境界を作る。**未着手**。
4. `async_preresolved`のroot object listへ適用し、sync比と旧async比を測る。**未着手**(3が前提)。
5. ~~nullable leaf/listでownershipが固まってからnon-null propagation、runtime directives、
   object child block、複数root siblingへ対象を広げる。~~ **複数root siblingは実施済み**
   (leafに限定、本節item 11)。non-null propagation・runtime directives・object child block
   は引き続き未着手(混在時はfallback)。
6. ~~Promise callback内でcompletionを再帰実行する形はroot単一fieldに限定し、複数siblingへ
   広げる段階ではready queueへ統合してreentrancyを防ぐ。~~ 実施済み(本節item 10で単独試作、
   item 11で複数sibling実装に組み込んだ形で採用)。

GraphQL::HoutouはPSGI前提の同期Webアプリで、実際にsuspendが起きる主因はDataLoader
バッチ解決(Ticket)であり、任意のresolverが返す汎用Promise::XSは相対的に稀なケースである。
そのため上記の順序に加えて、DataLoader Ticketの認識・直接subscribe・継続ctx統合(本節8, 9)を
先行させた。

6は単独で試作・計測した段階(本節item 10、詳細は`docs/future-performance-investigation-ja.md`
§14.17)では、settleごとの`exec_state_handle_t`/heap writer/block_frame確保と
native_value_t往復変換のコストがPromise::XS pre-resolvedで-7.0%、Ticket pendingで-2.6%の
実測retreatとなり、単独採用するには重すぎると判断して延期した。宣言通り、5(複数root
sibling、leafに限定)を実装する段階(本節item 11)で6のblock_frame_t/scheduler委譲を
組み込んだところ、全同期ケースはsync runtimeと完全に同速(退行なし)だったが、
suspendが起きるケースでも旧executorへのfallバックに対する**測定可能な改善は
確認できなかった**(§14.18)。1つの`block_frame_t`確保コストをsibling数で償却できる
という見込みは外れ、promotion時の`data_hv`→`native_value_t`一括変換コストが
fast laneでの安価なresolver呼び出しの利益を相殺していると見られる。ユーザーの
判断で、正しさ・将来の最適化の土台としての価値を優先しこのまま採用した。

次に性能改善を狙うなら、`data_hv`を経由したPerl SVの一括変換をなくし、fast lane
ループ中に解決済みsiblingを直接`native_value_t`へ書き込む設計へ作り直す必要がある。

12. 上記の宿題を実施した(詳細は`docs/future-performance-investigation-ja.md`
    §14.19)。ブロックループの返り値を`data_hv`のRVから、呼び出し側が確保した
    `SV **resolved_values`配列(op位置でindexし、解決済みの値を直接格納)へ変更。
    `frame`が作られなかった(全同期)場合のみループ後に`data_hv`を組み立て、
    `frame`が作られた場合はdata_hvを一切経由せず`resolved_values[]`から直接
    `frame->values_value`へ書き込む(plan所有のフィールド名をborrowedで渡すため、
    従来`gql_runtime_vm_native_value_from_sv`が行っていた名前の二重コピーも
    なくなった)。5標本中央値で、旧executorへのfallback比 width 5で+2.1%、
    width 10で+1.6%の改善を確認(width 2はほぼ横ばい)。全492テスト、ASan
    (49ファイル個別実行・複数hash seed)、unicode文字列siblingのUTF8保持、
    promotionありなしを混ぜた1000回のリーク検証で確認済み。

旧async executorはfallbackとして残す。対象shapeが明示的に判定でき、correctnessと性能の両方を
満たした範囲だけをsync-first経路へ移す。
