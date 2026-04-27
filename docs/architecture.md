# GraphQL::Houtou Architecture

この文書は、現在の `GraphQL::Houtou` の実装を

- 何を目指しているのか
- どの層が何を所有しているのか
- データがどのように流れるのか
- どこが hot path で、どこが cold path なのか

という観点でまとめたものです。

短い入口は `docs/runtime-mainline-overview.md`、最新の checkpoint と計測結果は
`docs/current-context.md` を参照してください。

## 目的

このリポジトリの現在の mainline は、旧 `execution` / `compiled_ir` 実装を延命することではありません。
目的は次です。

- Perl から使いやすい公開 API を維持する
- 実行の主系を compile + VM + native bundle に置く
- hot path で Perl の `HV/AV/SV` を内部通貨にしない
- schema と query を段階的に lower し、実行計画をキャッシュできる形にする
- Pure Perl fallback を本命にせず、native mainline を主戦場にする

要するに、

> Perl のライブラリとして見えるが、内部では compile 済み artifact を VM / native runtime で実行する

という構成を取っています。

## 設計原則

### 1. キャッシュするのは resolver の結果ではなく実行計画

resolver の戻り値は request ごと、object ごとに変わるので、一般にはよい cache 対象ではありません。
本当に cache したいのは次です。

- schema metadata
- field / type metadata
- abstract dispatch metadata
- operation lowering 結果
- VM program
- native bundle

つまり cache すべきなのは

- 何を返したか

ではなく、

- どう実行するか

です。

### 2. kind を先に決め、payload は遅延 materialize する

hot path ではまず

- field family
- completion family
- outcome kind
- promise か否か

を決めます。payload の Perl object 化は必要になるまで遅らせます。

これは tokenizer 最適化でいう

- token kind を先に決める
- token value の materialize を遅らせる

のと同じ発想です。

### 3. Perl object を hot path の内部通貨にしない

hot path の helper 同士が `{ data => ..., errors => ... }` のような Perl envelope を受け渡す設計は取りません。
代わりに次の runtime object を内部通貨として使います。

- `ExecState`
- `Cursor`
- `BlockFrame`
- `FieldFrame`
- `Outcome`
- `Writer`
- `VMProgram`
- `VMBlock`
- `VMOp`

この文書でいう **内部通貨** とは、hot path の helper 同士が受け渡す主表現のことです。
理想的な内部通貨は small / kind-first / state-first であり、response 直前まで Perl の response shape に戻さないものです。

### 4. Pure Perl は bring-up / fallback であり、本命は native bundle

Pure Perl の VM 実装は

- correctness の確認
- lowering の確認
- feature bring-up
- native 側に未実装の cold path

のためにあります。

しかし性能の本命は `NativeRuntime` と `src/vm_runtime.h` の組です。
最適化の主対象もこちらです。

## 全体構成

アーキテクチャは大きく 6 層です。

### 1. Public API

主なモジュール:

- `GraphQL::Houtou`
- `GraphQL::Houtou::Schema`
- `GraphQL::Houtou::Native`

責務:

- XS bundle bootstrap の唯一の owner
- schema compile / execute / native execute の公開入口
- user-facing API の安定面

ここでは API を提供しますが、実行そのものは持ちません。

### 2. Schema Runtime Graph

主なモジュール:

- `Runtime::SchemaGraph`
- `Runtime::SchemaBlock`
- `Runtime::Slot`

責務:

- schema object を immutable graph に lower
- field / abstract dispatch / slot metadata を固定
- root block と schema-side block 群を所有

これは boot-time compile の中心です。

### 3. Operation Lowering

主なモジュール:

- `Runtime::OperationCompiler`

責務:

- query document を schema-aware な lowered program に変換
- args / variables / directives / fragments を実行しやすい shape にする
- child block, completion family, dispatch family を固定する

### 4. VM Lowering

主なモジュール:

- `Runtime::VMCompiler`
- `Runtime::VMProgram`
- `Runtime::VMBlock`
- `Runtime::VMOp`
- `Runtime::VMDispatch`

責務:

- lowered program を `program -> block -> op` へ下げる
- dispatch family を bind する
- dump/load 可能な descriptor 境界を持つ

ここで VM artifact ができます。

### 5. VM Execution

主なモジュール:

- `Runtime::ExecState`
- `Runtime::Cursor`
- `Runtime::BlockFrame`
- `Runtime::FieldFrame`
- `Runtime::Outcome`
- `Runtime::Writer`
- `Runtime::LazyInfo`
- `Runtime::PathFrame`
- `Runtime::ErrorRecord`

責務:

- VM state machine を実行する
- current block / current op / field lifecycle を所有する
- outcome を kind-first に運ぶ
- response materialization を `Writer` に集中させる

### 6. Native Boundary

主なモジュール / ファイル:

- `Runtime::NativeRuntime`
- `GraphQL::Houtou::Native`
- `src/vm_runtime.h`

責務:

- request-time specialization
- native runtime handle / native bundle handle の所有
- compact descriptor の構築と native 実行の橋渡し

ここが本命の高性能経路です。

## 実行の流れ

通常の流れは次の通りです。

1. `Schema` から `SchemaGraph` を構築
2. document を `OperationCompiler` で lowered program にする
3. `VMCompiler` で `VMProgram` にする
4. `ExecState` が `program -> block -> op` を回す
5. `Writer` が最終 response を作る

native mainline では 3 の後にさらに

6. `NativeRuntime` が compact descriptor / native bundle を作る
7. `vm_runtime.h` の executor が XS/native 側で block/op を回す

という流れになります。

## なぜこの構成なのか

過去の試行錯誤で分かったことは次です。

- `resolve_type` 周辺の micro-opt だけでは大勝ちしない
- helper 境界を細かく増やすだけでは branch / call overhead が増える
- `completed { data, errors }` を内部通貨にすると object allocation が重い
- object/list/abstract の family ごとに ownership を持たせると改善しやすい
- 真に効くのは、Perl object を hot path から遠ざけること

そのため現在は

- corridor widening より
- internal currency の軽量化
- family-owned contract
- table-driven / bound dispatch
- native bundle 実行

を優先しています。

## Public API と内部実装の境界

このリポジトリでは、公開 API の Perl らしさは残しますが、内部では互換のための複雑な層を維持しません。

たとえば:

- parser compatibility は要件から外した
- PP fallback は主要求ではない
- 旧 execution mainline は active tree から削除した
- 旧テストは `legacy-tests/` に退避した

つまり、公開面は残すが、内部は mainline のために作り直す、という立場です。

## parser の位置づけ

parser は runtime mainline ではありません。

現在の parser まわりは

- `parse`
- `parse_with_options`

という最小 public surface を持ちつつ、内部では

- `parser_ast_runtime`
- `parser_ir_runtime`
- `parser_graphqlperl_runtime`
- `parser_shared_ast`

のような parser-internal helper に閉じています。

これは runtime/VM の本命とは切り離して扱う、という意味です。

## いまの本命

現在の性能評価では、

- `houtou_runtime_cached_perl`
  は correctness / fallback 寄り
- `houtou_runtime_native_bundle`
  が本命

です。

したがって今後の最適化主戦場は:

- `NativeRuntime`
- compact descriptor
- `vm_runtime.h`
- native outcome / writer ownership

です。

## 今後の方向

今後の大きい方向は次です。

1. native bundle / compact descriptor の最適化
2. `NativeRuntime` と `vm_runtime.h` の境界のさらなる縮小
3. VM executor の native ownership 強化
4. public API は維持しつつ、内部の不要層をさらに削る

要するに、いまの `GraphQL::Houtou` は

> 高速な GraphQL 実行器を中心に据えた compile + VM + native runtime のライブラリ

として整理されています。
