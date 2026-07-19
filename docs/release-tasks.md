# リリースまでの残タスク (2026-07-16 改訂)

> **履歴資料:** セキュリティ・メモリ安全性対応の詳細な作業記録として残しています。
> 現在のリリース判断、完了項目、残ブロッカーは
> [`production-release-audit-2026-07-18.md`](production-release-audit-2026-07-18.md)
> を正とします。

P0 仕様適合(validation 結線 / エラー envelope / 結果コアーション /
Non-Null 伝播)は `feature/p0-spec-conformance` で完了。この文書は
**そこから先**の残タスクを、セキュリティ・XS 堅牢性を含めて優先度順に
まとめる。`docs/release-readiness.md`(P0 前の評価)を置き換える。

各項目の状態は実測プローブで確認済み(スクラッチパッドの再現コードは
本文に要点を残す)。

## S. セキュリティ(リリースブロッカー)

開発者判断で**リリース前に必ず修正**。S1 は実証済みの脆弱性。

### S1. パーサのスタックオーバーフロー(未認証 DoS)★実証済み

- **症状**: 深くネストしたクエリで parse が SIGSEGV。8MB スタック
  (既定)で **約 35,000 段**、`{a{a{...` の約 70KB で落ちる。値の
  ネスト `[[[...` は約 100,000 段。
- **深刻度**: 未認証の 1 リクエストでワーカープロセスが即死。
  `gql_parse_selection_set` / `gql_parse_value`(src/parser_graphqlperl_
  runtime.h)の C 再帰がスタックを食い尽くす。
- **既存防御が効かない**: depth-limit(既定 15)は **parse の後**に
  走る。実測: 既定設定の `execute_document` に 35,000 段クエリ →
  SIGSEGV。depth-limit は一切保護にならない。
- **修正**: `gql_parser_t`(src/bootstrap.h)に `depth` カウンタを足し、
  `gql_parse_selection_set` / `gql_parse_value` の入口で increment /
  出口で decrement、上限(例 500〜1000。graphql-js の実運用上限相当)
  超過で `gql_throw` で**クリーンにエラー**(request error として
  envelope 化)。上限は控えめに固定 + 将来オプション化。
- **テスト**: t/ に「上限+1 段は request error、上限段は通る、SIGSEGV
  しない」を fork 分離で固定。ASan でも回す。

### S2. リクエストサイズ上限

- **PSGI**: `_read_body` が `CONTENT_LENGTH` を信じて全部読む。上限なし
  → 巨大ボディでメモリ枯渇。`max_body_size`(既定 1MB 程度)を追加し、
  超過は 413。`CONTENT_LENGTH` 詐称にも実読バイト数で防御。
- **パーサ**: ソース長の上限(例 既定なし〜数 MB)と**トークン数上限**
  (graphql-js の `maxTokens` 相当)。S1 の深さ上限と別軸で、横に長い
  入力(巨大なフィールド列)を切る。

### S3. クエリ複雑度 / alias flooding

- depth-limit はあるが**横方向の爆発**に上限がない。
  `{a:f b:f c:f ...}` × ネストで応答/計算量が指数的に膨らむ。
  最大ノード数上限(素朴でよい)か複雑度スコアを validation に追加。
  本格的なコスト重み付けは P1 でよいが、**素朴なノード数上限は S**
  (DoS 面なので)。
- fragment 爆発は cycle 検出で概ね塞がっているが、alias × fragment
  spread の組合せをノード数上限で確実に閉じる。

### S4. セキュリティ回帰の CI 化

- S1〜S3 の上限を robustness.yml に敵対的入力テストとして常設
  (深いネスト・巨大ボディ・alias flooding・不正 UTF-8・NUL 埋め込み・
  巨大数値リテラル)。ASan ビルドで回して「クラッシュしない」を保証。

## R. XS 堅牢性(リリースブロッカー相当)

C 実装の面積が大きく(Houtou.xs ~11k 行 + src ~9k 行)、信頼できない
入力に直接晒される。以下はメモリ安全性の網羅性を上げる作業。

### R1. パーサ fuzz スモーク

- 既存 fixture(kitchen-sink 等)を種にランダム変異(切詰め・バイト
  反転・重複挿入・不正 UTF-8)を数万件、ASan ビルドで流すスモークを
  util/ に追加。クラッシュ = ワーカー死なので最優先の網羅手段。
- 定型ケース(不正 UTF-8、NUL 埋め込み、深い括弧、巨大数値リテラル、
  未終端文字列、サロゲート単独)を t/ に固定。
- robustness.yml(ASan)に組み込み継続実行。

### R2. ASan CI のシード掃引

- 現状 robustness.yml の ASan は 1 シードのみ。HV 反復順がプールの
  並びを変え、未初期化読みの発火はシード依存(#45 の実績)。
  `PERL_HASH_SEED` を 1〜20 程度で回すマトリクスにする。
  実行者環境で `#45` 型の flake を早期検出するため必須。

### R3. コンパイラ警告ゲート

- 現状 `-Wno-error=implicit-function-declaration` で緩めている。
  `-Wall -Wextra`(最低 `-Wunused-function` / `-Wshadow` /
  `-Wundefined-internal`)をコンパイル時ゲートに。死コード削除で
  clang は既に clean(parser/IR レガシー変換の未使用 static は
  cleanup ブランチで解消済み)なので、gate 化のコストは低い。

### R4. exec/scheduler の再帰上限

- fast SV / fast JSON 実行器はオブジェクト階層ごとに C 再帰する。
  現状は depth-limit(parse 後 validation)が実質の防御だが、
  **S1 修正でパーサ深さを 500〜1000 に制限すれば実行深さも同時に
  上限される**(ネスト深さ ≥ 実行深さ)。S1 を入れれば R4 は自動的に
  カバーされる想定。要確認:validation を skip する
  `validate => 0` 経路でも parse 上限が効くこと(効く。parse は必ず
  通る)。

### R5. valgrind / LeakSanitizer の一回転 — 完了(2026-07-18、残 3 件すべて修正)

macOS は valgrind/LSan 非対応のため arm64 Linux コンテナ(perl 5.40 +
valgrind 3.24)で全テストを valgrind にかけた(`PERL_DESTRUCT_LEVEL=2`
+ `util/valgrind-perl.supp` で interpreter ノイズを抑制、definite/
indirect leak のみを error に)。**注意**: マウントした macOS ビルド
成果物を使うと XS ロードに失敗して「空の clean」になるため、必ず
コンテナ内でツリーをコピーして再ビルドすること。

見つかった leak:

1. **abstract_child_names の未解放**(修正済み・valgrind で 0 確認)。
   `char**` の各文字列を parse/clone は個別確保するのに destroy は
   配列だけ `Safefree` していた。program cache で bounded だったため
   RSS soak では出なかった。共通ヘルパ
   `free_op_abstract_child_names` で両 destroy 経路を修正。
2. **async nested block frame の leak(未修正・追跡中)**。t/36 /
   t/40 の DataLoader/promise 経路で 1 リクエストあたり稀に発生
   (per-request unbounded ではない。soak +416KB/20k がその証左)。
   valgrind スタック(definitely lost 88B direct + 632B indirect):

   ```
   gql_runtime_vm_new_block_frame_struct
   gql_runtime_vm_exec_state_execute_block_async_path_sv
   gql_runtime_vm_exec_state_complete_async_sv
   gql_runtime_vm_exec_state_execute_current_op_async_sv
   gql_runtime_vm_exec_state_execute_block_async_path_sv
   gql_runtime_vm_execute_native_program_auto_impl_sv
   ```

   nested object 完了で作られた子 block frame が orphan 化(refcount
   が 0 に落ちない)。async スケジューラの refcount/ownership は
   xs-coding-rules.md 5〜7 の最高リスク領域なので、静的読解での
   拙速修正は use-after-free を招く。専用セッションで instrumentation
   (frame alloc/free のトレース)を入れて追うべき。
3. **fast_json/execute 経路の path frame leak(未修正・追跡中)**。
   t/35 / t/48 で検出(`new_result_path_frame` ←
   `execute_block_fast_json` ← `execute_bundle_fast_response_json`、
   56B definitely lost)。**単一クエリでは再現しない** — scalar /
   list-of-objects / abstract / non-null / introspection / bundle 経路
   を個別に valgrind で試したがいずれもクリーン。複数クエリの相互
   作用(program cache eviction や top-level `execute_to_json` の
   都度 runtime 生成)で稀に発生する疑い。ブラックボックス二分では
   追えず、path_frame プールの alloc/free instrumentation が要る。

   2・3 は 2026-07-18 に原因特定・修正済み(手法: block/path frame の
   alloc/free live カウンタを XS に常設し、macOS 上で valgrind なしに
   決定的再現 → 参照トレースで所有権を特定):

   - **leak 3(fast lane path frame)**: sync fast lane 内からの croak
     (promise 誤設定・実行時引数コアーションエラー)が、再帰各段の
     path frame 参照を longjmp で飛び越えてリークしていた。croak を
     exec state の deferred croak チャネル(`fast_lane_deferred_croak_sv`)
     に載せ替え、レーンを通常のエラー経路で巻き戻してからトップレベル
     エントリで `croak_sv` する方式に変更(エラー文言・分類は完全維持)。
   - **leak 2(async block frame)**: pending のまま放棄されたリクエストは
     「frame → pending entry(promise 保持)→ armed callback ctx →
     exec state(強参照)→ frame」の参照サイクルを形成し、全フレームが
     解放不能だった。さらに context 経由の第 2 サイクル(exec state →
     context → DataLoader → queued deferred → promise → armed callback →
     exec state)も存在。pending response promise に exec state への
     magic を付与し、PP ドライバの放棄地点(deadlock 検出・on_stall
     なし stall)で `cancel_pending_response_xs` がフレーム木の pending を
     再帰クリア+リクエストスコープ参照(context / variables /
     root_value)を解放してサイクルを切る。suspended frame の alloc 参照
     は ExecState DESTROY が `response_frame` 経由で回収。遅延 settle は
     entry-index の bounds check で安全に no-op。
   - **leak 4(新規発見)**: 全テストを valgrind ゲートに載せた際に
     t/40 で検出。specialization が @skip/@include で op を落とす分岐が
     `abstract_child_names` の配列だけを Safefree し、各名前文字列を
     漏らしていた(leak 1 と同じ clone/destroy 非対称クラスの取り残し)。
     `free_op_abstract_child_names` に置換して修正。
   - 検証: t/54(frame live カウンタのシナリオ別ゼロ検証)を追加。
     t/35 / t/36 / t/37 / t/39 / t/40 / t/44 / t/48 すべて終了時
     live カウンタ 0。CI の valgrind ゲートを全テストに拡大。
     soak +480KB/12k(既知残差水準)、async ベンチ回帰なし
     (async_sv 61.9k / async_json 63.4k)。

   **既知の残存制限**: ドライバを介さず pending の response promise を
   受け取ったまま捨てるケース(async runtime の `execute_document` が
   返した promise を settle させずに破棄)は cancel の契機がなく、
   サイクルが残る。通常の利用形態(on_stall 駆動・promise を await)では
   発生しない。

## P1. 運用面の堅牢化(リリース同時か直後)

### P1-1. パッケージング整理

- `Changes` が `minil new` の初期テンプレのまま → 0.01 の変更履歴を
  書く(P0 の 4 項目、死コード削除、SWAPI 例題等)。
- `cpanfile` の runtime 依存監査: `JSON::MaybeXS` / `Promise::XS` /
  `Role::Tiny` は妥当。**graphql-perl(`GraphQL`)を runtime から
  外す**(残っていれば develop フェーズへ)。`Promise::XS` を
  suggests に落とすか(sync-only 利用者に XS 依存を強制するか)判断。
- META provides / no_index、最小 perl(5.24)整合。

### P1-2. 公開 API の POD

- `execute_document` の全オプション(variables / context / on_stall /
  max_depth / validate / root_value)、**エラー形状の 3 分類**
  (request / field / internal)、on_stall 契約と deadlock 条件、
  PSGI(ステータスマッピング)、DataLoader、`GraphQL::Houtou::Error`。
  エラー形状は P0 で確定済みなので今書ける。

### P1-3. CI マトリクス拡充

- 現状 Linux のみ(perl 5.24〜5.42)。開発は darwin なので
  **macOS runner を 1 つ**追加(XS のプラットフォーム差、特に
  DYLD/SIP 周りの実挙動確認)。Windows は任意。

## 完了済み(参考)

- P0-1 validation 結線 / P0-2 Non-Null 伝播 / P0-3 結果コアーション /
  P0-4 エラー envelope(`feature/p0-spec-conformance`)
- 死コード削除・legacy-tests 整理(`cleanup/dead-code`)
- アーキテクチャドキュメント(`docs/architecture-overview.md`)

## リリース後でよい(スコープ外)

- 複雑度の**本格版**(コスト重み付け。S3 の素朴上限で当面十分)
- APQ(SHA-256 persisted queries。基盤は実装済み、結線のみ)
- 性能 L3/L4(async 60.5k→80k、幅優先ハイブリッド)
- `@defer` / `@stream`、Subscription トランスポート、Federation

## 推奨着手順

1. **S1**(パーサ深さ上限)— 実証済み脆弱性。最優先。R4 も同時に閉じる。
2. **S2 / S3**(サイズ・複雑度上限)— 残りの DoS 面。
3. **R1 / R2**(fuzz + シード掃引)— S の修正を守る網。S4 と一体で CI へ。
4. **R3 / R5**(警告ゲート・valgrind 一回転)— 低コストの網羅性向上。
5. **P1-1〜3**(パッケージング・POD・CI マトリクス)— リリース事務。

## 受け入れ基準(リリース判定)

1. 敵対的入力(深いネスト・巨大ボディ・alias flooding・不正 UTF-8 等)で
   **プロセスが死なない**(全て request error か上限エラーで返る)。
2. fuzz スモーク + ASan シード掃引 + soak が CI でグリーン。
3. コンパイラ警告ゼロ(`-Wall -Wextra` ゲート)。
4. valgrind/LSan で既知ノイズ以外の直接リークなし。
5. P0 の受け入れ基準(t/44/47/48/49/50 のレーンパリティ・エラー分類・
   コアーション・non-null)が引き続きグリーン。
