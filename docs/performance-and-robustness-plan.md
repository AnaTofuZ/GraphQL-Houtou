# パフォーマンス・堅牢性改善計画

> **2026-07-06 以降の優先順位は `docs/product-roadmap.md` を正とする。**
> この文書は当時の調査・計画記録として残す。

作成日: 2026-07-04

Web アプリケーション(prefork PSGI / 長時間稼働 worker)での利用を前提に、
per-request スループットの向上と、メモリリークのない堅牢な実装を目指す計画。

前提となる既知の知見:

- XS ↔ Pure Perl の境界往復(callback / frame 処理)は大幅な劣化要因
- sync native fast lane 自体は high-watermark 水準に収束済み
  (`docs/current-context.md`)。残る主戦場は「境界コスト」と「実トラフィック
  で初めて現れるコスト」

---

## 1. 現状ベースライン(2026-07-04 計測)

| 経路 | スループット | 備考 |
|------|-------------|------|
| `execute_bundle`(固定 query) | 約 60〜71 万 req/s | checkpoint 水準 |
| `execute_program` + **固定** variables | 約 22 万 req/s | 既存ベンチが測っているのはこれ |
| `execute_program` + **毎回異なる** variables | **約 6.1 万 req/s** | 実 Web トラフィック相当。固定比 **3.5x 遅い** |
| `execute_bundle` + JSON::MaybeXS encode | JSON が全体の **約 22%** | list-of-20-objects クエリ |
| async(Promise::XS) | 約 12〜18 万 req/s | `docs/current-context.md` 記録値 |

### 発見 1: variables 依存の per-request specialization(最重要)

`NativeRuntime::execute_program` の variables あり経路は毎リクエスト:

1. `_specialized_variables_cache_key` が **変数ハッシュ全体を Perl で再帰的に
   文字列シリアライズ**してキャッシュキーを作る
2. キーが未ヒットなら native program を **clone → specialize → キャッシュ格納
   (FIFO evict)**

既存ベンチマークは毎回同じ変数を渡すためキャッシュヒット率 100% でこのコストが
見えないが、実際の Web トラフィック(リクエストごとに異なる ID 等)では
**ミス率 ~100%** になり、clone/specialize/evict churn が発生する。

これは速度だけでなく堅牢性の問題でもある:

- 変数のカーディナリティが高いと specialized cache(既定 max 1000)に
  **program clone が最大 1000 個滞留**する(メモリ保持)
- キー文字列は変数値をそのまま埋め込むため、**キーサイズが入力に比例して
  無制限**(巨大な入力オブジェクトでメモリ・CPU 双方に効く)
- eviction churn による割り当て圧力

### 発見 2: レスポンス JSON 化が全体の ~22%

現在は native value → Perl の `{data => ...}` envelope → ユーザー側 JSON encode
の 2 段。native value 表現から直接 JSON バイト列を書ければ、envelope の SV
materialize 自体も丸ごと省ける(効果は 22% より大きい)。

### 発見 3: input object coercion の XS→PP→XS 往復

すべての入力 coercion(リテラル引数・変数・ネスト変数)は
`gql_runtime_vm_coerce_input_value_sv` → **Perl の `graphql_to_perl`** に
集約されている。input object を使う Web アプリでは per-request で
XS→PP→XS の境界往復が発生する(まさにユーザー既知の劣化パターン)。

### 発見 4: 堅牢性ゲートの不備

- `util/leak-check.pl` の対象ケースが **legacy-tests に移動済みの旧テスト**
  (t/03, t/04, t/11, t/12)を参照しており、active mainline を検査していない
- CI は `test.yml` のみで、**ASan / leaks のリークゲートが存在しない**
- handle クラス(ExecState / Outcome / NativeProgram 等)に `CLONE_SKIP` が
  なく、ithreads 環境で XS handle が複製されると未定義動作
  (`docs/ecosystem-feature-gap.md` §9.1 の既知問題)

### 発見 5(小粒)

- `execute_document` のキャッシュミス時、depth limit チェックで 1 回 parse し、
  `compile_program` で再度 parse する(**二重 parse**)
- `_make_bool` が boolean リテラルごとに `JSON::MaybeXS::true()` を呼ぶ
  (BOOT 時 singleton 化可能)
- Role::Tiny の `DOES` 呼び出しは boot / introspection の cold path のみ
  → 対応不要

---

## 2. フェーズ計画

順序の意図: **リークゲート(Phase B)を大きな XS 変更(C 以降)の前に整備**
し、以降の各フェーズを既存の benchmark gate + 新設 leak gate の両方で
keep/revert 判断できる状態にする。

### Phase A: variable-invariant 実行の徹底(P0・最大の実効改善)

1. checkpoint ベンチマークに **varying-variables ケース**と
   **execute+JSON ケース**を追加(現状のベンチは実トラフィックを見誤る。
   まずゲートを正しくする)
2. per-request specialization を「必要な program だけ」に限定する:
   - compile 時に「variables に依存する runtime directive / dynamic guard を
     持つか」を program にフラグとして焼き込む
   - フラグなし(大多数)の program は specialize せず、variable-invariant な
     cached bundle + request-local prepared variables で直接実行
     (fast lane は既に `ARGS_DYNAMIC` + variables_hv を処理できる)
   - フラグありの program のみ従来の specialize(キーは変数全体ではなく
     **依存する変数だけ**から構築し、サイズ上限を設ける)
3. 期待効果: 実トラフィックで **~3.5x**、specialized cache の滞留・churn 解消

### Phase B: 堅牢性ゲートの整備(P0・以降の変更の安全網)

1. `util/leak-check.pl` を active suite に更新
   (t/15 execute, t/16 promise, t/19 vm, t/29 alias, t/33 oneOf, persisted)
2. CI に **Linux ASan ジョブ**を追加(`--backend asan`)。macOS leaks は
   ローカル運用のまま
3. **soak テスト**(`util/soak-test.pl`)新設: 長時間 worker を模した
   数百万リクエストのループで RSS 成長をアサート。対象:
   - program cache / specialized cache の eviction 経路
   - async(Promise::XS)経路
   - **エラー経路**(error record / path frame の解放漏れが出やすい)
   - resolver 内 die / croak の例外安全性(部分構築 struct の解放)
4. `util/lint-xs-ownership.pl` を CI に組み込み
5. XS handle クラス群に `CLONE_SKIP { 1 }` を追加(ithreads での複製事故防止)
   + POD に ithreads 非サポートを明記

### Phase C: `execute_to_json` fast lane(P0)

1. native value tree から直接 JSON バイト列を書き出す
   `execute_document_to_json` / `execute_bundle_to_json` を XS 実装
   (direct-SV 1 パスと同じ発想の direct-JSON 1 パス)
2. errors がある場合のみ envelope 経路にフォールバック
3. 期待効果: JSON encode の ~22% + envelope materialize 分。
   PSGI アダプタ(ロードマップ第2段)はこれを既定経路にする

### Phase D: input coercion の native 化(P1)

1. compiled schema(kind / fields / is_one_of は既に XS 側にある)を使って
   input object / list / enum / 組み込み scalar の coercion を
   `src/vm_runtime.h` 内で完結させる
2. PP へのコールバックは **custom scalar の `parse_value` のみ**に限定
3. oneOf チェックも native 側に移す(現在は graphql_to_perl 内)
4. `execute_document` の二重 parse 解消(depth check と compile で AST を共有)
   と、string→result 全体の XSUB 単一入口化もここで実施

### Phase E: async path の継続改善(P1)

`docs/current-context.md` の残課題をそのまま引き継ぐ:

1. ownership provenance を持たせた clone 削減
2. object / abstract completion の内部表現を raw/native 寄りに
3. Promise::XS continuation / batch continuation の further specialization

sync (60万/s) と async (12〜18万/s) の差は DB アクセスのある実アプリで
体感を支配するため、Phase D 完了後の主戦場。
(将来の幅優先実行モード = DataLoader バッチングの受け皿もこの層に載せる)

### Phase F: boot / deploy 最適化(P2)

1. スキーマの boot-time コンパイルキャッシュ
   (native runtime descriptor の dump/load は既存。file 化 + 起動時 load で
   prefork worker の起動コストと CoW 共有性を改善)
2. `_make_bool` の bool singleton 化などの小粒バッチ

---

## 3. 運用ルール

- 各フェーズは従来どおり **benchmark gate**(checkpoint 中央値、
  Phase A で追加する varying / json ケースを含む)で keep/revert 判断
- Phase B 以降は **leak gate**(ASan CI + soak の RSS アサート)を必須通過条件に
- checkpoint 結果は `docs/current-context.md` に追記(既存運用踏襲)

## 4. 期待値まとめ

| フェーズ | 対象 | 期待効果 |
|---------|------|---------|
| A | 変数付き実 Web トラフィック | ~3.5x + メモリ churn 解消 |
| B | 長時間稼働の安全性 | リーク回帰の CI 検出、ithreads 事故防止 |
| C | execute + serialize の実効値 | +25〜40%(envelope 省略込み) |
| D | input object を使うリクエスト | 境界往復の除去(クエリ形状依存) |
| E | async / DB アクセスあり | sync との差(現状 3〜4x)の縮小 |
| F | worker 起動・メモリ共有 | 起動時間短縮、CoW 改善 |

## 関連文書

- `docs/current-context.md` — runtime/VM の checkpoint 履歴
- `docs/first-release-roadmap.md` — 機能面のロードマップ(§2 が本計画の前身)
- `docs/memory-leak-check.md` — leak harness(Phase B で更新対象)
