# ファーストリリース・ロードマップ調査

> **2026-07-06 以降の優先順位は `docs/product-roadmap.md` を正とする。**
> この文書は当時の調査・計画記録として残す。

調査日: 2026-07-04

この文書は、ファーストリリースに必要な残機能、速度向上の今後の開発ポイント、
Federation 等モダン機能の取り込み方針、および graphql-ruby の幅優先実行の
導入可否をまとめたものである。

`docs/ecosystem-feature-gap.md`(2026-04-06 調査)を起点に、その後の実装進捗を
git 履歴で確認した上で整理した。

## 前提: ギャップ調査(4月)以降に実装済みのもの

- Mutation serial execution(PR #9)
- Query depth limit(default 15、PR #13)
- Compiled program cache(PR #11)
- Deprecated introspection / JSON::MaybeXS 対応(`a535771`)
- Directive runtime / custom directive hooks(PR #14)
- Persisted queries(`t/22_persisted_queries.t`, `docs/persisted-queries.md`)
- Promise::XS auto-detect async mainline

---

## 1. ファーストリリースに必要な残機能

### 必須(リリースブロッカー)

1. **`build_schema`(SDL → 実行可能スキーマ)/ `print_schema`(スキーマ → SDL)**
   - `lib/` に未実装。最重要。
   - 理由:
     - graphql-perl ユーザーの主要な移行経路が SDL 定義
     - GraphiQL / codegen / schema registry 統合の基盤
     - Federation `_service { sdl }` がこれに直接依存する
   - XS パーサーは既にあるため、SDL AST → 型オブジェクト構築と逆方向の
     printer の実装で済む。
2. **スキーマ構築時バリデーション**
   - 特に Interface 実装整合性チェック
     (`assert_object_implements_interface` 相当)。
   - 「壊れたスキーマは build 時に落ちる」保証がないと、不正スキーマが
     XS 実行時まで通ってしまう。
3. **Introspection 現代化の残り**
   - `__Directive.isRepeatable` / `__Type.specifiedByURL` / `__Type.isOneOf`
   - 未対応だと最近の GraphiQL / codegen がスキーマ取得時に落ちることがある。
   - 既存 `Introspection.pm` の拡張で対応可能。
4. **パッケージング整理**
   - `cpanfile` の `requires 'GraphQL', '0.54'`(graphql-perl)を runtime 依存から外す。
   - 実際の使用箇所は `GraphQL::Error`(4 モジュール + parser エラー構築)と
     `GraphQL::Language::Receiver` の block string ヘルパーのみで、
     自前の `GraphQL::Houtou::Error` と spec 準拠のローカル実装で置き換え可能。
   - `util/` のベンチマークスクリプトは比較対象として graphql-perl を使い続けるので、
     `develop` フェーズ依存として残す。

### 強く推奨(同リリースか直後)

5. **PSGI/Plack アダプタ**
   - GraphQL over HTTP 仕様(POST JSON、`application/graphql-response+json`)準拠の
     薄い `Plack::App::GraphQL::Houtou` + GraphiQL 配信。
   - 別ディストリビューションでも可。採用の入口として重要。
6. **`@oneOf`**
   - バリデーションルール追加のみで小さい。graphql-js では stable 入り済み。

### ファーストリリースから外してよいもの

- `@defer` / `@stream`(イベントループ前提でアーキテクチャ課題が大きい)
- Subscription トランスポート(graphql-ws)
- Query complexity 分析(depth limit で当面の安全弁はある)

---

## 2. 速度向上の今後の開発ポイント

`docs/current-context.md` の checkpoint で既に特定済みの残りコスト
(nested の args/variable coercion 固定コスト、generic info callback case の
ABI 特化、async の nested block artifact / clone 削減)に加えて、
未着手で効果が大きい見込みのもの:

1. **レスポンスの直接 JSON 化(`execute_to_json`)**
   - 現在は native value → Perl の `{data => ...}` envelope → ユーザー側 JSON encode
     の 2 段構え。
   - VM は native value 表現を持っているので、SV envelope を経由せず C レベルで
     直接 JSON バイト列を書き出す fast lane を作れば、サーバー用途の実効
     スループット(execute + serialize)で大きく効く。
   - sync fast lane を direct-SV 1 パスに戻したのと同じ発想の「direct-JSON 1 パス」。
2. **スキーマの boot-time コンパイルキャッシュ**
   - native runtime descriptor の dump/load は既にあるので、
     「スキーマ定義 → コンパイル済み descriptor をファイル化 → 起動時 load」で
     prefork サーバー(Starman 等)の worker 起動コストを削る。
3. **async path の続き**
   - ownership provenance を持たせた clone 削減と
     object/abstract completion の raw/native 化(checkpoint 記載の通り)。
   - sync native bundle(約 58 万/s)と async(約 12〜18 万/s)の差はまだ 3〜4 倍。
     実アプリ(DB アクセスあり)ではここが体感を支配する。
   - 後述の幅優先実行モードは async path の再設計と同時にやるのが効率的。

sync fast lane 自体は high-watermark を超えて収束しているため、generic runtime を
これ以上磨くより上記の「境界コスト」を削る方が筋が良い。

---

## 3. Federation ほかモダン機能の取り込み

### Apollo Federation v2 subgraph 対応(推奨)

ゲートウェイ側ではなく subgraph 側。Perl サーバーの現実的なユースケースは
「既存 Perl モノリスを subgraph として供給グラフに参加させる」こと。

必要なもの:

- `@key` / `@external` / `@requires` / `@provides` / `@shareable` /
  `@inaccessible` / `@override` / `@link`
  - 大半はスキーマメタデータ。directive runtime が既にあるので載せる場所はある。
- `_service { sdl }` — **`print_schema` 完成が前提**(§1 項目 1 との依存関係)
- `_entities(representations:)` — 型ごとの reference resolver 登録 API +
  `_Any` / `FieldSet` scalar + `_Entity` union
- 検証: Apollo 公式の subgraph compatibility テストスイート
  (apollographql/apollo-federation-subgraph-compatibility)をそのまま使える

注意: `_entities` は representation ごとに resolver が呼ばれる N+1 の温床で、
§4 の幅優先実行と直結する。

### Federation 以外

- **APQ(Automatic Persisted Queries)** — 費用対効果が最も高い。
  SHA-256 ハッシュ + キャッシュのプロトコルだけで、persisted query 基盤
  (`compile_native_bundle` / program cache)が既にあるためほぼ結線のみ。
  Apollo Client 利用者への訴求が大きい。
- Relay Connection ヘルパー — 薄いスキーマパターン提供なので優先度低。
- graphql-ws — 非同期 I/O アーキテクチャの決断が必要なので当面見送り。

---

## 4. graphql-ruby の幅優先実行の導入可否

**結論: 導入可能。しかも Perl では本家以上に価値がある。**

### 背景

graphql-ruby の実験は「フィールドを深さ優先で 1 本ずつ解決する代わりに、
同一階層の全フィールド(全親オブジェクト横断)の resolver を先に全部呼び、
その後で次の階層に降りる」というもの。狙いは Dataloader のバッチングを
fiber 切り替えなしで成立させること。

### Houtou に導入すべき理由

`docs/ecosystem-feature-gap.md` §9.2 の指摘の通り、Perl には Node.js の
イベントループ tick がないため DataLoader の自動バッチ化ポイントが自然に
作れない。幅優先実行はこれを構造的に解決する —
「階層 N の全 resolver 呼び出し完了」が明示的なバッチ flush ポイントになる。
Federation `_entities` / Relay `node()` の N+1 対策として §3 とセットで効く。

### 実装面の見立て

下地はかなりできている。`optimize-async-scheduler` で入った XS scheduler は
ready block queue + pending entry の state machine + 2-phase continuation という
構造で、幅優先に必要な「フィールド実行と completion の分離」「フレームの
キュー駆動」をほぼ備えている。

方針: sync fast lane(depth-first tight loop、stack writer、borrowed path frame)には
触らず、**第 3 の実行モード**(例: batch loader 登録時に自動選択)として
scheduler 側に載せる。

1. 階層 N の全 slot について resolver を呼ぶ(値 or「バッチ待ち」トークンを返す)
2. 登録された batch loader を flush(ここが DataLoader の同期バッチポイント)
3. completion を回して次階層の block frame 群を構築し、N+1 へ

### 注意点

- 階層幅ぶんのフレーム保持で、深さ優先よりメモリを食う
- non-null エラーの bubbling とエラー順序の再現に注意
- mutation は従来通り serial のまま
- graphql-ruby でも experimental 扱いなのと同様、opt-in で入れて
  既存の benchmark gate 運用で keep/revert を判断する

---

## 推奨する実施順序

1. `build_schema` / `print_schema` + スキーマ構築時バリデーション +
   introspection 残り + 依存整理 → **ファーストリリース**
2. PSGI アダプタ + APQ
3. Federation subgraph(1 の printer に依存)
4. 幅優先実行モード(3 の `_entities` バッチングの受け皿として、
   async path 最適化と同時に)

速度面の次の大きな山は `execute_to_json` とスキーマ precompile。

## 関連文書

- `docs/ecosystem-feature-gap.md` — 未対応機能の全量調査(2026-04-06)
- `docs/project-status.md` — mainline の現状
- `docs/current-context.md` — runtime / VM の詳細 checkpoint
- `docs/validation-status.md` — validation ルールの実装状況
