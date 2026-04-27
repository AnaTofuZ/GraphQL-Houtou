# Parser Dialects

## Goal

`GraphQL-Houtou` では、既存利用者を壊さずに parser の互換性と将来拡張を両立するため、
以下の 2 軸を分離して扱う。

活動記録と残作業の全体像は `docs/project-status.md` にまとめてある。

- dialect
  - `graphql-perl`
  - `graphql-js`
- backend
  - `pegex`
  - `xs`

## Design Rules

### 1. `parse()` keeps graphql-perl compatibility

`GraphQL::Houtou::parse($source)` は graphql-perl dialect 固定の互換 API として扱う。

ここでいう graphql-perl dialect とは、以下を含む。

- Perl 独自 AST 形状
- Perl 値への即時変換
- `location => { line, column }` 形式
- 既存 grammar の制約

ただし backend の既定は `xs` であり、必要なときだけ `pegex` を明示選択する。
また、core parser が spec 寄りに受理する差分のうち legacy 互換が必要なものは、
この dialect 層で再制約する。現時点では empty object value (`{}`) がこれに当たる。

### 2. Dialect selection uses `parse_with_options()`

dialect と backend は `parse_with_options()` で明示選択できる。

```perl
my $ast = GraphQL::Houtou::parse_with_options($source, {
  dialect => 'graphql-js',
  backend => 'xs',
  no_location => 1,
});
```

### 3. Namespaces are split by dialect

- `GraphQL::Houtou::GraphQLPerl::Parser`
- `GraphQL::Houtou::GraphQLJS::Parser`

これにより、利用者がどの AST 契約に依存しているかを import 時点で明示できる。

### 4. Backend modules are split by implementation

- `GraphQL::Houtou::Backend::Pegex`
- `GraphQL::Houtou::XS::Parser`

`GraphQL::Language::Parser` 依存は `Backend::Pegex` に閉じ込め、
通常経路は `XS::Parser` の XSUB / Perl helper を直接使う。

## Current Stage

2026-04-03 時点の状態:

- top-level `parse()` の既定 backend は `xs`
- `backend => 'pegex'` は互換用の明示指定
- `GraphQL::Houtou::GraphQLJS::Parser` は executable document と主要 SDL を graphql-js 風 AST に変換できる
- `no_location` は graphql-js dialect では実際に `loc` を落とす
- `interface ... implements ...` と `directive ... repeatable ...` は metadata patch で対応済み
- `extend schema|scalar|type|interface|union|enum|input` は graphql-js extension node に変換済み
- variable definition directives も metadata patch で対応済み
- graphql-js dialect の前処理 metadata 抽出は `GraphQL::Houtou::XS::Parser::graphqljs_preprocess_xs()` を優先利用する
- XS 前処理は metadata だけでなく rewritten source も返す
- `GraphQL::Houtou::GraphQLJS::Parser` は XS 専用経路であり、`backend => 'xs'` のみを受け付ける
- `GraphQL::Houtou::XS::Parser::tokenize_xs()` を使って graphql-js `loc` を source token ベースで再構築する
- XS core parser は empty object value を受理し、graphql-perl dialect 側でだけ legacy reject をかける
- XS patch と PP patch の variable directive 出力は parity テストで固定している

## Verified

新 distribution 側で確認済み:

- dialect routing
- graphql-perl AST compatibility
- graphql-js AST compatibility の代表ケース
- XS helper smoke
- kitchen-sink / schema-kitchen-sink parse smoke

## Remaining Work

1. graphql-js dialect の current-spec 差分をさらに詰める
2. graphql-js `loc` 精度を complex SDL 全体でさらに固定する
3. benchmark / profile を distribution 側で継続的に取れるようにする
4. 必要なら `Backend::Pegex` の optional dependency 化を検討する

## Compatibility Promise

- `GraphQL::Houtou::parse()` は graphql-perl 互換 AST を返す
- graphql-js dialect は別 API / 別 namespace で提供する
- `GraphQL::Language::Parser` 依存は `Backend::Pegex` に閉じ込める
- 通常利用は `xs` backend を前提に進める
