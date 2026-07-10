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
- low-level native handle API は `GraphQL::Houtou` が XS を bootstrap した後の
  `GraphQL::Houtou::XS::VM` に直接出す
- `GraphQL::Houtou::Validation` は `validate` だけを公開する最小 facade として残す
- native mainline の internal 専用 stitching は `Runtime::NativeRuntime` から XS を直接呼ぶ
- `SchemaGraph->execute_program(...)` は public entrypoint として残すが、engine 選択と native specialization の ownership は `NativeRuntime` に寄せた
- public の `compile_program` / `inflate_program` は `NativeProgram` を返す形に揃え、`VMProgram` は internal inflate/debug 用に後退した
- `VMCompiler` は VM lower / inflate の owner に限定し、native compact struct の ownership は `SchemaGraph` / `VMProgram` / `NativeRuntime` に寄せている
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
- Promise::XS fast path branch
  - branch: `promise-xs-fast-path`
  - `cpanfile` では `Promise::XS` を `https://github.com/AnaTofuZ/p5-Promise-XS.git` の `master` 参照にした
  - ローカル検証は upstream checkout を submodule ごとに展開して `local/` へ manual install する運用に切り替えた
  - `GraphQL::Houtou::Promise::PromiseXS` を追加し、
    - `Promise::XS::all(...)` の row-array 返却を Houtou 向けに正規化
    - no-event-loop 環境で callback が即時に走る場合だけ `then(...)` を short-circuit
    する helper を導入した
  - `t/16_runtime_promise.t` に Promise::XS-backed case を追加
  - async benchmark harness は `--include-async --promise-backend promise_xs` で Houtou 単独計測できる
  - Promise::XS marker (`_houtou_promise_backend => 'promise_xs'`) を XS state に通し、
    async path では
    - `is_promise` を direct class check
    - `Promise::XS::all(...)` を direct call
    - flatten callback を global XSUB callback
    - fulfilled 済み promise は `Promise::XS::Promise::AWAIT_IS_READY` / `AWAIT_GET` で short-circuit
    - pending / rejected は通常の `then(...)` 経路へフォールバック
    で扱えるようにした

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

## 内部表現

hot path の内部表現は Perl の `{ data => ..., errors => ... }` ではなく、
次の kind-first / state-first なランタイムオブジェクトです。

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

- Promise::XS async benchmark on `promise-xs-fast-path`
  - `perl util/execution-benchmark-checkpoint.pl --repeat=3 --count=-1 --include-async --promise-backend promise_xs`
    の中央値:
  - `async_scalar`
    - initial adapter/helper path: `3140/s`
    - direct Promise::XS fast path: `3111/s`
    - `AWAIT_IS_READY/AWAIT_GET` short-circuit 後: `3229/s`
  - `async_list`
    - initial adapter/helper path: `3026/s`
    - direct Promise::XS fast path: `3082/s`
    - `AWAIT_IS_READY/AWAIT_GET` short-circuit 後: `3170/s`
  - `async_object`
    - initial adapter/helper path: `3082/s`
    - direct Promise::XS fast path: `3054/s`
    - `AWAIT_IS_READY/AWAIT_GET` short-circuit 後: `3169/s`
  - `async_abstract`
    - initial adapter/helper path: `3082/s`
    - direct Promise::XS fast path: `3054/s`
    - `AWAIT_IS_READY/AWAIT_GET` short-circuit 後: `3169/s`
  - 解釈:
    - Promise::XS master の `AWAIT_IS_READY/AWAIT_GET` を使う fulfilled-promise short-circuit は有効
    - direct Promise::XS fast path 比で
      - `async_scalar`: 約 `+3.8%`
      - `async_list`: 約 `+2.9%`
      - `async_object`: 約 `+3.8%`
      - `async_abstract`: 約 `+3.8%`
      改善した
    - 一方で promise callback / outcome object 生成はまだ支配的で、次の本命は callback ABI と pending queue の更なる専用化

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
  Perl hash/array は内部表現ではなく、境界用の facade に限定する方向で再実装している
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

- callback ABI code / empty args / slot metadata cache
  - slot に `callback_abi_code` を追加し、
    - default
    - explicit generic
    - explicit native
    を runtime native struct 上で明示的に分けた
  - explicit generic callback は 5-arg ABI を維持したまま、
    slot type object を direct 参照する fast path に寄せた
  - explicit native callback だけ 4-arg fast ABI を使うように整理し、
    `resolver_mode_code == 2` への過剰依存を外した
  - sync `native_bundle` fast lane の `ExecState` に empty args singleton を持たせ、
    no-args field で毎回空 hashref を作らないようにした
  - native slot に
    - `result_name_len`
    - `field_name_len`
    を持たせて、inner loop の `strlen(...)` を削った
  - runtime 初期化時に、explicit callback slot の `slot_type_object` が
    direct 参照で埋まっていることを検証するようにした
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`: `551441/s`
  - `list_of_objects`: `493746/s`
  - `abstract_with_fragment`: `558484/s`

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
  - callback ABI / empty args / slot metadata cache を入れた最新 batch では
    `937edb0` 比で
    - `nested_variable_object`: 約 `5.7%` 低い
    - `list_of_objects`: 約 `0.2%` 低い
    - `abstract_with_fragment`: 約 `0.9%` 速い
  - つまり、high-watermark との差はもう
    - nested の args / variable 系固定コスト
    - generic info callback が残る case
    にほぼ局所化できている
  - つまり現行 branch でも、specialized fast lane を切れば
    high-watermark にかなり近い水準まで戻せる見通しがある

- 現時点の判断:
  - `direct-SV` 1 パス自体は keep
  - `LazyInfo` の opaque handle 化と metadata cache は correctness / ownership
    の整理として妥当
  - ただし速さに効いた本命は、`resolver_mode => 'native'` を足掛かりに
    **sync native_bundle path を再び specialized ABI に戻したこと**

- static args materialization cache
  - `ARGS_STATIC` かつ `EXPLICIT_NATIVE` fast ABI の slot では、
    native args payload に materialized args hashref を 1 回だけ作って保持し、
    以降の request では `HV` を再生成しないようにした
  - generic callback ABI の slot では従来どおり毎回 materialize して、
    callback 互換性の前提は変えない
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`: `566900/s`
  - `list_of_objects`: `479683/s`
  - `abstract_with_fragment`: `539309/s`

- 解釈:
  - `f304ae9` 比では
    - `nested_variable_object`: 約 `+2.8%`
    - `list_of_objects`: 約 `-2.8%`
    - `abstract_with_fragment`: 約 `-3.4%`
  - `937edb0` (`restore-native-bundle-high-watermark`) 比では
    - `nested_variable_object`: 約 `3.0%` 低い
    - `list_of_objects`: 約 `3.0%` 低い
    - `abstract_with_fragment`: 約 `2.6%` 低い
  - つまり、`nested` の残差はほぼ `ARGS_STATIC` の毎回 materialize だった
    という仮説は当たっていた
  - 一方で list / abstract は今回の変更では本質的に触っていないので、
    ここで残っている差は
    - bundle 実行前の type object 準備
    - per-request writer allocation
    - abstract/type callback 周辺の固定コスト
    に寄っていると見てよい

- bundle block type-object warmup skip / stack writer
  - native bundle に `prepared_runtime_schema` を持たせ、
    同じ runtime schema での再実行では block type object 準備を丸ごとスキップするようにした
  - runtime schema が変わった場合だけ、既存の block type object を捨てて再解決する
  - sync fast lane の writer は heap alloc をやめ、stack storage を初期化/破棄する形に切り替えた
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`: `579118/s`
  - `list_of_objects`: `490021/s`
  - `abstract_with_fragment`: `553731/s`

- 解釈:
  - `21a301d` 比では
    - `nested_variable_object`: 約 `+2.2%`
    - `list_of_objects`: 約 `+2.2%`
    - `abstract_with_fragment`: 約 `+2.7%`
  - `937edb0` (`restore-native-bundle-high-watermark`) 比では
    - `nested_variable_object`: 約 `0.9%` 低い
    - `list_of_objects`: 約 `0.9%` 低い
    - `abstract_with_fragment`: 約 `0.1%` 速い
  - つまり、現行 branch の specialized fast lane でも
    high-watermark と実質同水準まで戻せた
  - 残差は benchmark ばらつきで吸収される範囲にかなり近く、
    次に差が出るとすれば
    - abstract callback/type lookup の残りの generic fallback
    - sync fast lane 以外の program path 固定コスト
    の方が支配的と見てよい
  - したがって、今後も「generic runtime をそのまま磨く」より
    「fast lane を明示的に specialized に保つ」方が筋が良い

- global singleton / direct wrapper / variable-invariant fast lane
  - `Native.pm` は module load 時に一度だけ XS bootstrap し、
    hot path で `_ensure_vm_xs_loaded()` を毎回呼ばないようにした
  - sync fast lane の
    - empty args
    - empty errors
    は global singleton を使い、per-call の空 hashref / arrayref allocation を削った
  - `NativeProgram` は request-local variables を焼き込まない variable-invariant artifact として扱い、
    `execute_native_program_handle_xs(...)` は runtime ごとの cached bundle を再利用する
  - cached bundle 作成時には
    - static args の coercion/default 適用
    - static directive guard の prune
    だけを一度だけ済ませ、program 本体は mutate しない
  - `SchemaGraph->execute_program(...)` も毎回 `NativeRuntime->new(...)` し直さず、
    cached native runtime を再利用する
  - sync `execute_program(...)` は request ごとに program clone/specialize を行わず、
    prepared variables を request-local state として fast lane へ流す
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`
    - `houtou_runtime_program`: `192200/s`
    - `houtou_runtime_native_bundle`: `621166/s`
  - `list_of_objects`
    - `houtou_runtime_program`: `319894/s`
    - `houtou_runtime_native_bundle`: `517177/s`
  - `abstract_with_fragment`
    - `houtou_runtime_program`: `348646/s`
    - `houtou_runtime_native_bundle`: `583519/s`

- 解釈:
  - `f6c9a24` 比では
    - `runtime_program`
      - `nested_variable_object`: 約 `+5890%`
      - `list_of_objects`: 約 `+9760%`
      - `abstract_with_fragment`: 約 `+10669%`
    - `native_bundle`
      - `nested_variable_object`: 約 `+7.3%`
      - `list_of_objects`: 約 `+5.5%`
      - `abstract_with_fragment`: 約 `+5.4%`
  - `937edb0` (`restore-native-bundle-high-watermark`) 比では
    - `runtime_program` は大幅に速くなり、もはや別物の水準に入った
    - `native_bundle`
      - `nested_variable_object`: 約 `+6.2%`
      - `list_of_objects`: 約 `+4.5%`
      - `abstract_with_fragment`: 約 `+5.4%`
  - つまり、
    - `native_bundle` は high-watermark を明確に超えた
    - `runtime_program` は sync path がようやく fast lane に統一された
  - ここでの設計判断として重要なのは、
    variable-bearing query の本命は「variables ごとに artifact を焼き直すこと」ではなく
    **variable-invariant NativeProgram + request-local prepared variables**
    に切ることだった

- 次に詰めるべきこと:
  1. nested の残差を詰めるため、args / variable coercion の固定コストをさらに落とす
  2. explicit generic callback で `info` を要求しない case を見分けられるなら、ABI をもう一段 specialized にできるか検討する
  3. promise/DataLoader 主経路へ今回の callback ABI / metadata cache の判断をどこまで逆輸入するか決める

- path frame borrowed key / async raw path frame
  - `gql_runtime_vm_path_frame_t` に
    - `key_pv_len`
    - `key_pv_borrowed`
    を追加し、result name 由来の path key は `slot->result_name` を borrow するようにした
  - `gql_runtime_vm_new_result_path_frame(...)` と sync fast lane / sync `execute_program(...)` の field path 構築は
    `newSVpv(...) + memcpy` ではなく borrowed path frame を使う
  - promise path では内部 async 実行が `PathFrame` handle を毎回 wrap/unwrap せず、
    raw `gql_runtime_vm_path_frame_t *` を
    - resolver bridge
    - complete callback
    - error callback
    - nested object/list/abstract completion
    まで流す形に変更した
  - error outcome / lazy info も内部 path は raw pointer で受け取り、
    handle 化は public 境界だけに寄せた
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`
    - `houtou_runtime_program`: `205906/s`
    - `houtou_runtime_native_bundle`: `650345/s`
  - `list_of_objects`
    - `houtou_runtime_program`: `338460/s`
    - `houtou_runtime_native_bundle`: `548036/s`
  - `abstract_with_fragment`
    - `houtou_runtime_program`: `364181/s`
    - `houtou_runtime_native_bundle`: `611211/s`

- 解釈:
  - `74d7324` 比では
    - `runtime_program`
      - `nested_variable_object`: 約 `+7.1%`
      - `list_of_objects`: 約 `+5.8%`
      - `abstract_with_fragment`: 約 `+4.5%`
    - `native_bundle`
      - `nested_variable_object`: 約 `+4.7%`
      - `list_of_objects`: 約 `+6.0%`
      - `abstract_with_fragment`: 約 `+4.7%`
  - borrowed path key だけでなく、async 内部の `PathFrame` handle 往復を消したことが
    sync / async 共通の固定コスト削減として効いている
  - 現時点では
    - sync fast lane は引き続き high-watermark を上回っている
    - `runtime_program` も fast lane 統一後の改善が継続している
  - 次の本命は
    - async promise queue / pending merge 自体の専用 fast lane 化
    - `source` ownership を表現したうえでの default leaf `newSVsv` 削減
    の 2 点

- promise queue / callback lookup の軽量化
  - promise block finalize で pending をいったん `AV` に積み直すのをやめ、
    `promise_all_cb` へ stack へ直接 `XPUSHs(...)` する形に変更した
  - pending が `Outcome` の場合だけ、その場で mortal handle を作って push し、
    promise 自体は clone せず borrowed `SV*` をそのまま流す
  - `wrap_object_outcome_callback_xs` / `wrap_list_outcome_callback_xs` は
    BOOT 時に global coderef cache を初期化し、promise path では
    毎回 `get_cv(...)` + `newRV_inc(...)` しないようにした
  - `./Build test` / `minil test t/16_runtime_promise.t t/17_runtime_errors.t t/20_public_runtime_api.t`
    は通過

- 解釈:
  - ここは promise/DataLoader 主経路の固定コスト削減で、現行 benchmark script の
    sync-only case には直接は現れない
  - 今回の変更で減っているのは
    - block finalize の中間 `AV` alloc
    - promise 値の `newSVsv(...)`
    - outcome wrapper callback の coderef lookup
    の 3 点
  - 次の D の本命は引き続き
    - pending merge の outcome handle churn 削減
    - promise callback 後の response materialization 専用 fast lane
    になる

- pending merge の native-first 化と field frame resolved value の削減
  - `pending_merge_resolve` は base object をいったん Perl hash に materialize して clone するのをやめ、
    `frame->values_value` へ `consume_outcome_native_object(...)` で直接 merge してから
    最後に 1 回だけ materialize する形に変更した
  - `block_frame_merge_pending_xs(...)` も同じ native-first merge に揃えた
  - active path の `FieldFrame->resolved_value` は実行中に参照していなかったため、
    sync/async hot loop での `newSVsv(...)` 更新をやめ、field frame の初期値も `NULL` にした
  - `./Build test` / `minil test` は通過

- latest median:
  - `nested_variable_object`
    - `houtou_runtime_program`: `191565/s`
    - `houtou_runtime_native_bundle`: `605390/s`
  - `list_of_objects`
    - `houtou_runtime_program`: `318515/s`
    - `houtou_runtime_native_bundle`: `516388/s`
  - `abstract_with_fragment`
    - `houtou_runtime_program`: `346092/s`
    - `houtou_runtime_native_bundle`: `582772/s`

- 解釈:
  - この batch 自体は promise/DataLoader 主経路向けで、現行 benchmark script の sync-only case では
    効果を直接測れていない
  - sync median は `0a4d66d` 時点の局所 peak より少し低いが、
    `937edb0` (`restore-native-bundle-high-watermark`) 比では
    - `nested_variable_object`: 約 `+3.6%`
    - `list_of_objects`: 約 `+4.4%`
    - `abstract_with_fragment`: 約 `+5.3%`
    を維持している
  - promise 主経路で残る大きいコストは、現行 promise adapter ABI のもとでは
    - per-promise callback CV/closure 生成
    - callback 境界での owned `SV*` 化
    にほぼ収束している
  - つまり、D は「現行 ABI を変えずに取れる async hot path のコスト削減」は一通り入った状態とみなせる

- Promise::XS auto-detect mainline と generic promise adapter の撤去
  - `GraphQL::Houtou::Promise::Adapter` を削除し、generic `promise_code` 注入を public API から外した
  - top-level `execute(...)` / `Schema->execute(...)` / `NativeRuntime->execute_program(...)` は
    `promise_code` を受け取ると即 error にした
  - async execution の mainline は Promise::XS 固定に寄せ、
    resolver が `Promise::XS::Promise` を返したら自動的に async path へ昇格する
  - `execute_native(...)` は explicit sync/native fast lane として維持し、
    内部的には `engine => 'native'` を明示して native bundle / native program 実行へ入る
  - `ExecState` handle / XS runtime から
    - `promise_code`
    - `promise_then_cb`
    - `promise_all_cb`
    - `promise_is_promise_cb`
    を外し、Promise::XS direct path に寄せた
  - `t/16_runtime_promise.t` は generic adapter 互換テストをやめ、
    `promise_code` rejection と Promise::XS auto-detect を見る構成に変えた
  - `minil test t/15_runtime_execute.t t/16_runtime_promise.t t/20_public_runtime_api.t` 通過
  - `minil test` 通過

- latest median (after Promise::XS auto-detect switch)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `3197/s`
      - `houtou_runtime_native_bundle`: `570511/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `3269/s`
      - `houtou_runtime_native_bundle`: `496243/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `3207/s`
      - `houtou_runtime_native_bundle`: `569399/s`
  - async (`--include-async --promise-backend promise_xs`):
    - `async_scalar`
      - `houtou_runtime_program`: `3082/s`
    - `async_list`
      - `houtou_runtime_program`: `2983/s`
    - `async_object`
      - `houtou_runtime_program`: `3027/s`
    - `async_abstract`
      - `houtou_runtime_program`: `3011/s`

- 解釈:
  - public async interface は `promise_code` 注入なしで Promise::XS auto-detect に一本化できた
  - `execute_native(...)` の explicit fast lane は維持されているので、
    sync-first の native benchmark / persisted artifact path は引き続き分離できる
  - current benchmark script 上では
    - sync native bundle は依然として high-watermark 級の水準を維持
    - Promise::XS async path は `3.0k/s` 前後で、generic adapter を抱えたままの構成より単純になった
  - ここから先の本命は
    - Promise::XS continuation / batch continuation の further specialization
    - auto-detect mainline と sync fast lane の benchmark surface の再整理

- Perl 5.14 CI workaround for Promise::XS direct-await shortcut
  - `t/16_runtime_promise.t` が Perl 5.14 の GitHub Actions で SEGV したため、
    Promise::XS direct `AWAIT_IS_READY` / `AWAIT_GET` shortcut を old perl では無効化した
  - 対象は [`gql_runtime_vm_promise_xs_is_ready_now(...)`] と
    [`gql_runtime_vm_promise_xs_try_get_sync_values_av(...)`]
  - `PERL_VERSION < 5.16` では最適化を使わず、通常の `then(...)` path へフォールバックする
  - 5.42 では `minil test t/16_runtime_promise.t` / `minil test` ともに通過
  - 原因の見立て:
    - Promise::XS direct await helper 自体、または old perl の callback / await lifetime 周辺が怪しい
    - shortcut は最適化であって必須ではないので、old perl では安全側に倒した

- Promise::XS undocumented await shortcut removal
  - clean Docker で `e7ab702` を Perl `5.16`, `5.18`, `5.20`, `5.22`, `5.24`, `5.26`, `5.30`
    まで検証したところ、`t/16_runtime_promise.t` の終了時 SEGV は old perl 限定ではなかった
  - `Promise::XS::Promise::AWAIT_IS_READY` / `AWAIT_GET` は POD や export surface に載っておらず、
    stable な public API とみなせないため mainline から撤去した
  - Promise::XS fast path は documented な `then` / `all` と promise type 判定だけに戻す

- `optimize-async-xsub-entry` branch follow-up
  - public async mainline の入口を XSUB 化した `9f68eeb` の上で、leaf/generic async completion の callback churn を削減した
  - `GQL_VM_COMPLETE_GENERIC` で resolver が promise を返したとき、
    per-field `complete_callback` を作らず shared identity callback を使い、
    block finalize 時に pending merge で native object へ書き戻す
  - pending payload kind に `GQL_VM_PENDING_PROMISE_GENERIC_VALUE_SV` を追加し、
    `Outcome` handle を経由しない generic scalar completion を block 単位で処理できるようにした
  - Promise callback 用 identity XSUB は `PPCODE` 委譲をやめて通常の `CODE/OUTPUT` で返し、
    Promise::XS に返す fulfilled value は `SvREFCNT_inc` ベースの ownership transfer にした
  - `NativeRuntime->execute_program(...)` の auto path は Promise::XS async mainline へ直接入るまま維持しつつ、
    `G_EVAL` helper で stale `$@` を持ち込まないように整理した
  - `execute_native_program_auto_xs(...)` hot path で `sv_derived_from(...)` 前の
    `SvOK(...)` guard を追加し、`uninitialized` warning の発生源自体を潰した
  - `./Build test` 通過

- latest median (after leaf/generic async callback reduction)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `144777/s`
      - `houtou_runtime_native_bundle`: `571946/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `202885/s`
      - `houtou_runtime_native_bundle`: `502626/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `194682/s`
      - `houtou_runtime_native_bundle`: `563581/s`
  - async (`--include-async --promise-backend promise_xs`):
    - `async_scalar`
      - `houtou_runtime_program`: `166134/s`
    - `async_list`
      - `houtou_runtime_program`: `123675/s`
    - `async_object`
      - `houtou_runtime_program`: `127999/s`
    - `async_abstract`
      - `houtou_runtime_program`: `110277/s`

- 解釈:
  - async mainline は `9f68eeb` 時点からさらに
    - `async_scalar`: 約 `+5.3%`
    - `async_list`: 約 `-0.9%`
    - `async_object`: 約 `+0.9%`
    - `async_abstract`: 約 `+0.5%`
    と、leaf-heavy case を中心に改善した
  - sync `runtime_program` は query ごとに増減があるが、public mainline が `100k/s` を大きく超える水準は維持している
  - specialized `native_bundle` はほぼ横ばいで、今回の batch の主効果は async/public path 側にある

- `optimize-async-batch-continuation` branch follow-up
  - async pending entry に
    - `path_frame`
    - `block_index`
    - `slot_index`
    - `op_index`
    - `result_name_pv_borrowed`
    を追加し、field ごとの complete callback を作らず block finalize で completion できるようにした
  - resolver promise は `identity + error_callback` で正規化し、
    - generic field は raw value pending
    - object/list/abstract は resolved-value pending
    に分けて積む
  - finalize callback は
    - phase 1: resolved value を `complete_async(...)` へ流す
    - phase 2: nested completion が返した outcome promise だけを再度 finalize する
    形の 2-phase continuation になった
  - immediate outcome pending は `Promise::XS::all(...)` に入れず、finalize 前に `values_value` へ直接 merge する
  - pending result name は slot lifetime にぶら下がる borrowed pointer を使い、
    async hot path の `savepvn/free` を削った
  - `./Build test` 通過
- latest median (after async batch continuation / native-first merge)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `150436/s`
      - `houtou_runtime_native_bundle`: `592111/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `194869/s`
      - `houtou_runtime_native_bundle`: `517476/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `187563/s`
      - `houtou_runtime_native_bundle`: `570511/s`
  - async (`--include-async --promise-backend promise_xs`):
    - `async_scalar`
      - `houtou_runtime_program`: `170666/s`
    - `async_list`
      - `houtou_runtime_program`: `127999/s`
    - `async_object`
      - `houtou_runtime_program`: `132741/s`
    - `async_abstract`
      - `houtou_runtime_program`: `111348/s`
- 解釈:
  - async mainline は直前 checkpoint 比で
    - `async_scalar`: 約 `+2.7%`
    - `async_list`: 約 `+3.5%`
    - `async_object`: 約 `+3.7%`
    - `async_abstract`: 約 `+1.0%`
    と全 case で改善した
  - object/list/abstract でも per-field complete callback を減らせたので、
    leaf-heavy case 以外にも改善が広がった
  - sync `native_bundle` も即時 outcome pending の pre-merge によりわずかに改善した

- `optimize-async-scheduler` branch checkpoint
  - async block finalize を Promise chain 主導から XS scheduler 主導へ寄せた
    - root block は `Promise::XS::deferred` を 1 個だけ持ち、
      ready block queue を drain して resolve する
    - mainline の `block_frame_finalize_sv(...)` は `Promise::XS::all(...)`
      を使わず、pending entry の state machine を arm/drain する
  - `pending_entry` に `state_code` と borrowed result-name ownership を追加し、
    pending result name の `savepvn/free` を減らした
  - object/list/abstract を scheduler drain 側へ寄せ、
    nested completion promise は phase 2 の pending として再投入する形にした
  - 実装中に見つかった correctness bug を修正
    - Promise callback の resolved value / outcome を copy する前に元の promise
      を `SvREFCNT_dec` してしまい、scalar と outcome handle が壊れていた
    - list item promise は resolved callback が同期実行される前提なので、
      `unresolved_count` を callback 登録前に全件数えておかないと early resolve
      して 2 件目以降が落ちる
  - `./Build test` 通過
- latest median (after async scheduler / root deferred / no-mainline-all)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `151775/s`
      - `houtou_runtime_native_bundle`: `589278/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `194794/s`
      - `houtou_runtime_native_bundle`: `510630/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `188449/s`
      - `houtou_runtime_native_bundle`: `576014/s`
  - async (`--include-async --promise-backend promise_xs`)
    - `async_scalar`
      - `houtou_runtime_program`: `180705/s`
    - `async_list`
      - `houtou_runtime_program`: `125754/s`
    - `async_object`
      - `houtou_runtime_program`: `140894/s`
    - `async_abstract`
      - `houtou_runtime_program`: `118153/s`
- 解釈:
  - async mainline は前 checkpoint 比で
    - `async_scalar`: 約 `+5.9%`
    - `async_list`: 約 `-1.8%`
    - `async_object`: 約 `+6.1%`
    - `async_abstract`: 約 `+6.1%`
    となり、list 以外の case で scheduler 化の効果が出た
  - list は `Promise::XS::all(...)` を外した代わりに list-specific scheduler の
    固定コストが残っており、次の調整点になった
  - sync `runtime_program` / `native_bundle` はほぼ横ばいで、今回の batch の
    主効果は async path にある

- `optimize-async-scheduler` branch checkpoint (rootless finalize fix / internal list pending)
  - root async finalize の use-after-free を修正した
    - root frame は `Promise::XS::resolved(...)` が即時 callback を走らせても、
      `block_frame_finalize_sv(...)` の途中で promise handle を失わない
    - rootless child block (`return_pending_handle = 1`) は finalize 時点で drain せず、
      親 block に接続してから scheduler が処理する
  - list async path から internal `Promise::XS::deferred` を外した
    - `GraphQL::Houtou::Runtime::ListPending` handle を追加
    - list item promise は `ListPending` 内で callback を張り、
      全 item が揃ったら owner frame を ready queue へ戻す
    - mainline では top-level response 以外の list 集約用 Promise を作らない
  - async pending ownership をもう一段整理した
    - child block / list pending の owner frame を explicit に持たせた
    - pending result-name は引き続き borrowed pointer で持つ
  - `./Build test` 通過
- latest median (after rootless finalize fix / internal list pending)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `146688/s`
      - `houtou_runtime_native_bundle`: `572334/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `187570/s`
      - `houtou_runtime_native_bundle`: `494673/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `186163/s`
      - `houtou_runtime_native_bundle`: `560274/s`
  - async (`--include-async --promise-backend promise_xs`)
    - `async_scalar`
      - `houtou_runtime_program`: `176987/s`
    - `async_list`
      - `houtou_runtime_program`: `143479/s`
    - `async_object`
      - `houtou_runtime_program`: `135244/s`
    - `async_abstract`
      - `houtou_runtime_program`: `114840/s`
- 解釈:
  - 直前 checkpoint 比で async は
    - `async_scalar`: 約 `-2.1%`
    - `async_list`: 約 `+14.1%`
    - `async_object`: 約 `-4.0%`
    - `async_abstract`: 約 `-2.8%`
    となり、internal list promise の撤去は list-heavy case に明確に効いた
  - その代わり object / abstract はまだ internal outcome/materialization cost が残り、
    次の主戦場は nested block / list item の native container 化と clone 削減になった
  - sync `runtime_program` / `native_bundle` は小幅なぶれの範囲で、
    今回の batch の主目的は async scheduler の内部 artifact 整理だった

- `optimize-async-scheduler` branch checkpoint (native-first nested object completion)
  - nested object / abstract child block の immediate 完了で Perl hash へ materialize してから
    `Outcome` に包み直していた経路を外した
    - `return_pending_handle = 1` の child block が pending 0 の場合は
      owned native object value から直接 `Outcome` を返す
    - object / abstract completion はその `Outcome` をそのまま親へ返す
  - `gql_runtime_vm_exec_state_complete_async_sv(...)` から
    - `cursor` の snapshot / restore
    - `FieldFrame` の alloc / free
    を外した
    - native program の `block/op/slot` を直接引いて completion する
    - completion 専用 path では `FieldFrame` を参照していなかったので削除は意味論に影響しない
  - `./Build test` 通過
- latest median (after native-first nested object completion)
  - async (`--include-async --promise-backend promise_xs`)
    - `async_scalar`
      - `houtou_runtime_program`: `175363/s`
    - `async_list`
      - `houtou_runtime_program`: `146161/s`
    - `async_object`
      - `houtou_runtime_program`: `143479/s`
    - `async_abstract`
      - `houtou_runtime_program`: `122530/s`
- 解釈:
  - 直前 checkpoint 比で async は
    - `async_scalar`: 約 `-0.9%`
    - `async_list`: 約 `+1.9%`
    - `async_object`: 約 `+6.1%`
    - `async_abstract`: 約 `+6.7%`
    となり、狙いどおり object / abstract completion に効いた
  - list は internal Promise 撤去の checkpoint で大きく改善し、今回の batch では小幅上積み
  - scalar は誤差の範囲で、残る主課題は
    - Promise callback 後の scalarish snapshot
    - list item の native container 化の徹底
    - nested block / list pending のさらに direct な merge
    に絞られてきた

- `optimize-async-scheduler` branch checkpoint (async native resolver ABI + lower-overhead field/list state)
  - async resolver path が `resolver_mode => native` / `callback_abi_code` を見ずに
    常に generic ABI (`args + info + return_type`) を組んでいたのを修正した
    - `gql_runtime_vm_exec_state_resolve_current_value_sv(...)` で
      `GQL_VM_CALLBACK_ABI_EXPLICIT_NATIVE` は sync fast lane と同じ 4-arg ABI を使う
    - benchmark の async cases はすべて `resolver_mode => native` なので、
      ここが今回の主因だった
  - nested block execute の per-op `FieldFrame` を stack frame に置き換えた
    - async/sync ともに `new/free` を外し、hot loop の heap churn を減らした
  - list pending の内部集約を `AV` ではなく native list value に変更した
    - item promise 完了後に Perl `AV` を更新せず、
      native list value を index 代入で埋める
    - ready 時はその owned native list から直接 `Outcome` を作って親 frame に consume する
  - async immediate outcome の hot path で `Outcome` handle を作って直後に unwrap する往復を削減した
  - `./Build test` 通過
- latest median (after async native resolver ABI + lower-overhead field/list state)
  - sync:
    - `nested_variable_object`
      - `houtou_runtime_program`: `157284/s`
      - `houtou_runtime_native_bundle`: `549818/s`
    - `list_of_objects`
      - `houtou_runtime_program`: `202239/s`
      - `houtou_runtime_native_bundle`: `483840/s`
    - `abstract_with_fragment`
      - `houtou_runtime_program`: `209024/s`
      - `houtou_runtime_native_bundle`: `544514/s`
  - async (`--include-async --promise-backend promise_xs`)
    - `async_scalar`
      - `houtou_runtime_program`: `183991/s`
    - `async_list`
      - `houtou_runtime_program`: `150377/s`
    - `async_object`
      - `houtou_runtime_program`: `143479/s`
    - `async_abstract`
      - `houtou_runtime_program`: `124660/s`
- 解釈:
  - 直前 checkpoint 比で async は
    - `async_scalar`: 約 `+4.9%`
    - `async_list`: 約 `+2.9%`
    - `async_object`: ほぼ同水準
    - `async_abstract`: 約 `+1.7%`
    となり、async mainline は全体として baseline を上回った
  - いちばん効いたのは async resolver path が native fast ABI を使っていなかった点の修正で、
    field/list state の軽量化はそれを補助した形
  - まだ sync `native_bundle` との差は大きく、
    次の本命は
    - nested block の internal Promise / Outcome artifact をさらに減らすこと
    - ownership provenance を持たせて safe な clone を削ること
    - object / abstract completion の internal result representation を raw/native 寄りにすること
    になる

## 2026-07-05 benchmark gate: real-traffic cases

- `util/execution-benchmark.pl` に 2 ケースを追加した
  - `varying_variables`: 毎リクエスト異なる variables を渡す
    (`vars_generator`)。実 Web トラフィックの形で、specialized program
    cache が毎回ミスする経路を測る。native_bundle mode は固定 variables
    前提のため対象外
  - `list_of_objects_json`: execute 結果を JSON::MaybeXS で encode する
    実効スループット(`json` flag)
- `util/execution-benchmark-checkpoint.pl` の sync 既定ケースにも追加した
- baseline median (repeat=3, count=-1):
  - `varying_variables`
    - `houtou_runtime_program`: `55351/s`
  - `list_of_objects_json`
    - `houtou_runtime_program`: `223417/s`
    - `houtou_runtime_native_bundle`: `490119/s`
  - 比較: 同一クエリ固定 variables の `nested_variable_object`
    `houtou_runtime_program` は `208524/s`
- 解釈:
  - 変数が毎回異なると public program path は固定比で約 `3.8x` 遅い。
    毎リクエストの variables 全体シリアライズによる cache key 生成と、
    ミス時の program clone/specialize/evict が原因
    (`docs/performance-and-robustness-plan.md` Phase A-2 の対象)
  - JSON encode は native_bundle 実行の実効値を大きく削る。
    Phase C (`execute_to_json`) のゲートとして使う

## 2026-07-05 variable-invariant execute_program (Phase A-2)

- `execute_program` の variables あり経路が、runtime directive を持たない
  program でも毎リクエスト
  - 変数ハッシュ全体の Perl 文字列シリアライズ(cache key)
  - miss 時の program clone / specialize / FIFO evict
  を払っていた問題を修正した
- `gql_runtime_vm_program_needs_variable_specialization(...)` を追加し、
  「op が runtime directive または variables 依存の directive guard
  (`directives_mode == DYNAMIC`)を持つか」を program 構造体に memoize した
  (`native_program_needs_variable_specialization_xs`)
- フラグが立たない program(大多数)は specialize せず、
  variable-invariant な cached bundle + request-local prepared variables で
  直接実行する。フラグが立つ program のみ従来の specialized cache を使う
- specialized cache の key は 2048 bytes を上限とし、超える場合は
  cache せず specialize する(巨大 variables による key の無制限成長を防ぐ)
- latest median (repeat=3, count=-1):
  - `varying_variables`
    - `houtou_runtime_program`: `55351/s` → `202867/s`(約 `3.7x`)
  - `nested_variable_object`(固定 variables)
    - `houtou_runtime_program`: `210437/s`(横ばい)
    - `houtou_runtime_native_bundle`: `703248/s`(横ばい)
  - `list_of_objects`
    - `houtou_runtime_program`: `249683/s` / `native_bundle`: `619934/s`(横ばい)
- 解釈:
  - 実 Web トラフィック相当(毎回異なる variables)が固定 variables と
    同水準になった
  - runtime directive 使用時の per-variables specialization は維持
    (`t/24` に skip / still-specialize 両方の回帰テストを追加、
    `t/27` の directive 動作も全て通過)

## 2026-07-06 execute_to_json direct-JSON fast lane (Phase C)

- sync fast lane の JSON シンク版を追加した
  - `gql_runtime_vm_execute_block_fast_json(...)` が Perl hash/array を
    materialize せず、出力 SV へ直接 JSON バイト列を書く
  - abstract dispatch は `gql_runtime_vm_select_abstract_child_block_fast(...)`
    として SV 版から分離し、両レーンで共有する
  - envelope は `execute()` と同一(`data` + `errors`(message/path)、
    成功時は `"errors":[]`)
  - response key は query の field 順で出力される(SV 版は Perl hash のため
    順序を保持できない)
  - Boolean 型の leaf は resolver が 0/1 を返しても JSON boolean で出す
  - 出力は UTF-8 octets。async(Promise::XS)resolver は croak
- 公開面:
  - `NativeRuntime->execute_bundle_to_json / execute_program_to_json /
    execute_document_to_json`
  - top-level `execute_to_json($schema, $doc, $vars?)`
- latest median (repeat=3, count=-1, `list_of_objects_json`):
  - `houtou_runtime_native_bundle`(execute + JSON::MaybeXS encode): `438856/s`
  - `houtou_bundle_to_json`: `918729/s`(約 `2.1x`)
  - `houtou_runtime_program` + encode: `220553/s`
  - `houtou_document_to_json`: `485623/s`(約 `2.2x`)
- 解釈:
  - envelope の SV 化を丸ごと省くため、JSON なしの素の execute より速い
  - PSGI アダプタ(ロードマップ第2段)はこの lane を既定にする

## 2026-07-07 L1: DataLoader batching(on_stall フック + 同梱 DataLoader)

- コア公開契約(L1-a):
  - `execute(..., on_stall => sub { ... })` / `NativeRuntime->execute_document(..., on_stall => ...)`
  - resolver が Promise::XS promise を返すと async lane で実行し、
    executor がストール(ready queue 空 + pending 残)するたびに
    `on_stall` を呼ぶ。戻り値は「進捗数」で、pending が残ったまま
    進捗 0 を返すと deadlock を検出して die する
  - `_settle_result` が response promise を run-to-completion で駆動
    (Promise::XS の resolve は同期でコールバックが走るため、
    Perl 側ループでスケジューラが前進する)
- 同梱リファレンス実装(L1-b): `GraphQL::Houtou::DataLoader`
  - `new(batch =>, max_batch_size =>, cache =>, cache_key =>)` /
    `load` / `load_many` / `prime` / `clear` / `dispatch` /
    class method `on_stall_for(@loaders)`
  - 公開フック API のみで実装(XS 非依存)。N+1 が level ごとの
    1 バッチに畳まれることを `t/36` で検証
- async lane の既存バグ 2 件を修正(真の late-resolution で初めて顕在化):
  - `deferred_resolves_response` の判定を `frame_stack_count == 1` から
    exec state の `response_frame` ポインタ比較に変更(late continuation の
    子フレーム単独スタック時に envelope が二重に巻かれる誤り)
  - `complete_current_native_async` OBJECT/ABSTRACT の
    `return_pending_handle` を 1→0(親接続前提のハンドル返却が
    late continuation では親不在のため BlockFrame ハンドルが
    マージ値として漏れる)
- メモリリーク 2 件を修正:
  - `async_scheduler_resolve_frame` が deferred へ resolve した
    `resolved_sv`(response envelope)を decref していなかった
    (リクエストごとに envelope + data 一式を保持。タスク #11 の正体)
  - `expect_error_records_av` が error_records 未指定時に owned な
    `newAV()` を返し、`new_outcome_struct` が借用扱いでリーク
    (エラーなし Outcome 1 個につき空 AV 1 個。async の OBJECT 完了で
    子ブロック分と合わせて 2 個/フィールド)
  - 調査メモ: Perl 側 census(walk_arena)はスナップショット間の
    アリーナ攪乱でアドレス再利用の偽陰性が出る。C 側で SV を確保しない
    アリーナ走査 + 二分 snap が有効だった。`perl Build` はヘッダのみの
    変更では .o を再コンパイルしない(検証時は .o を消すこと)
- soak(修正後): `dataloader` +304KB/12000 iters(~26B/req、修正前 ~750B/req)、
  `async_promise` +48KB/8000(~6B/req、#11 解消)、mixed +128KB/8000
- 既知の未修正バグ(main 由来、別 issue 化):
  - variables あり + resolver が promise を返す + `on_stall` なしの場合、
    fast lane(`execute_native_program_handle_xs`)が promise を検出せず
    data に promise オブジェクトがそのまま入る(OBJECT 型では子ブロックが
    promise を source として実行され `undef` になる)。variables なしは
    auto lane のため正しく promise が返る
- latest median (repeat=3): `abstract_with_fragment` program `234113/s` /
  bundle `660591/s`、`varying_variables` `188543/s`、
  `list_of_objects_json` bundle_to_json `876861/s` / document_to_json
  `475976/s`(いずれも前回チェックポイントと同水準、リグレッションなし)

## 2026-07-07 L2: async response の direct-JSON tail

- `execute_to_json` / `execute_document_to_json` が `on_stall` を受け付け、
  async lane(バッチング resolver)でも JSON バイト列を返せるようになった
  - exec state に `response_json_mode` を追加。response frame の resolve 時に
    `gql_runtime_vm_response_json_from_native_sv(...)` が native value tree を
    直接 JSON 化して deferred に渡す(Perl envelope hash は作らない)
  - native tree walker `native_value_cat_json`(OBJECT/LIST/SCALAR 各 kind、
    NV は sync lane と同じ Gconvert、FALLBACK_SV は `json_cat_scalar` に委譲)
  - auto lane はストールしなかった場合(全 sync 完了)も
    `response_json_from_data_sv`(SV walker)で JSON を返す
  - 公開面: `execute_native_program_auto_to_json_xs`、
    `NativeRuntime::execute_program_to_json` の `on_stall` 分岐
- 出力仕様(sync JSON lane との差、POD に明記):
  - キー順は完了順(sync フィールド先、遅延解決フィールドは解決順)。
    sync lane はクエリ順
  - Boolean 型 leaf は resolver の戻り値のまま(0/1)。native tree に
    GraphQL 型情報がないため。どちらも L3 で収斂予定
  - エラー envelope(message/path)・エスケープ・数値表現は sync lane と共通
    (json_cat_* を共有)
- 計測:
  - dataloader バッチ(20 item list): SV+encode 156k/s → direct 164k/s(+5%)。
    100 item では +1%。async リクエストは loader/promise 機構が支配的で、
    serialization tail の寄与は小さい。大きな伸びは L3(hot path)側
  - soak `dataloader_json` +320KB/12000 iters(~27B/req、SV 版と同水準。
    リークなし)
  - sync lane リグレッションなし(bundle_to_json 899k/s、document_to_json 474k/s)
- t/37_async_to_json.t 追加(6 subtests、計 264 tests)。
  minilla は git 未追跡のテストを実行しないので新規 t/ ファイルは
  `git add` してから `minil test` すること

## 2026-07-08 #28 修正: async ランタイム宣言 + fast lane の promise ガード

- 設計判断: DataLoader/Promise が主経路という運用実態に合わせ、
  ヒューリスティック(初回 croak→自動再実行、mutation の初回失敗)は不採用。
  **`build_native_runtime($schema, async => 1)` の宣言 1 箇所**で
  全リクエストが async lane から開始する(初回の特殊挙動なし)
  - execute: variables の有無に関わらず auto lane。`on_stall` は従来どおり合成
  - to_json: async lane + L2 JSON tail。pre-resolved チェーンは settled
    promise から同期に JSON を取得、真のストールは「pass on_stall」エラー、
    rejection は本来のエラーを伝播(`_auto_json_or_die`)
  - `engine => 'native'` 明示時は async 宣言より優先して strict sync
- ガード: resolver 呼び出し 4 箇所(default/explicit × cb4/cb5、SV/JSON 両
  fast lane 共有)に `gql_runtime_vm_fast_lane_guard_promise_sv`。
  promise が返ったら「build the runtime with async => 1 (or pass on_stall)」
  で即 croak(promise オブジェクトが data に混入しない)。非 ref は SvROK、
  unblessed ref は SvOBJECT で即抜け → ホットパス影響なし
  (varying_variables 192k/s 横ばい、soak +16KB/12000)
- t/39(7 subtests)+ t/35 更新、計 271 tests。
  PSGI アダプタへの `async` パススルーは #31 マージ後に追加予定

## 2026-07-10 R0 / #33 修正: list × promise 項目の silent undef を解消

- 根本原因: async lane の COMPLETE_LIST が promise 検出**前に**子ブロックを
  実行していた(検出対象が item_result で、item_sv ではなかった)。
  promise を source に子ブロックが走り全フィールド undef、エラーも出ない
- 修正(lib/GraphQL/Houtou.xs):
  - COMPLETE_LIST の item ループで `item_sv` を promise 判定し、promise なら
    子ブロック実行を then コールバックに遅延する
    `gql_runtime_vm_new_list_item_child_callback_sv`(state_sv + path_frame +
    child_block_index を magic ctx に保持、resolve 後に
    `execute_block_async_path_sv` を実行)+ 既存 error_callback を
    `call_then_promise_for_state_sv` に接続
  - `xs_list_pending_callback`: `native_list_store_at` の前に Outcome の
    error_records を writer へ push(list 内 per-key rejection が errors に
    届くようになった。従来は silent loss)
  - sync fast lane の list item ループ(`complete_current_list_fast_sv` /
    `complete_current_list_fast_json`)にも
    `gql_runtime_vm_fast_lane_guard_promise_sv` を追加 → promise 項目は
    async => 1 を案内して croak(silent undef の残り経路を閉鎖)
- 経路の整理(テスト設計にも影響):
  - sync ランタイムでも variables/root/context なしの execute(SV)は
    auto lane に乗るため、pre-resolved promise 項目はこの修正で正しく完了する
  - fast SV lane に乗るのは `engine => 'native'` 明示 or variables あり。
    t/39 の新 subtest は `engine => 'native'` で fast lane 経由の croak を検証
  - to_json は sync ランタイムでは常に fast JSON lane → croak
- テスト: t/36 に DataLoader 経由の list-of-promises subtest(全 data +
  1 バッチ + per-key error が errors[0] に載る)、t/39 に fast lane croak ×4 +
  auto lane 完了 subtest。計 273 tests パス
- soak 全シナリオ +800KB/12000 iters(既知残差水準、リークなし)。
  benchmark checkpoint: list_of_objects bundle 601k/s、bundle_to_json 876k/s、
  varying_variables 189k/s(いずれも前回同水準、ガード追加の影響なし)

## 2026-07-10 P1/L3 着手: 計測ゲート + outcome clone 除去(+13%)

- 計測ゲート: `async_preresolved` ケースを execution-benchmark(-checkpoint).pl に
  追加(20件×3フィールド object list、variables あり、native runtime)。モード:
  `houtou_sync_sv/json`(fast lane 参照値)、`houtou_async_sv/json`
  (一括 promise)、`houtou_async_items_sv`(per-item promise)。
  行データはリクエスト毎に生成(共有 SV への POK 汚染で dualvar 比較が
  壊れるため。id/name 補間で POK が付くので qty は `0 + $i` で純 IV に)
- ベースライン median (repeat=5): sync_sv 70.4k / sync_json 68.6k /
  async_sv 19.4k(3.6x)/ async_json 19.3k / async_items_sv 12.8k(5.5x)
- **切り分けの要点**: async ランタイム + 同期 resolver(promise ゼロ)でも
  20.5k vs sync 62.7k で 3x 遅い。promise 1 個の追加コストは −13% のみ。
  → L3 の主犯は Promise::XS 境界(候補1/4)ではなくレーン機構
  (クローン・native⇔SV 往復・frame 生成)。`sample` プロファイルでも
  malloc/free + sv_clear/sv_setsv + hv_common が支配的
- ゲートの sanity チェックが実バグを 2 件検出:
  1. **修正済み**: `new_outcome_struct` の KIND_OBJECT/KIND_LIST 変換が
     1 段 shallow(`new_native_value_scalar`)で、promise-of-list /
     promise-of-object の nested 子ツリーが JSON レーンで
     `"HASH(0x...)"` に文字列化(main でも再現する L2 以来の既存バグ。
     SV レーンは block frame から materialize するため無事)。
     `native_value_from_completed_sv`(plain HV/AV のみ再帰、blessed leaf は
     scalar fallback 維持)で修正。t/37 に回帰テスト
  2. **既知ギャップの露出(P3)**: dualvar(IV+POK)の Int leaf が
     async レーンで `"1"` に quote される。native tree に GraphQL 型情報が
     ないため SvPOKp 優先で PV 格納される。sync fast lane は型情報で数値化。
     P3(native scalar kind)で解消予定
- 最適化 1(候補2の一部): `consume_outcome_native_object` が
  outcome->value を deep clone 直後に破棄していたのを、refcount==1 なら
  subtree を移譲する形に。`consume_current_outcome_now` の
  field_frame->outcome 退避(読者なし、3 行後に解放)も削除し
  sole-owner 化 → async_sv/json 19.4k→22.0k(+13%)、items +7%。
  sync 横ばい、274 tests + soak 全シナリオパス
- **次の実装単位(最大レバー)**: native-first completion(候補3)。
  現状は子ブロックごとに native values→SV materialize→outcome で再 native 化
  の往復があり leaf が 4〜5 回コピーされる。execute_block_async_path が
  native 値を持つ Outcome を直接返し、COMPLETE_OBJECT/LIST が Outcome を
  透過・転送する形へ(COMPLETE_LIST の item 収集と error_records 集約が要注意)。
  その後に frame プール化(候補5)、XSUB プール化(候補1)の順
