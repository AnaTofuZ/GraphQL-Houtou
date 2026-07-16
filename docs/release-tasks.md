# リリースまでの残タスク (2026-07-16 改訂)

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

### R5. valgrind / LeakSanitizer の一回転

- soak は RSS 傾きでリーク検出しているが、正確なリーク元特定のため
  リリース前に valgrind(または LSan)を 1 回全テストに通し、
  既知の interpreter arena ノイズ以外の直接リークがないことを確認。
  常設は重いので「リリースゲートとして 1 回」でよい。

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
