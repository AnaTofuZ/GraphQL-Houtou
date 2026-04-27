# Runtime/VM Mainline Overview

この文書は、現在の `GraphQL::Houtou` の実行系を短く把握するための概要です。
ownership と層構成をまとめて読むには `docs/runtime-mainline-architecture.md` を参照してください。
詳細設計は `docs/runtime-vm-architecture.md` を参照してください。

## 方針

- 実行の mainline は `Runtime/VM` 系です。
- 旧 execution 実装は active code path から外してあります。
- 旧テスト資産は `legacy-tests/` に退避してあり、必要なら Git 履歴と合わせて参照します。
- Pure Perl fallback を主設計には置いていません。
- 公開 API は Perl らしさを保ちつつ、内部通貨は Perl の `{ data => ..., errors => ... }` ではなく runtime/VM 用オブジェクトです。

## レイヤー

### 1. Public API

- `GraphQL::Houtou`
- `GraphQL::Houtou::Schema`
- `GraphQL::Houtou::Native` (low-level native handles)
- parser / validation facade

役割:

- XS bundle bootstrap の入口を 1 箇所にまとめる
- schema compile / operation compile / VM execute の公開 API を提供する
- `GraphQL::Houtou::Runtime` façade は削除済み
- public な low-level native handle 操作は `GraphQL::Houtou::Native` に集約する
- internal 専用の native bundle stitching は `Runtime::NativeRuntime` から XS を直接呼ぶ
- `GraphQL::Houtou::Native` は public low-level facade であり、internal 専用 API の受け皿ではない

### 2. Schema Runtime

- `GraphQL::Houtou::Runtime::SchemaGraph`
- `GraphQL::Houtou::Runtime::NativeRuntime`
- opaque native bundle handle (`GraphQL::Houtou::Runtime::NativeBundle` package is provided by XS only)

役割:

- schema を boot-time compile 可能な immutable graph に lower する
- field / abstract dispatch / slot metadata を固定する
- native runtime / native bundle との境界を持つ
- request-time specialization と native bundle descriptor 組み立てを `NativeRuntime` が所有する
- native bundle descriptor の inflate/execute も `SchemaGraph` 経由の wrapper ではなく `NativeRuntime` が所有する
- `Runtime::execute_vm(...)` からの compact program 実行も `NativeRuntime` が所有する
- hot path では `runtime + program` の Perl descriptor hash を組み立てず、
  compact runtime struct と compact program struct を別引数のまま XS に渡して bundle を inflate する
- compact program の実行時は、一時的な native bundle handle を Perl 側で組み立てず、
  `execute_native_program_xs(...)` へ直接流す
- `VMProgram` は compact native struct を memoize し、同一 program の繰り返し実行で
  block/op 配列の Perl 再構築を避ける
- `NativeRuntime->execute_program(...)` も `compile_bundle -> execute_bundle` を通らず、
  `specialize -> execute_compact_program` の mainline を使う

### 3. Schema Graph

- `GraphQL::Houtou::Runtime::SchemaGraph`
- `GraphQL::Houtou::Runtime::SchemaBlock`
- `GraphQL::Houtou::Runtime::Slot`

役割:

- schema object から object-field 単位の immutable schema block を作る
- root type / dispatch metadata / slot catalog を `SchemaGraph` が直接所有する
- operation lowering から参照する schema-side block/index を提供する

### 4. Operation Lowering

- `GraphQL::Houtou::Runtime::OperationCompiler`
- `GraphQL::Houtou::Runtime::Slot`

役割:

- query document を schema-aware な lowered program に変換する
- variables / args / directives / fragments を execution しやすい shape に下げる
- さらに native specialization に渡す前段の IR を持つ

### 5. VM Lowering

- `GraphQL::Houtou::Runtime::VMCompiler`
- `GraphQL::Houtou::Runtime::VMProgram`
- `GraphQL::Houtou::Runtime::VMBlock`
- `GraphQL::Houtou::Runtime::VMOp`
- `GraphQL::Houtou::Runtime::VMDispatch`

役割:

- lowered program を VM block / op に変換する
- hot path で使う dispatch family を bind する
- string opcode の再解釈や動的 helper lookup を避ける

### 6. VM Execution

- `GraphQL::Houtou::Runtime::ExecState`
- `GraphQL::Houtou::Runtime::Cursor`
- `GraphQL::Houtou::Runtime::BlockFrame`
- `GraphQL::Houtou::Runtime::FieldFrame`
- `GraphQL::Houtou::Runtime::Writer`
- `GraphQL::Houtou::Runtime::Outcome`
- `GraphQL::Houtou::Runtime::LazyInfo`
- `GraphQL::Houtou::Runtime::PathFrame`
- `GraphQL::Houtou::Runtime::ErrorRecord`

役割:

- `program -> block -> op` を state machine として実行する
- current block / current op / field lifecycle を `ExecState` 配下に集約する
- outcome kind を先に決め、payload の Perl object 化を遅らせる
- writer が最後の response materialization を担当する

## 内部通貨

hot path の helper 同士が受け渡す主表現は次です。

- `ExecState`
- `Cursor`
- `BlockFrame`
- `FieldFrame`
- `Outcome`
- `Writer`

重要なのは、これらを runtime の一次通貨として使い、
Perl の envelope や ad hoc な `SV/HV/AV` の組を hot path の標準形にしないことです。

## XS 境界

- XS bundle の bootstrap owner は `GraphQL::Houtou` だけです。
- 子モジュールが個別に `XSLoader::load` する構造は採用しません。
- Perl facade は root bootstrap 後に XSUB package を呼びます。

これにより、

- 重複 bootstrap
- redefined warning
- PP から XS への差し戻しのような歪んだ依存

を避けています。

## 旧実装との関係

- 旧 execution header / compiled IR mainline は削除済みです。
- 旧 parser / validation / execution の回帰資産は `legacy-tests/` に退避しています。
- active suite は runtime/VM mainline を前提にしています。

## 今後の主軸

- runtime/VM を mainline として磨く
- family-owned dispatch と state machine ownership をさらに進める
- 必要な箇所から XS/native fast path を増やす
- schema cache / native bundle / descriptor roundtrip を実用レベルまで押し上げる

要するに、現在の `GraphQL::Houtou` は
「Perl API を持つが、内部は compile + VM runtime で動く GraphQL 実行系」
として整理されています。

Persisted Queries については `docs/persisted-queries.md` を参照してください。
