# Runtime Mainline Architecture

この文書は、現在の `GraphQL::Houtou` の実行系を「どのモジュールが何を所有しているか」という観点で読むための設計メモです。
短い入口は `docs/runtime-mainline-overview.md`、最新の checkpoint と性能値は `docs/current-context.md` を参照してください。

## 目的

現在の mainline は、旧 `execution` / `compiled_ir` 系ではなく、次の方針で再構成されています。

- 公開 API は Perl のまま保つ
- hot path の内部通貨は Perl の `{ data => ..., errors => ... }` ではなく専用 runtime object にする
- schema / operation / VM program を段階的に lower する
- native 実行は `NativeRuntime` と XS VM の境界に集約する
- public な low-level native API は `GraphQL::Houtou::Native` に残す
- `NativeRuntime` の internal 専用 stitching は必要に応じて XS を直接呼び、
  `GraphQL::Houtou::Native` は public low-level facade に限定する
- `GraphQL::Houtou::Runtime` façade 層は削除し、`Schema` / `SchemaGraph` /
  `Compiler` / `NativeRuntime` が直接 mainline を構成する
- Pure Perl VM は bring-up / fallback / 低速 path として残し、本命は native bundle 実行とする

## レイヤー構成

### 1. Public API

主なモジュール:

- `GraphQL::Houtou`
- `GraphQL::Houtou::Schema`

責務:

- XS bundle bootstrap の唯一の owner
- schema compile / program compile / native execute の公開 API 提供
- `Schema` から runtime mainline への入口の提供

備考:

- 子モジュールは `XSLoader::load` しない
- `GraphQL::Houtou::_bootstrap_xs()` が唯一の bootstrap 点

### 2. Schema Runtime Graph

主なモジュール:

- `GraphQL::Houtou::Runtime::SchemaGraph`
- `GraphQL::Houtou::Runtime::SchemaGraph`
- `GraphQL::Houtou::Runtime::Block`
- `GraphQL::Houtou::Runtime::Slot`

責務:

- schema object から immutable な runtime graph を構築
- field / abstract dispatch / slot metadata の固定
- root block と schema block の直接所有

現在の状態:

- 旧 `Runtime::Program` は削除済み
- `SchemaGraph` が schema-side block graph を直接持つ

### 3. Operation Lowering

主なモジュール:

- `GraphQL::Houtou::Runtime::OperationCompiler`

責務:

- query document を schema-aware な lowered program に変換
- variables / args / directives / fragments を実行しやすい shape に lower
- block / op family / child block 参照を固定

### 4. VM Lowering

主なモジュール:

- `GraphQL::Houtou::Runtime::VMCompiler`
- `GraphQL::Houtou::Runtime::VMProgram`
- `GraphQL::Houtou::Runtime::VMBlock`
- `GraphQL::Houtou::Runtime::VMOp`
- `GraphQL::Houtou::Runtime::VMDispatch`

責務:

- lowered program を `program -> block -> op` の VM artifact に変換
- dispatch family を bind し、hot loop で文字列 opcode を再解釈しないようにする
- descriptor dump/load の境界を持つ

### 5. VM Execution

主なモジュール:

- `GraphQL::Houtou::Runtime::VMExecutor`
- `GraphQL::Houtou::Runtime::ExecState`
- `GraphQL::Houtou::Runtime::Cursor`
- `GraphQL::Houtou::Runtime::BlockFrame`
- `GraphQL::Houtou::Runtime::FieldFrame`
- `GraphQL::Houtou::Runtime::Outcome`
- `GraphQL::Houtou::Runtime::Writer`
- `GraphQL::Houtou::Runtime::LazyInfo`
- `GraphQL::Houtou::Runtime::PathFrame`
- `GraphQL::Houtou::Runtime::ErrorRecord`

責務:

- `ExecState` が block / field lifecycle を所有
- `Cursor` が current block / op / slot を指す
- `BlockFrame` が block-local values と pending state を保持
- `FieldFrame` が field-local temporary を保持
- `Outcome` が kind-first な結果通貨
- `Writer` が response materialization を担当

### 6. Native Boundary

主なモジュール:

- `GraphQL::Houtou::Runtime::NativeRuntime`
- `GraphQL::Houtou::Native`
- `src/vm_runtime.h`

責務:

- request-time specialization の owner
- native runtime handle / native bundle handle の owner
- Perl VM artifact から native compact descriptor への変換境界
- XS 実行呼び出しの集中管理

現在の状態:

- `Runtime::ProgramSpecializer` は削除済み
- request-time specialization は `NativeRuntime` に統合済み
- `Runtime::NativeBundle` の Perl wrapper は削除済み
- native bundle は XS が提供する opaque handle
- `Schema` が native bundle descriptor を手組みする経路は削除済み
- `Runtime::execute_vm(...)` も compact descriptor を直組みせず `NativeRuntime` に委譲する
- native 実行の hot path では `runtime + program` を 1 つの Perl hash にまとめず、
  compact runtime struct と compact program struct を part-based API で XS に渡す
- compact program 実行では Perl 側で一時 native bundle handle を作らず、
  `execute_native_program_xs(...)` に直接渡す
- `VMProgram` は compact native struct を memoize し、
  specialization 後の同一 program 再実行では descriptor 再構築を避ける
- `NativeRuntime->execute_program(...)` も `compile_bundle -> execute_bundle` を通らず、
  `specialize -> execute_compact_program` の経路へ寄せてある

## 内部通貨

hot path の一次通貨は以下です。

- `ExecState`
- `Cursor`
- `BlockFrame`
- `FieldFrame`
- `Outcome`
- `Writer`

設計原則:

- kind を先に決める
- payload の Perl object 化は最後まで遅らせる
- `completed { data, errors }` のような envelope を hot path の標準形にしない

これは tokenizer の最適化でいう「token kind と token value を分ける」のと同じ発想です。

## 実行フロー

### Perl VM path

1. `Schema->build_runtime`
2. `Runtime::OperationCompiler->compile_operation`
3. `Runtime::VMCompiler->lower_program`
4. `Runtime::VMExecutor` が `ExecState` を回す
5. `Writer` が最終 response を materialize

### Native VM path

1. `Schema->build_native_runtime`
2. `NativeRuntime->compile_program`
3. `NativeRuntime->specialize_program`
4. `NativeRuntime->compile_bundle` または `execute_program`
5. `GraphQL::Houtou::Native` 経由で XS VM 実行

## 現在の性能の読み方

性能比較では 2 系統を分けて考える必要があります。

- `houtou_runtime_cached_perl`
  - Pure Perl VM mainline
  - bring-up / fallback / cold path
- `houtou_runtime_native_bundle`
  - 本命の native bundle / XS VM mainline

現時点では native bundle 側が旧 `compiled_ir` mainline より大幅に速く、Perl VM 側はそれより遅いです。
したがって、最適化の主対象は Perl VM ではなく native bundle / XS VM 境界です。

## 削除済みの旧実装

active tree からは次を削除済みです。

- 旧 `execution` / `compiled_ir` mainline
- `src/execution.h`
- `src/ir_engine.h`
- `src/ir_execution.h`
- `src/legacy_compat.h`
- `Runtime::Program`
- `Runtime::ProgramSpecializer`
- `Runtime::NativeBundle` Perl wrapper

旧テストと履歴は次を参照します。

- `legacy-tests/original-t/`
- Git history

## 今後の主戦場

今後の高速化で一番重要なのは次です。

- `NativeRuntime` と `src/vm_runtime.h` の境界をさらに詰める
- request-time specialization を compact descriptor / native slot 寄りにする
- native VM executor 側で `Outcome` / `Writer` 相当の ownership を強める
- Perl VM は correctness / fallback / bring-up へ寄せる

つまり、今後の最適化は旧 corridor widening の延長ではなく、**native bundle mainline の構造最適化** が中心です。
