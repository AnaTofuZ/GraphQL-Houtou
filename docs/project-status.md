# GraphQL::Houtou Project Status

## Current Mainline

`GraphQL::Houtou` の mainline は parser 単体ではなく、次の 3 層です。

- XS-first parser surface
- compiled runtime / VM surface
- top-level native bundle execution surface

現時点で実際に mainline として扱っている公開面は次です。

- `GraphQL::Houtou::execute(...)`
- `GraphQL::Houtou::execute_native(...)`
- `GraphQL::Houtou::compile_runtime(...)`
- `GraphQL::Houtou::compile_native_bundle(...)`
- `GraphQL::Houtou::Schema->build_runtime(...)`
- `GraphQL::Houtou::Schema->build_native_runtime(...)`
- `GraphQL::Houtou::Schema->compile_program(...)`
- `GraphQL::Houtou::Schema->execute(...)`
- `GraphQL::Houtou::Schema->execute_native(...)`

公開 validation façade は XS 必須です。

- `GraphQL::Houtou::Validation`

## Compatibility Policy

互換性の扱いは次の通りです。

- parser surface では、必要な範囲で
  - `graphql-perl` 互換 AST
  - `graphql-js` 風 AST
  を維持する
- execution mainline は旧 mixed executor ではなく runtime / VM を優先する
- Pure Perl fallback は mainline の前提にしない
- ただし legacy XS integration がまだ依存している内部互換モジュールは一時的に残す

現時点では validation 側の internal PP bridge は削除済みで、旧 path に残る
互換層は主に execution 側です。

## Runtime / VM Status

runtime / VM で既に入っているもの:

- immutable schema graph
- immutable execution program / block / slot
- VM lowering artifact
- VM descriptor dump/load
- native runtime descriptor dump/load
- native bundle compile/load/execute
- `ExecState / Cursor / BlockFrame / FieldFrame / Writer / Outcome`
  による kind-first 実行
- top-level native boundary の集中化

関連ドキュメント:

- `docs/current-context.md`
- `docs/runtime-vm-architecture.md`
- `docs/execution-benchmark.md`

## Legacy Artifacts

旧実装のテスト資産は `legacy-tests/` に退避済みです。

意図:

- 旧仕様との差分確認
- 必要なケースだけ将来の runtime / VM テストへ再移植
- 旧実装コードを大胆に削除するための保険

active suite は `legacy-tests/` を基準にはしていません。

## Current Direction

今後の主方向は次です。

1. runtime / VM を mainline として育てる
2. hot path の内部通貨から Perl envelope を追い出す
3. family-owned completion と VM block/state ownership を強める
4. native execution surface を mainline に寄せる
5. 旧 mixed implementation の露出を順次下げる

## Non-Goals

当面の非目標:

- public Pure Perl fallback の維持
- 旧 mixed execution architecture の延命
- 小さな互換 helper を増やして mainline を複雑化すること

## Verification

現在の確認コマンドは少なくとも次です。

```sh
minil test
```

runtime / VM 寄りの focused 確認は次です。

```sh
minil test t/13_runtime_schema.t t/14_runtime_operation.t t/15_runtime_execute.t t/16_runtime_promise.t t/17_runtime_errors.t t/18_vm_lowering.t t/19_vm_execute.t t/20_public_runtime_api.t
```
