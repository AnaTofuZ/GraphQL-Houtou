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
- `GraphQL::Houtou::Backend::GraphQLJS::XS`
  - graphql-js AST を正準形として返す XS 中心 backend
- `GraphQL::Houtou::GraphQLPerl::Parser`
  - graphql-perl 互換 AST parser
- `GraphQL::Houtou::GraphQLPerl::FromGraphQLJS`
  - graphql-js 正準 AST から graphql-perl AST を組み立てる互換層
- `GraphQL::Houtou::GraphQLJS::Parser`
  - graphql-js 風 AST parser
- `GraphQL::Houtou::XS::Parser`
  - XS backend helper
- `GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS`
  - legacy AST から graphql-js AST への変換
- `GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl`
  - graphql-js AST から legacy AST への変換
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
- graphql-js XS canonical backend
- graphql-js AST から graphql-perl AST への adapter backend
- XS helper の smoke
- graphql-perl 互換 AST の代表回帰
- graphql-js/spec 寄りの空 object value 受理
- graphql-perl dialect での空 object value legacy reject
- XS/PP directive patch parity
- kitchen-sink / schema-kitchen-sink の parse smoke

2026-04-03 時点のローカル検証:

- `./Build build`
- `./Build test`
- `7 files / 50 tests / PASS`
- `7 files / 53 tests / PASS`
- benchmark 記録は `docs/performance.md`

## Recent Decisions

### Core parser is spec-first for empty object values

XS コア parser は `{}`
を object value として受理する。これは graphql-js / 現行 spec 側に寄せた判断である。

一方で `graphql-perl` dialect は既存互換のため、compatibility layer 側で
empty object value を `Expected name` として reject する。
この差分は parser core ではなく dialect 層の責務として扱う。

### XS and PP patch paths must stay comparable

variable definition directive の patch は、XS 経路と PP fallback 経路で
同じ graphql-js AST を返すことをテストで固定した。
PP 側は materialize 済み directive node を再 parse せず、
`loc` の rebasing だけ行う構成に整理した。

### graphql-js AST is now an explicit canonical XS path

`GraphQL::Houtou::Backend::GraphQLJS::XS` を追加し、
graphql-js AST を返す XS 中心経路を独立 backend として明示した。

まだ parser core 自体が完全な graphql-js 専用 AST builder になったわけではないが、
少なくとも API と責務の境界は

- graphql-js AST を返す正準経路
- graphql-perl 互換 AST へ落とす adapter 経路

に切り出せた。

`GraphQL::Houtou::GraphQLPerl::Parser` には `backend => 'canonical-xs'`
を追加し、graphql-js canonical path から legacy AST へ戻す段階移行を始めている。
`graphqljs-xs` は互換 alias として残している。
現時点では location の意味が legacy XS と完全一致しないため、
この経路は「形状互換を確認する移行 backend」として扱う。

## Remaining Work

### 1. テスト移植の拡充

旧 repo の parser 回帰はかなり持ってきたが、まだ残りがある。

候補:

- graphql-js AST 形状テストの残件
- SDL / location のさらに細かい regression
- parser error の網羅性追加
- `canonical-xs` -> graphql-perl adapter の location / error parity 固定

### 2. graphql-js canonical XS path の本格化

現在の `Backend::GraphQLJS::XS` は既存実装を明示 backend 化した段階であり、
本当の意味での「graphql-js 専用 XS core」はまだ未完である。

候補:

- graphql-js AST builder を XS 直生成へ寄せる
- Perl 側 adapter / locator の残りを XS helper へ移す
- `canonical-xs` backend の location parity を詰める

### 3. upstream 依存の切り分け

いまは `GraphQL::Houtou::Backend::Pegex` が `GraphQL::Language::Parser` に依存しているため、
長期的には以下を決める必要がある。

- 依存を維持するか
- Pegex path を `GraphQL-Houtou` 側に複製するか
- XS backend を既定に寄せて upstream parser 依存を薄くするか

### 4. distribution metadata の整備

まだ scaffold 直後の要素が残っている。

候補:

- README / POD の充実
- GitHub Actions の見直し
- release 手順の整理
- version / Changes ポリシーの整理

### 5. performance measurement の継続

baseline の benchmark / NYTProf は `docs/performance.md` に記録した。
今後は次を継続対象とする。

- `graphql-js` 側 NYTProf の追加
- release 前の再測定
- CI に入れるかどうかの判断

## Recommended Next Steps

1. `Backend::GraphQLJS::XS` を真の graphql-js 専用 XS core に寄せる
2. `canonical-xs` -> graphql-perl adapter の parity を広げる
3. docs / metadata を distribution 公開前提に整理する
4. `GraphQL::Language::Parser` 依存をどこまで残すか決める
