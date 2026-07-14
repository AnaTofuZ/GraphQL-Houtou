# パフォーマンス・堅牢性計画 v3 (2026-07-14)

v2 の R1/R4/P1(第 1〜2 弾)消化後の再調査。P1 第 1 弾(mode 1 直通 =
pending 子ブロックの frame handle 化、PR #40)と第 2 弾(pending entry の
直接購読 = 中間 identity-then 除去、PR #42 draft)を踏まえ、コードベースを
再点検して「バグ」と「残りの速度レバー」を洗い直した。

## 現状の実測 (PR #42 適用後、同一マシン A/B)

| lane                                    | req/s      | 備考 |
|-----------------------------------------|------------|------|
| sync (execute, 20件×3フィールド)        | ~95k       | |
| async pre-resolved(list 全体 promise)  | **53.3k**  | 51.9k → +2.7%(#42) |
| async per-item promise(items_sv)       | **24.6k**  | sync の 1/4。最遅レーン |
| 多段 DataLoader(posts→author→team)     | 8.5–8.8k   | 6.6–7.8k → ~+20%(#42) |

## B: バグ(調査で確認・確定したもの)

### B1. 【確認済み・deadlock】armed pending entry の stale entry_index

**同一フレームに「即時解決される promise フィールド」と「loader promise
フィールド」がこの順で並ぶとデッドロックする。main でも再現する既存バグ。**

- repro: `{ parent { fast slow } }`、parent は loader 経由(= 子フレームが
  drain 中に finalize される)、`fast` は `Promise::XS::resolved(...)`、
  `slow` は loader。→ `GraphQL execution stalled: ... on_stall made no
  progress` で die。`{ slow fast }` 順なら成功(メカニズム確定の傍証)。
  scratchpad の repro_stale_index.pl / repro_swapped.pl。
- メカニズム:
  1. 子フレームの arm 中に `fast` の preresolved promise が**同期 settle**
     し、`pending_unresolved` が一時的に 0 → frame が ready queue へ
     (drain 中なので処理は後回し)。続けて `slow` が arm され
     unresolved=1 に。
  2. drain がその frame を process → `fast` の READY entry を消費し、
     armed のままの `slow` entry を next_pending に**前詰めで再 push**
     (index 1 → 0)。しかし then コールバックの ctx は旧 index(1)を
     保持したまま。
  3. `slow` settle 時、xs_pending_callback の bounds check
     (`entry_index >= pending_count`)に落ちて**値が黙って捨てられ**、
     entry は永遠に未解決 → on_stall が進捗 0 を返しデッドロック報告。
- 実運用で踏みやすい: DataLoader の prime 済みキャッシュヒット +
  未キャッシュの混在、即値 promise を返す軽量フィールドとの混在など。
- **修正案**: pending entry に armed callback ctx へのバックポインタを
  追加し、process_frame の再 push 時に `ctx->entry_index` を新 index に
  更新する(settle / consume 時にクリア)。回帰テストはフィールド順
  両方(fast→slow / slow→fast)+ primed loader 混在形状を t/ に追加。

### B2. 【防御】resolve_frame 親通知の範囲外 index は outcome を黙って捨てる

`parent_entry_index >= pending_count` の場合、outcome はどこにも格納されず
フィールドが silent に欠落する(現状 B1 修正後は到達不能のはずだが、
到達したら data 破壊なので croak / warn の防御を入れる)。B1 と同時に対応。

### B3. 【#42 で修正済み】raw PROMISE_SV entry の rejection deadlock

旧 arm の error callback は outcome を「破棄済みの派生 promise」に返す
だけで entry に届かなかった。PR #42 の reject callback 直書き化で解消。

## P: 高速化(async_items 形状 24.6k/s の leaf プロファイルに基づく)

プロファイル上位: malloc/free churn(最大)、Perl_hv_common +
gv_fetch(`call_method("then")` のメソッド解決)、Perl_sv_clear、
newXS + sv_magicext(callback CV 生成)、create/delete_eval_scope
(then 呼び出しごとの G_EVAL)。

### P-A. callback CV のプール化(最優先・items 形状に最大効果)

pending/reject callback(arm 時に entry ごと)と list_pending / list item
child callback(item ごと×2)を毎回 newXS + magic で生成している。
items 20 件で 40+ CV/リクエスト。free-list で CV+ctx を再利用し、
newXS / magicext / cv_undef のコストと malloc churn を削る。

### P-B. then 呼び出しの最適化

`call_method("then", ...)` は毎回 gv_fetchmethod でメソッド解決する。
起動時に `Promise::XS::Promise::then` の CV を解決してキャッシュし、
promise の class が Promise::XS::Promise のときは `call_sv` 直呼びに
切り替える(他クラスは従来経路)。プロファイルの gv_fetch ~180 samples
相当を除去。

### P-C. object field 名の borrowed 化(v2 からの持ち越し)

native_object_store が field 名を per-field で savepv/free している
(native_value_destroy ~11%)。実行プランの slot 文字列を borrowed flag
付きで参照する。sync / async 両方に効く。

### P-D. response deferred の削減

async 実行は常に response 用 deferred + promise + then(materialize) を
作るが、on_stall で同期完走する経路(execute の主用途)では promise を
返す必要がない。完走経路では deferred を作らず直接 materialize する。

## 実施順序

1. **B1 + B2**(バグ優先。deadlock の実バグなのでリリース前必須)
2. P-A(callback CV プール)
3. P-B(then CV キャッシュ)
4. P-C(field 名 borrowed 化)
5. P-D(response deferred 削減)
6. (P1 完了後)README の graphql-perl(upstream)速度比較の復活検討

各ステップの検証: `rm lib/GraphQL/Houtou.o lib/GraphQL/Houtou.c && perl
Build` → minil test → soak-test.pl → execution-benchmark-checkpoint.pl
(--include-async --case async_preresolved)+ 多段 DataLoader A/B。

目標は v2 と同じく async hot path 80k/s(現在 53.3k)。
