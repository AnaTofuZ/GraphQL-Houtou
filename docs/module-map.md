# Module Map

この文書は、`lib/GraphQL/Houtou` 配下の現行 mainline を、責務ごとに短く把握するための索引です。

## Public Surface

- `GraphQL::Houtou`
  - 最小の公開入口
  - `parse`
  - `parse_with_options`
  - `execute`
  - `execute_native`
- `GraphQL::Houtou::Schema`
  - schema root object
  - runtime graph / program / native bundle の compile 入口
- `GraphQL::Houtou::Validation`
  - validation の最小 facade
  - 公開面は `validate` のみ
- `GraphQL::Houtou::Native`
  - native bundle / native runtime の低レベル facade

## Runtime Mainline

- `GraphQL::Houtou::Runtime::SchemaGraph`
  - boot-time compiled schema graph
  - root block / slot catalog / dispatch index の owner
- `GraphQL::Houtou::Runtime::OperationCompiler`
  - document から `VMProgram` を lower する
- `GraphQL::Houtou::Runtime::VMCompiler`
  - descriptor / native bundle 用の lower / inflate
- `GraphQL::Houtou::Runtime::NativeRuntime`
  - native specialization と native execute の owner
- `GraphQL::Houtou::Runtime::ExecState`
  - perl VM path の state machine

## Runtime State Objects

- `Cursor`
  - 現在の block / op / slot
- `BlockFrame`
  - block-local result and pending state
- `FieldFrame`
  - field-local execution state
- `Outcome`
  - kind-first の内部通貨
- `Writer`
  - outcome から response payload を構築
- `LazyInfo`
  - info の lazy materialization
- `PathFrame`
  - path の lazy materialization
- `ErrorRecord`
  - error payload の record
- `InputCoercion`
  - variables / args / directive guards の coercion

## Runtime Artifacts

- `SchemaBlock`
  - schema graph 側 block
- `Slot`
  - field metadata / dispatch metadata
- `VMProgram`
  - lowered program
- `VMBlock`
  - lowered block
- `VMOp`
  - lowered op
- `VMDispatch`
  - in-memory dispatch binder

## Type System

- `GraphQL::Houtou::Type`
  - type base
- `Type::Object`
- `Type::Interface`
- `Type::Union`
- `Type::InputObject`
- `Type::Scalar`
- `Type::Enum`
- `Type::List`
- `Type::NonNull`
- `Directive`
- `Introspection`

補助:

- `GraphQL::Houtou::Internal::TypeSupport`
  - type constructor helper
- `GraphQL::Houtou::Role::*`
  - marker role と最小 helper

## Parser Internals

parser compatibility は mainline 要件ではありませんが、最小 parser surface を支える内部実装は残しています。

- `GraphQL::Houtou::XS::Parser`
  - parser XS facade と lazy helper の Perl 側補助
- `src/parser_ast_runtime.h`
  - AST runtime helper
- `src/parser_ir_runtime.h`
  - IR materialization helper
- `src/parser_graphqlperl_runtime.h`
  - graphql-perl dialect parser runtime
- `src/parser_shared_ast.h`
  - shared AST helper

## Non-Mainline

次は mainline ではありません。

- `legacy-tests/`
  - 旧 execution / parser compatibility の退避領域
- docs 内の `runtime-vm-architecture.md`
  - 履歴を含む詳細設計メモ
  - 日常的な入口は `architecture.md` と `runtime-mainline-overview.md`
