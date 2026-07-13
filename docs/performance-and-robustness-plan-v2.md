# パフォーマンス・堅牢性計画 v2 (2026-07-08)

v1(performance-and-robustness-plan.md)の Phase A〜C と、その後の
L1(DataLoader)/L2(async JSON tail)/W1(PSGI)/#28(async 宣言)を
消化した時点での再検討。前提は v1 から変わらず
**「Web アプリ = DataLoader + Promise::XS が主経路」**だが、
今回はその主経路自体の速度と正しさに焦点を移す。

## 現状の実測 (同一クエリ形状: 20件 × 3フィールドの object list, variables あり)

| lane                                   | req/s   | 備考 |
|----------------------------------------|---------|------|
| sync fast lane (execute)               | 122k    | 変数不変実行 |
| sync fast lane (to_json)               | 120k    | この形状では encode 相当分の差が出ない |
| async lane, pre-resolved promise       | **32k** | **sync の 1/3.8** |
| async lane, loader(promise of array)   | 156k※  | ※L2 計測時。1 promise で配列全体が返る形 |
| persisted bundle (execute)             | 668k    | 参考: 固定クエリ上限 |
| persisted bundle (to_json)             | 899k    | 〃 |

読み取り:

1. **async lane の completion 側だけで sync 比 3.8x のオーバーヘッド**がある
   (pre-resolved は「待ち」ゼロなので、差は全て exec-state/frame/promise
   機構のコスト)。async が主経路である以上、ここが最大のレバー。
2. L2 で判明したとおり serialization tail は async コストの ~5% でしかない。
   伸ばすなら機構そのものを削る(L3)しかない。
3. 「promise of array」(loader が配列ごと返す)は completion が 1 回で
   済むため既に速い。逆に「array of promises」(per-item load)は
   **そもそも壊れている**(下記 R0)。

## R: 堅牢性(リリース前に必須のものから)

### R0. 【バグ・リリースブロッカー】list field × promise 項目 (issue #33)

resolver が `[ map { $loader->load($_) } @ids ]`(promise の配列)を返すと、
async lane の LIST completion が **await 前に** child block を promise を
source に実行し、全フィールドが silent に undef になる
(Houtou.xs COMPLETE_LIST: child 実行が promise 判定より先)。
fast lane も object 型 list では同様、scalar 型 list は JSON lane のみ
croak で止まる。DataLoader の教科書的な使い方が壊れているため
**0.01 リリース前に必須**。修正方針は issue #33 に記載。

### R1. DataLoader API の dataloader-js 整合

`load_many` が「フラットなキーリスト → promise のリスト」になっており、
dataloader-js の `loadMany(keys[]) → 単一 promise` と異なる。arrayref を
渡すと 1 キー扱いで silent に壊れる(本調査で誤用して発覚)。
arrayref 受け取り + 単一 promise 返しに揃え、リスト呼びは deprecate。

### R2. async 経路の croak/reject 監査 + soak シナリオ追加

async が主経路になったので、v1 で sync 側に行った croak 安全化と同等の
監査を async 側に行う:

- batch 関数内 die(全キー reject)→ フレーム/deferred の解放
- `on_stall` フック自体の die(drain 途中)
- late continuation 中の coercion croak / ネスト深い reject
- soak-test.pl に `dataloader_error` / `async_reject` シナリオを追加し
  robustness.yml の RSS ゲートに乗せる(既定シナリオ一覧に入れれば
  CI は自動で拾う)

### R3. リーク残差の回収 (#10 resolver_error ~125B/req, #12 eviction ~110B/req)

L1 で確立した手法(C 側アリーナ走査スナップ + 実行パス二分探索、
`Devel::FindRef`/pmat が C 保持に無力な点、census 攪乱の偽陰性)を
そのまま適用すれば短期で落とせる見込み。優先度は低いが、手法が
温かいうちに片付ける価値がある。

### R4. リリース工程 (R1→0.01)

#31(PSGI)/#32(async 宣言)マージ → PSGI への `async` パススルー
follow-up → R0 修正 → Changes/README 整備 → 0.01。
「SQL バックエンドの Web アプリでそのまま使える」の訴求は
R0 が直っていることが前提。

### R5. 運用文書

prefork/fork 安全性(CLONE_SKIP 済、program cache は per-process、
ワーカーあたりの RSS 期待値)と max-requests 推奨値を README/POD に明記。

## P: パフォーマンス(async lane 中心)

### P1. L3: async hot path(最大レバー、目標: pre-resolved 32k → 80k+)

プロファイル上の候補(コスト順の仮説):

1. **pending entry ごとの anonymous XSUB 生成をやめる**
   `gql_runtime_vm_new_pending_callback_sv` 等は per-entry に
   `newXS(NULL, ...)` + magic 付与を行う。CV 生成は SV 3〜4 個 + pad 相当の
   コストで、フィールド数に比例して効く。共有 XSUB 1 本 + ctx を
   引数/魔法で渡す形へ。
2. **防御的クローンの除去(ownership provenance)**
   `snapshot_scalarish_value_sv` などの「conservative clone path」
   (コードコメントに明記あり)。値の所有元を追跡して borrowed で持てる
   場所を増やす。
3. **completion の native-first 化**
   OBJECT/LIST completion が SV materialize を経由している箇所を
   native value のまま親へ接続する(envelope 直前まで SV を作らない)。
   L2 の JSON tail はこの下準備になっている。
4. **Promise::XS 境界の削減**
   内部チェーン(pending entry の then、response deferred)は
   `call_method("then")` で Perl API を往復している。Promise::XS の
   C API 直叩き、または内部専用の軽量 deferred(ユーザーに見える
   promise だけ Promise::XS)に置き換える。
5. **exec-state / block frame のプール化**
   リクエストごとの Newxz/Safefree をランタイム保持のフリーリストに。

計測ゲート: `util/lane-cost` 相当を execution-benchmark-checkpoint.pl に
`async_preresolved` シナリオとして追加し、中央値を記録してから着手する
(v1 の教訓: チェックポイントなしの最適化はリグレッション検出が遅れる)。

### P2. L4: 幅優先実行(L3 の後に判断)

DataLoader とは構造的に相性が良い(深さごとに 1 回の stall に収束し、
promise チェーン数が激減する)。ただし L3 で per-promise コストが
下がれば効果は相対的に縮む。graphql-ruby の実験実装を参考に、
L3 完了後のベンチで費用対効果を再評価してから着手。

### P3. L2 残差の収斂(小)

- Boolean の native scalar kind(async json で 0/1 → true/false)
- async json のキー順を可能な範囲でクエリ順に(pending 項目の
  挿入位置を予約する)

### P4. input coercion の native 化(旧 Phase D)

variables ありリクエストは毎回 `prepare_variables`(Perl)を通る。
async 主経路でも同じ。プロファイルして上位に出るなら XS 化。

### P5. W2: APQ + schema boot cache(旧 Phase F)

APQ は長文クエリの parse/転送を削る運用系の改善。boot cache は
prefork ワーカーの起動時間。どちらもリリース後で良い。

## 実施順序の提案

```
R0 (#33 修正)                      ← リリースブロッカー
  → #31/#32 マージ + PSGI async パススルー
  → R1 (load_many 整合) + R4 (0.01 リリース)
  → P1 (L3 async hot path、チェックポイント整備込み)
  → R2 (async croak 監査 + soak) ← L3 の変更と同時期に回すと効率的
  → R3 (リーク残差) / P3 (L2 残差)
  → P2 (L4) / P4 / P5 は再評価してから
```

v1 からの学び(継続適用): ベンチ・soak のチェックポイントを先に整備
してから最適化する / `perl Build` はヘッダ変更で .o を再コンパイルしない /
minilla は git 未追跡ファイルを見ない / リーク調査は C 側アリーナ走査。
