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
- public の `compile_program` / `inflate_program` は `NativeProgram` を返す形に揃え、`VMProgram` は internal inflate/debug 用に後退した
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

## Phase Records

- Phase 3: Runtime Descriptor Ownership
  - completion commit: `ff1f94c`
  - milestone branch: `milestone-c-runtime-native-owner`
  - `NativeProgram` を active runtime path の一次通貨に固定し、variable preparation を `native_program_prepare_variables_xs(...)` へ寄せた
- Phase 4: Promise/DataLoader Native Completion
  - completion commit: `5cdfda4`
  - milestone branch: `milestone-d-promise-native-completion`
  - promise callback bridge / lazy info / callback info の owner を XS 側へ寄せ、promise loop の active path が native descriptor ベースで通る状態にした
- Phase 5: Surface Freeze
  - completion commit: `24a6394`
  - milestone branch: `milestone-e-surface-freeze`
  - `ExecState` を `new/build_for_program/run_program` だけの thin facade に縮退し、`InputCoercion` は active path の `prepare_variables(...)` のみを残す
- Phase 6: Benchmark Gate
  - milestone branch: `milestone-f-benchmark-gate`
  - Phase 5 完了後に `./Build build` と benchmark repeat を回し、keep/revert 判断を記録する

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
   - XS-only opaque handles
     - `GraphQL::Houtou::Runtime::Cursor`
     - `GraphQL::Houtou::Runtime::BlockFrame`
     - `GraphQL::Houtou::Runtime::FieldFrame`
     - `GraphQL::Houtou::Runtime::Writer`
     - `GraphQL::Houtou::Runtime::Outcome`
     - `GraphQL::Houtou::Runtime::PathFrame`
     - `GraphQL::Houtou::Runtime::ErrorRecord`
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
- public descriptor load (`SchemaGraph->inflate_program`, `Schema->load_program_descriptor`) は `NativeProgram` handle を返し、`VMCompiler->inflate_program` は internal lowering 検証だけで使う
- active path の variable preparation は `Runtime::InputCoercion::prepare_variables(...)` だけを残し、coercion loop 自体は `native_program_prepare_variables_xs(...)` が owner
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
- Milestone B (`NativeProgram` mainline / promise native loop) 到達時の中央値:
  - `nested_variable_object`
    - `houtou_runtime_program` median `3381/s`
    - `houtou_runtime_native_bundle` median `343901/s`
  - `list_of_objects`
    - `houtou_runtime_program` median `3391/s`
    - `houtou_runtime_native_bundle` median `284212/s`
  - `abstract_with_fragment`
    - `houtou_runtime_program` median `3382/s`
    - `houtou_runtime_native_bundle` median `265429/s`

- Phase 6 benchmark gate
  - `./Build build` 後に
    `perl util/execution-benchmark-checkpoint.pl --repeat=3 --count=-3`
    を実行した中央値:
  - `nested_variable_object`
    - `houtou_runtime_program` median `3500/s`
    - `houtou_runtime_native_bundle` median `352797/s`
  - `list_of_objects`
    - `houtou_runtime_program` median `3530/s`
    - `houtou_runtime_native_bundle` median `289870/s`
  - `abstract_with_fragment`
    - `houtou_runtime_program` median `3510/s`
    - `houtou_runtime_native_bundle` median `268800/s`

解釈:

- Phase 5 の surface freeze 後でも、Milestone B 比では全 case で改善した
  - `runtime_program`
    - `nested_variable_object`: 約 `+3.5%`
    - `list_of_objects`: 約 `+4.1%`
    - `abstract_with_fragment`: 約 `+3.8%`
  - `native_bundle`
    - `nested_variable_object`: 約 `+2.6%`
    - `list_of_objects`: 約 `+2.0%`
    - `abstract_with_fragment`: 約 `+1.3%`
- 一方で、以前の native bundle high-watermark
  - `nested_variable_object`: `584616/s`
  - `list_of_objects`: `494673/s`
  - `abstract_with_fragment`: `553411/s`
  と比べると、まだ
  - `nested_variable_object`: 約 `39.7%` 低い
  - `list_of_objects`: 約 `41.4%` 低い
  - `abstract_with_fragment`: 約 `51.4%` 低い
- 旧 `compiled_ir` 最終 mainline (`ba7fbec`) と比べると現行 native bundle は依然として速い
  - `nested_variable_object`: 約 `6.2x`
  - `list_of_objects`: 約 `5.0x`
  - `abstract_with_fragment`: 約 `6.9x`

判断:

- Phase 3-5 の batch は revert しない
- 理由は
  - correctness を維持したまま `NativeProgram` 主経路 / promise native loop / surface freeze を完了している
  - Milestone B 比ではすべて改善している
  - 旧 `compiled_ir` mainline 比でも十分に速い
- ただし、過去の native bundle high-watermark にはまだ戻っていない
- 今後さらに詰めるなら、残っている callback/info/materialization の Perl 境界と、
  native descriptor から response 生成までの固定コストが次の本命

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
- `NativeRuntime` と `ExecState` の active path は `NativeProgram` を一次通貨に固定し、`VMProgram -> to_native_program_handle` bridge は public runtime path から外した
- `InputCoercion` は `NativeProgram` の variable defs を Perl hash に戻してから歩かず、`native_program_prepare_variables_xs(...)` で default 解決と coercion をまとめて行う
- `ExecState` は `NativeProgram` の `root_block_index` を専用 XSUB で引き、full descriptor/summary hash を materialize しない
- `ExecState` と `NativeRuntime` が別々に持っていた variable / arg coercion は `InputCoercion` に集約した
- `InputCoercion` の Perl fallback / helper 群は削除し、active path は `NativeProgram` 前提で `native_program_prepare_variables_xs(...)` だけを使う
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
- `Cursor`, `FieldFrame`, `PathFrame`, `BlockFrame`, `Outcome`, `Writer`, `ErrorRecord` は Perl wrapper file を持たない XSUB-only package に縮退済み
- `ExecState` も accessor / internal dispatch surface を削り、`run_program(...)` 中心の thin facade に縮退済み
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
- promise path の active block loop は `_run_via_code` へ戻らず、
  resolver 実行と promise 判定を XS 側で処理するように変更した
- その際に親/子 block 間で `field_frame` を先に free していた所有権バグを修正し、
  `t/16_runtime_promise.t` の `Signal: TRAP` は解消済み
- `ExecState` から未使用になった
  - `run_current_field_via`
  - `run_default_*`
  - `run_explicit_*`
  - `_run_via_code`
  などの Perl dispatch surface を削った

## 2026-05-04 native_bundle fast lane 再特化

- `fe9a58a` `native_bundle sync pathをdirect-SV fast laneへ戻す`
  - `execute_native_bundle_xs(...)` / `execute_native_program_xs(...)` /
    `execute_native_program_handle_xs(...)` を
    `native_value` tree + materialize の 2 パスから、`SV*` を直接組み立てる
    1 パス fast lane に戻した
  - benchmark median:
    - `nested_variable_object`: `393480/s`
    - `list_of_objects`: `340616/s`
    - `abstract_with_fragment`: `304552/s`

- `native_bundle` callback info / abstract fast path の再整理
  - `GraphQL::Houtou::Runtime::LazyInfo` を XS-owned opaque handle に変え、
    `%{}` のときだけ hash を materialize する形にした
  - sync fast lane / promise path の両方で同じ lazy info を使うように揃えた
  - runtime callback catalog に `slot_field_names` cache を追加し、
    field callback で毎回 field 名文字列を作らないようにした
  - `bundle->blocks[*].type_object_sv` を使って block parent type を直参照できるようにした
  - `./Build test` / `minil test` は通過

- ただし benchmark は `fe9a58a` を上回らなかった
  - latest median:
    - `nested_variable_object`: `369154/s`
    - `list_of_objects`: `325661/s`
    - `abstract_with_fragment`: `289557/s`
  - `937edb0` (`restore-native-bundle-high-watermark`) 比ではまだ大きく遅い

- `native_bundle` callback ABI の再特化
  - sync `native_bundle` fast lane で、`resolver_mode => 'native'` の slot に限り
    resolver / abstract callback を `info` 付きの generic ABI から外した
  - field resolver は
    - `($source, $args, $context, $return_type)`
    の軽い ABI へ戻した
  - abstract callback は
    - `tag_resolver($value, $context, $abstract_type, undef)`
    - `resolve_type($value, $context, undef, $abstract_type)`
    - `is_type_of($value, $context, undef, $type)`
    の high-watermark 系 ABI に戻した
  - generic path / promise path / `resolver_mode => 'native'` でない callback は
    既存の `info` 付き ABI を維持した
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`: `522198/s`
  - `list_of_objects`: `431448/s`
  - `abstract_with_fragment`: `483953/s`

- native leaf field の `path_frame` 遅延化
  - `resolver_mode => 'native'` かつ `complete_generic` の slot では、
    success path で `path_frame` を先に作らないようにした
  - error が出たときだけ field path を組み立てて error outcome を作る
  - object/list/abstract completion は親子 path を持つため eager path のまま据え置いた

- latest median:
  - `nested_variable_object`: `531431/s`
  - `list_of_objects`: `449661/s`
  - `abstract_with_fragment`: `510630/s`

- object/list/abstract completion と args/directives specialization の fast-lane 最適化
  - child block 実行時に current field の path が既に eager に積まれているなら、
    子側で同じ field path を二重生成しないように修正した
  - abstract dispatch は
    - `abstract_child_count == 1`
    - `possible_type` が 1 つに決まる
    場合の direct fast path を足し、child block 決定の名前比較を減らした
  - list completion も child block 実行時の field path 生成を整理し、
    success path の allocation を減らした
  - `gql_runtime_vm_evaluate_runtime_guards_native(...)` は
    directive の `if` を `SV*` materialize せず native dynamic value の truthiness だけで評価する
  - `gql_runtime_vm_specialize_arg_payload_native(...)` は
    `native payload -> SV/HV -> native payload` の往復をやめ、
    native payload から直接 specialized native payload を組み立てる
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`: `544514/s`
  - `list_of_objects`: `473653/s`
  - `abstract_with_fragment`: `528011/s`

- 解釈:
  - `6b980d7` 比では
    - `nested_variable_object`: 約 `+1.8%`
    - `list_of_objects`: 約 `+4.2%`
    - `abstract_with_fragment`: 約 `+5.5%`
  - `06b1d64` 比では
    - `nested_variable_object`: 約 `+43.9%`
    - `list_of_objects`: 約 `+38.1%`
    - `abstract_with_fragment`: 約 `+76.3%`
  - `937edb0` (`restore-native-bundle-high-watermark`) 比でもかなり近づいた
    - `nested_variable_object`: 約 `9.1%` 低い
    - `list_of_objects`: 約 `9.1%` 低い
    - `abstract_with_fragment`: 約 `7.7%` 低い
  - 今回の 3 点を入れた最新 batch ではさらに差が縮み、
    `937edb0` 比で
    - `nested_variable_object`: 約 `6.9%` 低い
    - `list_of_objects`: 約 `4.3%` 低い
    - `abstract_with_fragment`: 約 `4.6%` 低い
  - `5fe128b` 比では
    - `nested_variable_object`: 約 `+2.5%`
    - `list_of_objects`: 約 `+5.3%`
    - `abstract_with_fragment`: 約 `+3.4%`
  - ここで分かったことは明確で、現行 branch の主な重みは
    `LazyInfo` 自体より **callback ABI に `info` と generic lookup を持ち込んだこと**
    にあった
  - つまり現行 branch でも、specialized fast lane を切れば
    high-watermark にかなり近い水準まで戻せる見通しがある

- 現時点の判断:
  - `direct-SV` 1 パス自体は keep
  - `LazyInfo` の opaque handle 化と metadata cache は correctness / ownership
    の整理として妥当
  - ただし速さに効いた本命は、`resolver_mode => 'native'` を足掛かりに
    **sync native_bundle path を再び specialized ABI に戻したこと**
  - したがって、今後も「generic runtime をそのまま磨く」より
    「fast lane を明示的に specialized に保つ」方が筋が良い

- 次に詰めるべきこと:
  1. abstract dispatch の type lookup / callback catalog 直参照をさらに詰める
  2. `resolver_mode => native` 以外を specialized fast lane に含める価値があるか切り分ける
  3. promise/DataLoader 主経路へ今回の fast-lane 判断をどこまで逆輸入するか決める
