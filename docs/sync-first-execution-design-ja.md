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

## 9. 最初の実装範囲

最初の変更ではcontinuationそのものを導入せず、query blockのop loopから
「1 opを同期resolve/completionしてnative outputへ格納する」処理を共通helperへ切り出す。
sync laneの出力と性能を保ち、async側がplain value/ready Ticketに同じhelperを使える境界を
作る。

この共通化だけで性能が下がる場合は採用せず、inline可能なstatic helperまたはmacroへ調整する。
意味論を変えずに共通境界を確立してから、pending検出時の昇格を次の変更で実装する。
