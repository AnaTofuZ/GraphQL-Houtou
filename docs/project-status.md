# GraphQL::Houtou Project Status

## Goal

`graphql-perl` 本体へ取り込まれる前提を捨てて、parser 関連の成果物を
別 distribution `GraphQL-Houtou` として独立公開する。

この distribution の基本方針は次のとおり。

- upstream `GraphQL` を依存に置く
- parser / adapter / XS helper は `GraphQL::Houtou::*` 側で持つ
- 既存 `graphql-perl` AST と graphql-js 風 AST の両方を選択可能にする

## Current Layout

- `GraphQL::Houtou`
  - top-level facade
- `GraphQL::Houtou::Backend::Pegex`
  - upstream `GraphQL::Language::Parser` を呼ぶ互換 backend
- `GraphQL::Houtou::Backend::XS`
  - Houtou 側 XS backend dispatcher
- `GraphQL::Houtou::GraphQLPerl::Parser`
  - graphql-perl 互換 AST parser
- `GraphQL::Houtou::GraphQLJS::Parser`
  - graphql-js 風 AST parser
- `GraphQL::Houtou::XS::Parser`
  - XS backend helper
- `GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS`
  - legacy AST から graphql-js AST への変換
- `GraphQL::Houtou::GraphQLJS::PP`
  - PP fallback
- `GraphQL::Houtou::GraphQLJS::Locator`
  - token ベースの `loc` 再構築

補助スクリプト:

- `util/parser-benchmark.pl`
- `util/profile-parser.pl`

## Current Dependency Boundary

現時点では upstream `GraphQL` に依存している。

主な依存先:

- `GraphQL::Language::Parser`
- `GraphQL::Language::Receiver`
- `GraphQL::Error`

ただし `GraphQL::Language::Parser` 依存は `GraphQL::Houtou::Backend::Pegex`
へ隔離し、公開 parser facade や graphql-js parser 本体からは直接参照しない形にした。
通常経路の既定 backend は XS であり、Pegex は明示指定または fallback 用である。

つまり、完全独立 parser distribution ではなく、
「parser 機能を別 distribution として提供しつつ、upstream GraphQL を下位依存に置く」
段階である。

## Verified

現時点で新 distribution 側で確認しているもの:

- facade 経由の graphql-perl parse
- graphql-perl XS backend 選択
- graphql-js dialect 選択
- extension / repeatable / variable directives
- `no_location`
- token-based `loc`
- XS helper の smoke
- graphql-perl 互換 AST の代表回帰
- kitchen-sink / schema-kitchen-sink の parse smoke

2026-04-03 時点のローカル検証:

- `./Build build`
- `./Build test`
- `7 files / 36 tests / PASS`

## Remaining Work

### 1. テスト移植の拡充

旧 repo の parser 回帰はかなり持ってきたが、まだ残りがある。

候補:

- graphql-js AST 形状テストの残件
- SDL / location のさらに細かい regression
- parser error の網羅性追加

### 2. upstream 依存の切り分け

いまは `GraphQL::Houtou::Backend::Pegex` が `GraphQL::Language::Parser` に依存しているため、
長期的には以下を決める必要がある。

- 依存を維持するか
- Pegex path を `GraphQL-Houtou` 側に複製するか
- XS backend を既定に寄せて upstream parser 依存を薄くするか

### 3. distribution metadata の整備

まだ scaffold 直後の要素が残っている。

候補:

- README / POD の充実
- GitHub Actions の見直し
- release 手順の整理
- version / Changes ポリシーの整理

### 4. performance measurement の実測

benchmark / profiler スクリプトは distribution 側へ移植したが、
まだ `GraphQL-Houtou` 単体の実測結果を記録していない。

## Recommended Next Steps

1. docs / metadata を distribution 公開前提に整理する
2. benchmark / profile を実行して結果を記録する
3. `GraphQL::Language::Parser` 依存をどこまで残すか決める
4. 必要なら `Backend::Pegex` の optional dependency 化を検討する
