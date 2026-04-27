# Current Context

このリポジトリの主系は `Runtime` / `VM` ベースの新実装です。

## 現在の前提

- 実行系の主入口
  - `GraphQL::Houtou::execute`
  - `GraphQL::Houtou::Schema->execute`
  - `GraphQL::Houtou::Schema->execute_native`
- active suite
  - `t/00_compile.t`
  - `t/07_schema_compiler.t`
  - `t/08_validation.t`
  - `t/13_runtime_schema.t`
  - `t/14_runtime_operation.t`
  - `t/15_runtime_execute.t`
  - `t/16_runtime_promise.t`
  - `t/17_runtime_errors.t`
  - `t/18_vm_lowering.t`
  - `t/19_vm_execute.t`
  - `t/20_public_runtime_api.t`
  - `t/21_public_parser_api.t`
- 旧テストは `legacy-tests/original-t/` に退避済み
- PP fallback は設計上の主要求ではない
- 子モジュールが XS を直接 `use` して hot path を組み立てる形は避ける
- XS bundle のロード責務は `GraphQL::Houtou` だけが持つ
- 旧実装は git history で追えればよく、source tree には残さない

## 現在のアーキテクチャ

詳細は `docs/runtime-vm-architecture.md` を参照。

実装は次の 4 層に分かれています。

1. Public API
   - `GraphQL::Houtou`
   - `GraphQL::Houtou::Schema`
2. Compile / Lowering
   - `GraphQL::Houtou::Runtime::Compiler`
   - `GraphQL::Houtou::Runtime::OperationCompiler`
   - `GraphQL::Houtou::Runtime::VMCompiler`
3. Runtime / VM
   - `GraphQL::Houtou::Runtime::ExecState`
   - `GraphQL::Houtou::Runtime::Cursor`
   - `GraphQL::Houtou::Runtime::BlockFrame`
   - `GraphQL::Houtou::Runtime::FieldFrame`
   - `GraphQL::Houtou::Runtime::Writer`
   - `GraphQL::Houtou::Runtime::VMExecutor`
4. XS Native Boundary
   - bundle owner: `GraphQL::Houtou::_bootstrap_xs`
   - parser helper: `GraphQL::Houtou::XS::Parser`
   - compile / validation / native runtime は public facade から XSUB package を直接呼ぶ

## 内部通貨

hot path の内部通貨は Perl の `{ data => ..., errors => ... }` ではなく、
次の kind-first / state-first なオブジェクトです。

- `ExecState`
- `Cursor`
- `BlockFrame`
- `FieldFrame`
- `Outcome`
- `Writer`
- `VMProgram`
- `VMBlock`
- `VMOp`

基本方針:

- kind を先に決める
- payload の Perl object 化は遅らせる
- response envelope は境界でだけ作る

## 完了していること

- runtime schema compile
- operation lowering
- VM lowering
- VM descriptor dump/load
- native bundle dump/load
- sync object/list/default resolver 実行
- abstract dispatch
  - `tag_resolver`
  - `resolve_type`
  - `possible_types + is_type_of`
- promise runtime
- lazy `info`
- lazy error record
- public API を runtime/VM mainline に接続

## 直近の方針

- 旧 execution mainline の active dependency は削除済み
- 旧 execution / compiled-ir headers
  - `src/execution.h`
  - `src/ir_engine.h`
  - `src/ir_execution.h`
  - `src/legacy_compat.h`
  は source tree から削除済み
- parser / graphql-js 互換でまだ必要な実体は
  - `src/parser_compat.h`
  - `src/graphqljs_ir_runtime.h`
  に責務分離して保持
- 今後の高速化は旧 corridor widening の延長ではなく、runtime/VM 本体で進める
- 特に注力するのは:
  - native VM executor の XS 化
  - compact descriptor の最適化
  - schema/runtime cache の boot-time compile
  - writer/outcome の native 化

## 現在の確認コマンド

```sh
minil test
perl -Ilib t/18_vm_lowering.t
perl -Ilib t/19_vm_execute.t
```

## 次にやること

1. Pure Perl VM executor の責務をこれ以上増やさない
2. `XS::VM` 側に native VM executor を実装する
3. `Schema->build_native_runtime` / `compile_native_bundle` 経由の実行を本命にする
4. 現在の Perl VM を validation / bring-up / fallback 用に位置づける
