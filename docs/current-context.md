# Current Context

## Read First

現状の構成を短く把握するには、まず `docs/runtime-mainline-overview.md` を読むこと。
その次に `docs/runtime-mainline-architecture.md` を読むと、ownership と層構成が把握しやすい。
詳細設計や試行錯誤の履歴はこの文書と `docs/runtime-vm-architecture.md` に残してある。

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
- low-level native handle API は `GraphQL::Houtou::Native` が public owner
- `GraphQL::Houtou::Validation` は `validate` だけを公開する最小 facade として残す
- native mainline の internal 専用 stitching は `Runtime::NativeRuntime` から XS を直接呼ぶ
- `SchemaGraph->execute_program(...)` は public entrypoint として残すが、engine 選択と native specialization の ownership は `NativeRuntime` に寄せた
- `VMCompiler` は VM lower / inflate の owner に限定し、native compact struct の ownership は `SchemaGraph` / `VMProgram` / `NativeRuntime` に寄せている
- `GraphQL::Houtou::Native` は public low-level facade に限定し、internal 専用 API の受け皿にはしない
- `GraphQL::Houtou::Validation` は `validate` のみの最小 public facade として固定した
- 旧実装は git history で追えればよく、source tree には残さない
- promise path の current checkpoint では、`ExecState` の `perl_only` 分岐でも
  - `Cursor`
  - `Writer`
  - `FieldFrame`
  - `BlockFrame`
  を native handle owner に寄せている
- `Outcome->scalar/object/list` は class constructor 経由でも常に XS outcome handle を返す
- これにより `t/16_runtime_promise.t` の `outcome handle is no longer valid` 系の破損は解消済み

## 現在のアーキテクチャ

詳細は `docs/runtime-vm-architecture.md` を参照。

実装は次の 4 層に分かれています。

1. Public API
   - `GraphQL::Houtou`
   - `GraphQL::Houtou::Schema`
2. Compile / Lowering
   - `GraphQL::Houtou::Runtime::SchemaGraph`
   - `GraphQL::Houtou::Runtime::OperationCompiler`
   - `GraphQL::Houtou::Runtime::VMCompiler`
   - `GraphQL::Houtou::Runtime::InputCoercion`
3. Runtime / VM
   - `GraphQL::Houtou::Runtime::ExecState`
   - `GraphQL::Houtou::Runtime::Cursor`
   - `GraphQL::Houtou::Runtime::BlockFrame`
   - `GraphQL::Houtou::Runtime::FieldFrame`
   - `GraphQL::Houtou::Runtime::Writer`
4. XS Native Boundary
   - bundle owner: `GraphQL::Houtou::_bootstrap_xs`
   - parser helper: `GraphQL::Houtou::XS::Parser` は公開 facade ではなく、top-level `GraphQL::Houtou::parse*` と XS callback 用の internal helper
   - `XS::Parser` の lazy materialize helper は 1 dialect 前提の parser-internal helper として整理済み
   - `src/parser_ast_runtime.h` / `src/parser_ir_runtime.h` は parser-internal 層であり、runtime / VM mainline の一部ではない
   - compile / validation / native runtime は public facade から XSUB package を直接呼ぶ
   - `GraphQL::Houtou::Runtime::NativeBundle` は Perl wrapper ではなく XS が提供する opaque handle

5. Parser Surface
   - 公開 parser surface は canonical parser AST の 1 dialect に固定
   - `parse_with_options(...)` は `no_location` のような parser-local option だけを受ける
   - dialect/backend の選択 surface と benchmark/profile script 上の旧 option は削除済み
   - compat parser XSUB の公開 entrypoint も active mainline から削除済み

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
- `SchemaGraph` が schema block を直接所有し、`Runtime::Program` 中間層は削除済み
- `Runtime::ProgramSpecializer` は削除済みで、request-time specialization は `Runtime::NativeRuntime` が所有
- `Runtime.pm` は削除済みで、`SchemaGraph` / `Schema` / `NativeRuntime` が直接 mainline を構成する
- native bundle descriptor の inflate/execute は `Runtime::NativeRuntime` が owner
- variable / argument coercion と runtime guard evaluation の shared logic は `Runtime::InputCoercion` が owner
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

## パフォーマンス checkpoint

`Runtime::Program` 削除後、さらに `Runtime::ProgramSpecializer` と Perl wrapper の
`Runtime::NativeBundle` を外し、`Schema` 側の native bundle 組み立ても
`NativeRuntime` ownership に寄せ、`Runtime::execute_vm(...)` も
`NativeRuntime->execute_compact_program(...)` に委譲し、さらに hot path では
`runtime + program` の Perl descriptor hash を組み立てず part-based native load を使い、
compact program 実行時も一時的な native bundle handle を Perl 側で持たず
`execute_native_program_xs(...)` に直接流し、`VMProgram` 側でも compact struct を
毎回再構築せず memoize し、`NativeRuntime->execute_program(...)` も
`compile_bundle -> execute_bundle` ではなく `specialize -> execute_compact_program`
へ直行する
fresh `./Build build` 済み環境で、
`perl -Iblib/lib -Iblib/arch util/execution-benchmark-checkpoint.pl --repeat=3 --count=-3 --case nested_variable_object --case list_of_objects --case abstract_with_fragment`
を実行した中央値は次です。

- current runtime mainline
  - `nested_variable_object`
    - `houtou_runtime_cached_perl` median `18152/s`
    - `houtou_runtime_native_bundle` median `584616/s`
  - `list_of_objects`
    - `houtou_runtime_cached_perl` median `13989/s`
    - `houtou_runtime_native_bundle` median `494673/s`
  - `abstract_with_fragment`
    - `houtou_runtime_cached_perl` median `16183/s`
    - `houtou_runtime_native_bundle` median `553411/s`

- old compiled-ir mainline reference
  - 最終旧アーキテクチャ commit: `ba7fbec`
  - `/tmp/houtou-ba7fbec-src` に archive 展開して `perl Build.PL && ./Build build` 後、
    同じ benchmark script を repeat=3/count=-3 で実行
  - `nested_variable_object`
    - `houtou_compiled_ir` median `56878/s`
  - `list_of_objects`
    - `houtou_compiled_ir` median `58195/s`
  - `abstract_with_fragment`
    - `houtou_compiled_ir` median `38894/s`

解釈:

- current native bundle は旧 `compiled_ir` 比で大幅に速い
  - `nested_variable_object`: 約 `10.3x`
  - `list_of_objects`: 約 `8.5x`
  - `abstract_with_fragment`: 約 `14.2x`
- current cached-perl runtime は旧 `compiled_ir` より遅い
- したがって mainline の本命は Perl VM ではなく native bundle / XS VM 側
- 最近の XS 化 checkpoint 後の中央値:
  - `nested_variable_object`
    - `houtou_runtime_cached_perl` median `18095/s`
    - `houtou_runtime_native_bundle` median `585426/s`
  - `list_of_objects`
    - `houtou_runtime_cached_perl` median `13527/s`
    - `houtou_runtime_native_bundle` median `497824/s`
  - `abstract_with_fragment`
    - `houtou_runtime_cached_perl` median `15887/s`
    - `houtou_runtime_native_bundle` median `549703/s`

## 直近の方針

- 旧 execution mainline の active dependency は削除済み
- 旧 execution / compiled-ir headers
  - `src/execution.h`
  - `src/ir_engine.h`
  - `src/ir_execution.h`
  は source tree から削除済み
- parser public surface は canonical parser AST の 1 dialect に整理した
- type model の `Moo` 依存削減を開始し、`Type`, `Type::List`, `Type::NonNull` は plain Perl object に置き換えた
- `SchemaGraph` は compile / lower ownership のみを持ち、native eligibility 判定は `NativeRuntime` に委譲する
- `ExecState` と `NativeRuntime` が別々に持っていた variable / arg coercion は `InputCoercion` に集約した
- `InputCoercion` の dynamic arg materialization と runtime guard evaluation は `GraphQL::Houtou::XS::VM` helper に移し、Perl 側での再帰 walk を hot path から外した
- `Runtime::Outcome` の constructor と `Runtime::Writer` の `consume_outcome(...)` は `GraphQL::Houtou::XS::VM` helper に移し、kind-first outcome の生成と consume を XS 側へ寄せた
- `gql_runtime_vm_native_runtime_t` は callback 用 `SV*` 群を hot struct に直置きせず、
  `gql_runtime_vm_native_callback_catalog_t` へ分離した。resolver / abstract dispatch で
  必要な Perl object は callback 境界まで遅らせ、sync native 実行状態は slot/block 中心の
  C struct に近づける方針を取っている
- top-level sync `execute` は `promise_code` が無く `engine => 'perl'` でもない限り、
  `build_runtime -> compile_program -> execute_program` を通らず
  `build_native_runtime -> execute_document` に直行する。通常系で Perl VM artifact を
  eager に作らないための変更である
- `ExecState` の abstract runtime type resolution は `GraphQL::Houtou::XS::VM::resolve_runtime_type_xs(...)` に移し、
  - `tag_resolver`
  - `tag_map`
  - `resolve_type`
  - `possible_types + is_type_of`
  の orchestration を Perl hot path から外した
- `Runtime::Cursor`, `FieldFrame`, `PathFrame`, `BlockFrame`, `Outcome`, `Writer`, `ExecState` は
  いずれも XS の opaque handle owner に寄せた thin facade として再実装を進めている
- `ExecState` の
  - current op advance
  - enter/leave field
  - enter/leave block
  は XSUB owner へ移し、Perl 側は orchestrator だけを残す形に移行した
- `Cursor` の snapshot / restore は XSUB 関数名呼び出しではなく `src/vm_runtime.h` の C helper に降ろし、
  `ExecState` の block lifecycle も native helper から直接扱えるようにした
- `BlockFrame` の pending queue は raw outcome pointer ではなく generic `SV*` queue として持ち、
  promise SV と XS-owned outcome handle を同じ queue で扱えるようにした
- `Runtime::ErrorRecord` は XS-owned native record を本体とする thin facade に寄せ、
  resolver/runtime error の message cleanup と path capture は `src/vm_runtime.h` 側で処理する
- 現在の runtime hot path では、`Outcome` / `Writer` / `ErrorRecord` / `FieldFrame` などの
  Perl hash/array は内部通貨ではなく、境界用の facade に限定する方向で再実装している
- `FieldFrame` の `outcome` は XS-owned `gql_runtime_vm_outcome_t *` を直接保持し、
  `BlockFrame` の pending queue だけは promise cold path のため `SV*` queue として維持する。
  これにより sync hot path は C struct owner、promise path は Perl promise object owner という
  分離を明示した。
- historical / internal parser 資料は docs にのみ残し、mainline の API からは `graphql-js` dialect を外した
- parser compatibility 自体は要件から外し、parser 本体と旧互換層が共有していた helper は
  `src/parser_shared_ast.h` へ切り出したうえで parser-internal 層に閉じ込めた
- parser 本体は `src/parser_graphqlperl_runtime.h` に寄せ、互換層の名前は active source から外した
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
## Persisted Queries

- 固定 query / 固定 specialization:
  - `compile_native_bundle`
  - `compile_native_bundle_descriptor`
  を persisted artifact として使う
- 変数つき persisted query:
  - `compile_program`
  - `execute_program`
  を使う
- 詳細:
  - `docs/persisted-queries.md`

## 最新 checkpoint

- Runtime hot subobject の `perl_only` 分岐を削除し、
  - `Cursor`
  - `FieldFrame`
  - `PathFrame`
  - `BlockFrame`
  - `Outcome`
  - `Writer`
  を XS opaque handle owner に統一した
- `ExecState` も subobject 生成時に Perl owner へ戻さず、promise path を含めて native subobject を使う形に揃えた
- `./Build test` / `minil test` はこの状態で通過
- `BlockFrame` の pending inspection / aggregate 用 Perl surface は未使用だったため削除し、
  promise finalize の public 面は `finalize` と XS callback bridge だけに縮小した
