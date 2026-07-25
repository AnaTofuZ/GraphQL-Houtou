# GraphQL::Houtou 次期高速化調査

## 1. 目的

現行の GraphQL::Houtou は、GraphQL AST をリクエストごとに走査する構造から、
schema と operation を事前に native program へ lower し、XS VM 上で実行する構造へ
移行している。

本書では、現行アーキテクチャを前提として、次の大幅な高速化に向けた候補を整理する。

- 現時点の主要なボトルネック
- 変数、引数、resolver、response 構築の内部構造
- JIT、AOT、VM specialization の有効性
- async、parser、validation を含む周辺領域
- 現在の設計を維持した場合の性能上限
- 実装前に行うべき計測と実験

結論を先に述べると、次の主要な高速化対象は VM 命令 dispatch の JIT 化ではない。
現状の大きな天井は次の 3 点である。

1. 変数と引数をリクエストごとに Perl の HV/SV へ変換、coerce する処理
2. resolver を Perl callback として field ごとに呼ぶ境界コスト
3. response を Perl の HV/AV として生成するコスト

## 2. 現行アーキテクチャ

現行実装はすでに次の最適化を備えている。

- query parse と validation の結果を再利用する program cache
- schema field と callback catalog の index 化
- operation の block/op/slot 配列への lowering
- runtime と program を融合した native bundle
- 同期 SV、直接 JSON、async の実行レーン分離
- native value、outcome、writer による中間 HashRef の排除
- built-in scalar の C 側 coercion
- path frame の遅延生成
- Promise::XS に特化した async scheduler

このため、単純な「XS 化」「AST を VM にする」「opcode を整数化する」といった
高速化はすでに実施済みである。

固定 native bundle の同期実行は概ね次の経路を通る。

```text
XSUB 入口
  → request state 初期化
  → block/op loop
      → args HV 生成
      → Perl resolver 呼び出し
      → leaf coercion / child block
      → response HV への格納
  → { data => ... } envelope 生成
```

変数付き operation では、その前後に次の処理が追加される。

```text
variables HV
  → variable ごとの存在確認と SV 複製
  → input coercion
  → prepared variables HV
  → field ごとの dynamic argument materialize
  → argument coercion
  → resolver 用 args HV
```

## 3. ベンチマーク

### 3.1 条件

- 計測日: 2026-07-24
- Apple Silicon
- Perl 5.44
- XS: `-O3`
- `util/execution-benchmark-checkpoint.pl`
- 5 標本の中央値
- resolver の戻り値はリクエストごとに生成
- schema、program、bundle は事前コンパイルして再利用

### 3.2 結果

| ワークロード | throughput |
|---|---:|
| 変数付き nested object | 203,829 req/s |
| 同じ operation の固定 native bundle | 705,151 req/s |
| list of objects | 331,918 req/s |
| 同じ query の固定 native bundle | 627,139 req/s |
| abstract + fragment | 336,097 req/s |
| 同じ query の固定 native bundle | 697,805 req/s |
| list → Perl 構造 → JSON encode | 494,696 req/s |
| list → JSON 直接生成 | 931,786 req/s |

重要な差は次の通りである。

- 変数付き program から固定 bundle: 約 3.46 倍
- Perl response から直接 JSON: 約 1.88 倍
- 固定 bundle の各 query shape: 約 62 万〜71 万 req/s に収束

固定 bundle で object、list、abstract が近い範囲に収束していることから、
query shape 固有の VM 命令より、resolver callback、Perl scalar 操作、response
生成などの共通処理が支配的になり始めていると考えられる。

なお、macOS の sampling profiler による C レベルのサンプリングも試行したが、
プロセス起動と module load の期間を多く取得したため、定量的な hotspot の根拠には
採用していない。本書の判断は、反復ベンチマーク、レーン間差分、実装上の allocation
構造に基づく。

## 4. ボトルネック

### 4.1 変数 preparation

`gql_runtime_vm_prepare_program_variables_sv` は、リクエストごとに新しい HV を作り、
variable definition ごとに次を行う。

- provided variables の名前検索
- 入力 SV の複製
- default value の materialize
- GraphQL input coercion
- coerced HV への格納
- operation が宣言していない追加 variable の複製

単純な `ID!` 変数 1 個であっても、固定 bundle には存在しない request-time 処理が
複数発生する。

### 4.2 dynamic argument specialization

変数 preparation の後、各 field の resolver を呼ぶ直前に、dynamic argument が
再び materialize、coerce され、resolver 用の args HV に格納される。

概念的には次の往復が発生する。

```text
入力 SV
  → prepared variables HV
  → native dynamic value の参照
  → argument SV
  → coerced args HV
  → Perl resolver
```

変数付き nested object が固定 bundle の約 29% の throughput に留まることから、
ここは最重要の改善候補である。

### 4.3 Perl resolver callback

明示 resolver では field ごとに次が必要になる。

- Perl stack の準備
- callback arguments の refcount 操作
- `call_sv`
- `G_EVAL` による例外境界
- return SV の取得
- Promise::XS 判定
- completion と result coercion

resolver 本体が定数を返すだけでも、この境界コストは発生する。query の field 数が
増えると、VM dispatch より callback 回数が支配的になる。

### 4.4 response の HV/AV 化

同期 SV レーンは block ごとに `newHV()` し、field ごとに `hv_store()` する。
list ではさらに AV と item ごとの object HV が必要になる。

直接 JSON レーンでは、同じ block/op loop から出力 SV へ JSON bytes を append
するため、中間 response tree の allocation を回避できる。

同じ固定 list query で直接 JSON が約 1.88 倍高速であることから、HTTP response が
最終的に JSON になる用途では HV/AV 化が大きな天井である。

### 4.5 async scheduler

async レーンでは、VM の field completion に加えて次のコストが発生する。

- Promise::XS の生成
- `then` callback の登録
- resolve/reject callback context
- pending entry
- path frame
- ready queue と frame の再構築
- settle 時の refcount 操作

特に「list 全体を返す promise」より「item ごとに 1 promise」の方が大幅に遅くなる。
async の性能は opcode dispatch より promise 数に左右されやすい。

## 5. 優先度 A: 変数・引数パイプラインの刷新

現在の経路を次のように短縮する。

```text
現状:
入力 SV → coerce 済み HV → dynamic native value → args HV → resolver

候補:
入力 SV → typed request slots → resolver adapter
```

operation compile 時に、variable と argument の対応を固定命令列へ lower する。

```text
ARG_COPY_VAR    dst_arg_slot, variable_slot
ARG_CONST       dst_arg_slot, constant_slot
ARG_DEFAULT     dst_arg_slot, default_slot
ARG_COERCE_ID   dst_arg_slot
ARG_REQUIRED    dst_arg_slot
```

request ごとに固定長 slot 配列を生成し、名前による HV lookup、coerced variables HV、
field ごとの argument definition 探索を排除する。

ただし、従来の Perl resolver ABI が `$args` HashRef を要求する限り、callback 直前の
args HV 生成は残る。そのため resolver ABI を次のように分離する。

- compatibility ABI: 従来の HashRef
- typed native ABI: positional slots または opaque `ArgsView`
- no-args ABI: args、info、type を積まない
- common signature ABI: 使用頻度の高い引数数に特化

特に no-args field では、共有 empty HashRef を渡すだけでなく、callback の引数自体を
減らすことを検討する。

## 6. 優先度 A: resolver 境界の削減

### 6.1 宣言的 resolver

resolver を分類し、callback 不要な field を増やす。

- Hash key の取得
- array index の取得
- constant
- root/context slot の取得
- rename
- accessor method
- 単純な文字列結合
- native function

これらを schema compile 時に resolver opcode へ lower する。

```text
LOAD_HASH_KEY      source, interned_key
LOAD_CONTEXT_SLOT  n
LOAD_CONST         n
CALL_PERL_CV       n
CALL_NATIVE_FN     n
```

default resolver の HashRef key lookup はすでに C 側にあるが、アプリケーションが
同じ操作を明示 resolver で包むと Perl callback が必要になる。宣言的 resolver API
を提供すれば、互換性を保ったまま callback 数を減らせる。

### 6.2 native row/view

親 resolver が毎回 HashRef を作り、その子 field が key lookup する構造では、
executor が高速でもアプリケーション側の HashRef allocation が残る。

より高速な契約として、resolver が次を返せるようにする。

- native row
- packed array
- C struct の opaque view
- slot index で値を取得できる row adapter

この場合、child field は名前検索なしで値を読み、直接 JSON writer へ流せる。

## 7. 優先度 A: JSON レーンの強化

HTTP server の最終出力が JSON なら、Perl response tree は中間生成物である。
可能な経路では `execute_*_to_json` を主経路として扱う。

改善候補:

- PSGI 経路を原則直接 JSON へ寄せる
- field name を `"name":` の形まで compile 時に escape
- scalar 型ごとの emitter function を slot に保存
- block ごとの固定 JSON template
- 出力サイズの予測と `SvGROW`
- list item 用 tight loop
- UTF-8 検証済み native string ABI
- error がない場合の envelope fast path

固定 query は最終的に次の形へ近づけられる。

```text
JSON template literal
  → resolver result
  → type-specific scalar append
  → JSON template literal
```

これは machine code を生成せずに JIT に近い specialization を得る方法である。

## 8. JIT の評価

### 8.1 opcode JIT

現行 VM の opcode は resolve family と completion family の直積で、実質 8 種類である。
block/op は連続配列、slot と callback も index 化されている。

そのため、switch や dispatch を機械語化するだけの JIT は効果が限定的と考えられる。
resolver callback、HV/AV 生成、SV refcount が支配的なら、VM dispatch をゼロコストに
しても全体の改善率は小さい。

また、Perl API を呼ぶ JIT code は次を扱う必要がある。

- interpreter context
- SV refcount と mortal
- save stack
- croak/longjmp 安全性
- Perl version ABI
- W^X と platform ごとの実行コード制約
- sanitizer と debugger

実装、保守、移植性のコストに対して、得られる性能が見合わない可能性が高い。

### 8.2 有望な specialization

JIT 的な最適化を行う場合は、VM 全体ではなく固定 program の次の要素に限定する。

1. block/op の直線化
2. resolver ABI と completion family の定数畳み込み
3. field name、slot、child block の即値化
4. error と Non-Null 処理の cold path 分離
5. JSON template emitter の生成

最初は machine-code JIT ではなく、function pointer 列による executable steps が
安全である。

```c
struct compiled_step {
    resolve_fn resolve;
    complete_fn complete;
    emit_fn emit;
    const slot *slot;
};
```

これにより opcode decode と一部の条件分岐を除去しつつ、LLVM や runtime code
generation への依存を避けられる。

### 8.3 AOT query compiler

persisted query をビルド時に C へ変換し、XS bundle へコンパイルする AOT 方式は、
runtime JIT より本プロジェクトと相性がよい可能性がある。

利点:

- C compiler による inline と定数畳み込み
- production で実行時コード生成が不要
- symbolized profile を取得しやすい
- sanitizer を利用できる
- persisted query と自然に統合できる

ただし、field ごとの Perl resolver callback が残る限り改善幅は限定される。
AOT の価値が大きくなるのは、native/declarative resolver ABI と組み合わせた場合である。

## 9. 内部構造の刷新

### 9.1 request arena

request state、error、path、temporary args、native value を arena からまとめて確保し、
request 終了時に一括解放する。

response HV/SV は request 後も生存し得るため arena に置けないが、直接 JSON レーン
では多くの temporary allocation を arena 化できる。

async レーンにある pool と統合し、同期、非同期で共通の request allocator を
持つことも検討できる。

### 9.2 struct-of-arrays

op/slot の大きな struct から hot loop で必要な field のみを分離する。

```text
opcode[]
slot_index[]
child_block[]
result_name_ptr[]
result_name_len[]
resolver_ptr[]
flags[]
```

cache locality の改善余地はあるが、小さい query では効果が限られる可能性がある。
L1 miss、frontend stall、working set を hardware counter で確認してから採用すべきである。

### 9.3 fused executable bundle

bundle 生成時に、各 op へ次を直接接続する。

- resolver CV
- return type object
- leaf serializer
- abstract dispatch table
- pre-escaped JSON key
- specialized argument plan

現在の runtime callback catalog と schema slot index を経由する間接参照を減らし、
op を実行可能な step に近づける。

### 9.4 speculative error-free lane

通常リクエストでは field error がない。それでも通常ループには promise、error、
path、Non-Null 用の分岐が存在する。

compile 時に program traits を解析する。

- custom scalar なし
- runtime directive なし
- abstract fallback なし
- sync-only resolver
- path frame の遅延生成が可能

条件を満たす block は専用の fast loop で実行し、例外時だけ generic completion へ
deopt する方式を検討する。

## 10. parser と validation

persisted query や program cache hit を前提にすれば、parser と validation は定常的な
request hot path ではない。そのため execution 改善より優先度は低い。

ad-hoc query が主要用途の場合の候補:

- parser AST を全面的に Perl HV/AV 化せず operation compiler が直接消費
- parse、validation、lowering の arena 共有
- field/type name の schema-wide interning
- validation selection graph と execution program の同時構築
- location 情報の遅延 materialize
- negative validation cache
- normalized document hash の早期生成

現行 parser は最終的な AST を Perl の HV/AV として公開するため、この allocation が
parser surface を維持する場合の下限になる。

## 11. async レーン

async では JIT より promise 数と callback allocation の削減を優先する。

候補:

- resolver 単位でなく batch/collection 単位の promise を推奨
- already-resolved promise を callback arm 前に unwrap
- Promise::XS との直接的な settle hook
- callback pair、pending entry、path frame の request arena 化
- list pending を item ごとでなく range/bitmap で管理
- 同期で完了する subtree を async frame へ昇格させない
- async JSON でも native value を最後まで維持

async の最終的な天井は Promise::XS の CV、`then`、refcount、scheduler interaction
になる可能性が高い。

## 12. 性能上限

### 12.1 I/O を含む実アプリケーション

DB や network I/O が主要な latency である場合、executor を 2 倍にしても request
latency はほとんど変わらないことがある。

この場合に重要なのは次である。

- DataLoader の batch 率
- resolver 数
- N+1 query
- response size
- allocation と GC/refcount による tail latency

executor の高速化は、単一 request の latency より CPU 密度と同時実行可能数に効く。

### 12.2 in-memory GraphQL

Perl resolver を field ごとに呼ぶ設計を維持する場合、現在の約 60 万〜90 万 req/s は
すでに高い位置にある。

概算の改善余地:

- 局所的な C 最適化: 5〜20%
- fused op、JSON template、arena: 20〜60%
- typed arguments と specialized callback ABI: 変数付きで 1.5〜3 倍
- callback を減らす declarative/native resolver: query shape 次第で 2 倍以上
- 完全 native resolver と AOT JSON emitter: 現行とは別クラス

100 万〜150 万 req/s 程度は現行設計の延長で狙える可能性がある。それ以上を安定して
狙うには「各 field で Perl callback を呼ぶ」という契約自体を変える必要がある。

## 13. 推奨する実験順序

1. field 数、list 長、resolver 種別、args 数、variables 深度を変えた benchmark matrix を作る
2. variable preparation、argument specialization、resolver、completion、emit に C 内計測を入れる
3. typed request slots を試作し、変数付き nested case だけで効果を確認する
4. JSON key の pre-escape と block template を試す
5. fused executable step で VM dispatch 除去の実益を測る
6. native/declarative resolver を 1 種類だけ導入して callback 境界の上限を測る
7. その結果を基に AOT/JIT の採否を決める

最初の成功指標は次が妥当である。

- 変数付き nested object: 約 20 万 req/s から 40 万 req/s 以上
- 固定 bundle の直接 JSON: 約 93 万 req/s から 120 万 req/s 以上

JIT は目的ではなく、計測によって VM dispatch が十分大きな割合を占めると確認できた
場合にのみ採用する。現時点では、変数/引数の typed slots、resolver callback の削減、
JSON template 化の方が高い効果を期待できる。

## 14. 実装チェックポイント: prepared variable の直接利用

2026-07-24 に、typed request slots へ進む前の第一段階として、直接 variable reference
を argument に渡す経路から二度目の input coercion を除去した。

GraphQL の実行モデルでは、variable は variable definition に従う
`CoerceVariableValues` で一度 coerce され、argument はその prepared value を参照する。
従来実装は、prepared variables HV から値を materialize した後、field の argument
definition に対して同じ値をもう一度 coerce していた。

今回の fast path は次の条件に限定している。

- dynamic argument payload の値全体が単一の variable reference
- prepared variables HV に対象 variable が存在する
- prepared value が null ではない

list/input-object literal の一部に variable が含まれる場合は、外側の literal 全体を
argument type に従って coerce する必要があるため従来経路を維持する。

null も従来経路へ戻す。validation を明示的に迂回した実行では、nullable variable を
Non-Null argument へ渡す不正を argument coercion が検出する必要があるためである。

custom scalar の `parse_value` が直接 variable argument で一度だけ呼ばれる回帰テストを
追加した。全 49 test files、470 tests が成功している。

最終確認の 3 標本中央値:

| ワークロード | 変更前 | 変更後 | 改善 |
|---|---:|---:|---:|
| nested variable object | 203,829 req/s | 238,432 req/s | +17.0% |
| fresh variables per request | 196,383 req/s | 231,849 req/s | +18.1% |

先行する 5 標本ではそれぞれ 243,926 req/s、232,943 req/s だった。測定揺れを考慮しても、
二重 coercion の除去には約 17〜20% の改善があり、変数/引数パイプラインが主要な
最適化対象であるという仮説を支持する。

次の段階では、prepared variables HV と名前 lookup 自体を固定長 typed slots へ
置き換え、argument plan から slot index で参照できる構造を検討する。

続く小変更として、provided variables HV が保持している raw SV を variable coercion
へ渡す際の `newSVsv` を除去した。coercion 中は入力 HV が raw SV を所有し続け、
coercion 結果は別の owned SV になるため、入力の複製は不要である。

この変更後の 3 標本中央値は nested variable object が 243,926 req/s、fresh variables
が 236,302 req/s だった。直前の保守的な 3 標本から約 2%、最初の基準からはそれぞれ
約 19.7%、20.3% の改善となった。

### 14.1 Variable preparation と同期実行の融合

次に、variable-invariant program の同期 SV/JSON レーンについて、variable preparation
と実行を 1 回の XSUB 呼び出しへ融合した。

従来経路:

```text
Perl
  → prepare_variables XSUB
  → prepared variables HV を Perl へ返す
  → execute program XSUB
  → sync fast lane
```

新経路:

```text
Perl
  → fused prepare-and-execute XSUB
      → prepared variables HV
      → sync fast lane
```

prepared variables HV は fused XSUB 内の request-local temporary となり、Perl 側へ
一度返して再び XS へ渡す必要がなくなった。runtime directive または
variable-dependent directive guard により program specialization が必要な場合は、
従来経路を維持する。

5 標本中央値:

| ワークロード | 最初の基準 | 融合後 | 改善 |
|---|---:|---:|---:|
| nested variable object | 203,829 req/s | 324,585 req/s | +59.2% |
| fresh variables per request | 196,383 req/s | 307,680 req/s | +56.7% |

直前の raw SV clone 除去後との比較でも、それぞれ約 33.1%、30.2% 改善した。

同期 JSON レーンにも同じ融合入口を追加した。変数を持たない list-of-objects の
`execute_document_to_json` でも、prepared empty HV の Perl 往復が消える。

3 標本中央値:

| ワークロード | 変更前 | 融合後 | 改善 |
|---|---:|---:|---:|
| `execute_document_to_json` | 359,102 req/s | 411,560 req/s | +14.6% |

この結果から、typed slots の前段階として、request hot path を複数の XSUB に分割せず
coercion、argument materialization、execution、emit を単一 native request scope に
維持すること自体が重要であると分かる。

### 14.2 Variable name の compile-time slot binding

native dynamic value が持つ variable name を、native program load 時に
`variable_defs` の index へ bind するようにした。融合同期レーンでは coerce 済み
variable value を同じ順序の request-local slot 配列にも記録し、直接 variable
argument は次のように参照する。

```text
従来: argument payload → variable name → prepared HV の hv_fetch
現在: argument payload → variable index → prepared slots[index]
```

8 variables 以下の一般的な operation では slot 配列を XSUB の C stack 上に置き、
request-time heap allocationを追加しない。8 variables を超える operation と、
descriptor-only/unbound value は従来の名前 lookup へ戻る。

nullable variable が未指定の場合、slot は null pointer のままになる。このケースを
`undef` value として安全に従来の argument coercion へ戻す必要がある。初回の全テストで
この条件が canonical pagination query の crash として検出され、slot pointer と
格納 value の両方を検査する deopt guard を追加した。

5 標本中央値:

| ワークロード | XSUB 融合後 | slot index 導入後 | 改善 |
|---|---:|---:|---:|
| nested variable object | 324,585 req/s | 329,244 req/s | +1.4% |
| fresh variables per request | 307,680 req/s | 310,597 req/s | +0.9% |

1 variable、1 dynamic argument の小さい query では lookup が 1 回しかないため改善は
小さい。複数 field が同じ variable を参照する query では request preparation 1 回に
対して field ごとの名前 lookup を除去できるため、相対効果が大きくなると予想される。

### 14.3 採用しなかった単一 HV lookup

variable preparation は、provided variables に対して `hv_exists` を行った後、同じkeyを
`hv_fetch`している。これを単一の`hv_fetch`へ置き換える実験を行った。

5標本中央値はnested variable objectが327,680 req/s、fresh variablesが
308,163 req/sで、直前の329,244 req/s、310,597 req/sを上回らなかった。差は
0.5〜0.8%で測定ノイズの範囲だが、改善を実証できない変更は採用せずrevertした。

prepared variables HVそのものの遅延化には、次の3要素を同時に導入する必要がある。

- slot valueを所有するrequest-scoped AVまたはarena
- generic resolverが`info->{variable_values}`を要求した時の遅延HV materialize
- nested input literal、runtime directive、unbound descriptorの名前lookup deopt

空HashRefのglobal共有は、resolverによる変更が別requestへ漏れるため採用しない。

### 14.4 Slot-only owner と遅延 compatibility HV

融合同期レーンで、8 variables 以下のoperationはprepared variables HVを一次表現に
使わず、request-scoped AVをslot valueのownerとして使うようにした。

```text
provided variables HV
  → variable coercion
  → request AV owns coerced SVs
  → stack slots[index] borrows each SV
  → direct variable arguments
```

通常のnative resolverと直接variable argumentだけで完走する場合、coerce済みvariables
HashRefは生成されない。次の場合だけ、programのvariable definition、slot values、
provided variablesから従来互換のHashRefを遅延構築する。

- generic resolverがlazy infoを受け取る
- resolverが`info->{variable_values}`をmaterializeする
- input object/list literal内部にvariable referenceがある
- unbound variable valueが名前lookupを必要とする

未宣言のprovided variableも従来どおりcompatibility HVへコピーする。これにより
`info->{variable_values}`の既存契約を維持しつつ、native fast pathではHV allocationを
回避できる。

追加した回帰テスト:

- generic resolverの`variable_values`にcoerce済み値と追加variableが見える
- input object literal内部のvariableがfallback HVから解決される
- missing nullable variable、custom scalar、request errorの既存テスト

5標本中央値:

| ワークロード | slot index導入後 | slot-only owner導入後 | 改善 |
|---|---:|---:|---:|
| nested variable object | 329,244 req/s | 337,313 req/s | +2.5% |
| fresh variables per request | 310,597 req/s | 323,567 req/s | +4.2% |

最初の基準との比較では、それぞれ約65.5%、64.8%の改善となった。

変数を持たない`execute_document_to_json`は410,526 req/sで、直前の411,560 req/sと
同等だった。空HVと空AVのallocation差はこのqueryでは支配的でない。

### 14.5 引数なし resolver の専用 ABI

引数を宣言しない field 向けに、opt-in の
`resolver_mode => 'native_no_args'`を追加した。通常のnative resolverは
`($source, $args, $context, $return_type)`を受け取るが、このABIは
`($source, $context, $return_type)`を受け取る。同期SV、同期JSON、asyncの各レーンで
空args HashRefの取得とcallback stackへのpushを省く。

`util/resolver-abi-benchmark.pl`で、同じcompiled programを従来native ABIと比較した。
2秒測定:

| query幅 | native | native_no_args | 改善 |
|---:|---:|---:|---:|
| 1 field | 800,148 req/s | 827,076 req/s | +3% |
| 10 fields | 333,577 req/s | 372,754 req/s | +12% |
| 25 fields | 162,292 req/s | 186,535 req/s | +15% |

field数に比例してcallback境界の固定費が積み上がるため、幅の広いqueryでは明確に効く。
誤ったABI利用を防ぐため、argumentを宣言したfieldへの指定はruntime graph compile時に
拒否する。

positional argument ABIも候補だが、可変個数のPerl callback stack構築、default値と
argument定義順の固定、descriptor互換性を新たな公開契約として持つ必要がある。
今回のbranchで改善が実証できた引数なしABIとは独立に評価できるため、このPRには
含めず別実験とする。

### 14.6 採用しなかった汎用 positional resolver ABI

別branchで`($source, @argument_values, $context, $return_type)`というopt-in ABIを
試作した。argument値はcompact schema定義の安定順序で渡し、variable、default値、
同期実行まで実装した。

最初の実装は既存args HashRefをpositional値へ展開したため、通常native ABIより
1〜5%遅かった。次にstatic argument payloadを定義順のAVとして一度だけcacheし、
request時にはHashRefを経由せずcallback stackへ積むようにしたが、それでも次の結果に
なった。

| query幅 | nativeとの差 |
|---:|---:|
| 1 field、2 arguments | -1% |
| 10 fields、2 arguments | -2% |
| 25 fields、2 arguments | -3% |

固定4引数のnative callbackに対し、汎用positional ABIはfieldごとにargument定義を走査し、
可変個数のPerl stack entryを積む。その固定費がresolver内のHash lookup削減を上回った。
公開ABIとdescriptor codeを増やす根拠がないため実装はrevertした。

次に試すなら汎用positionalではなく、引数が1個だけのfield専用ABIに限定する。これは
既存native callbackと同じ固定4引数callを使いながら、args HashRefの生成とresolver内の
Hash lookupを同時に除去できる。

### 14.7 1引数専用 resolver ABI

`resolver_mode => 'native_one_arg'`を追加し、argumentを1個だけ宣言するfieldのresolverを
`($source, $value, $context, $return_type)`で呼ぶようにした。汎用positional ABIと違い、
既存native resolverと同じ固定4引数callbackを使う。

static argumentはnative payloadから値を直接cacheする。dynamic argumentはargument
HashRefを生成せず、coerce済みvariable slotを直接参照する。direct variableでない
input literal、default、nullのcoercionも単一値のまま行う。

2秒測定:

| workload | nativeとの差 |
|---|---:|
| 1 field、1 dynamic argument | +3% |
| 10 fields、1 dynamic argument | +18〜19% |
| 25 fields、1 dynamic argument | +25% |
| 1〜25 fields、1 static argument | 0〜+2% |

static argumentでは既存native ABIもcached HashRefを共有するため差は小さい。一方、
dynamic queryではfieldごとのHashRef allocationとHash lookupが消え、同じvariableを
複数fieldが使うほど改善が大きくなる。

### 14.8 ゼロ引数 object accessor

blessed source objectの単純なaccessor向けに、fieldへ
`accessor => 'method_name'`を宣言できるようにした。通常のdefault method resolverは
graphql-perl互換のため`($args, $context, $info)`をmethodへ渡すが、accessor契約は
ゼロ引数methodとしてsource objectだけをinvocantにして呼ぶ。args HashRef、lazy info、
別resolver coderefを生成しない。GraphQL field名とmethod名が異なるrenameにも使える。

2秒測定:

| object field数 | default method比 |
|---:|---:|
| 1 | +10% |
| 10 | +48% |
| 25 | +65% |

object fieldごとにgeneric args/info準備を省けるため、幅が広いほど効果が大きい。
GraphQL argumentsを宣言するfield、context/infoを必要とするmethod、DataLoaderや権限判定を
行うfieldは通常resolverを使う。`accessor`と`resolve`の同時指定はschema compile時に
拒否する。

accessor導入後にもfieldごとの`gv_fetchmethod_autoload`が残っていたため、runtime slotへ
直前のsource stashとmethod GVを1件cacheした。stashが変わるsubclass切替と
`PL_sub_generation`の変更時はmethod resolutionをやり直す。CVそのものではなくGVを
保持することで、同一GV上のmethod再定義も次回callで新しいCVへ追従する。

accessor単体のthroughputは、1 fieldで約1%、10 fieldsで約5%、25 fieldsで約8%
追加改善した。subclass切替と実行中のmethod再定義を回帰テストに含めた。

### 14.9 DataLoader resolver境界

DataLoaderの1 batch requestをloader単体とGraphQL実行全体に分けて測定した。
`dispatch`時のqueue全体`splice`除去、default identity `cache_key` callback除去、
`on_stall_for`の最終empty dispatch round省略をそれぞれ試したが、いずれも改善せず
約1〜2%低下したためrevertした。deferred Promise生成とsettleが支配的で、Perl配列や
小callbackの削減は全体throughputへ反映されない。

一方、GraphQL argumentsを持たないDataLoader resolverをgeneric ABIから
`fast_resolve_no_args`へ変更すると、1 keyで約4%、10 keysで約7%、25 keysで約6%
改善した。list itemごとのargs HashRefとlazy info生成を省けるためである。

pre-resolved Promise workloadでもasync SV laneはsync SV laneの約56%のthroughputだった。
Promise::XSはsettled valueを公開APIから同期取得できないため、executorはpre-resolved
Promiseにも`then` callback、pending entry、scheduler処理を必要とする。これ以上の大幅な
改善にはPromise::XSとの専用連携、またはDataLoaderがexecutorへnative pending handleを
返す内部契約が必要であり、小さなruntime変更とは別のアーキテクチャ課題になる。

### 14.10 DataLoader専用ticketの試作と不採用

通常のWebアプリで多い「variables付きquery + DataLoader + `on_stall`」を次の対象とした。
Houtouの`on_stall`経路はevent loopを駆動する一般的な非同期I/Oではなく、resolverが
返したpending値を記録し、DataLoaderをbatch dispatchしてから同期的に実行を再開する。
このため、DataLoader経路では汎用Promiseを専用pending ticketへ置き換えられるという
仮説を立てた。

最初に、20件のobject list（各3 fields）を同一queryとvariablesで実行し、sync値、
root resolverがpre-resolved Promiseを1個返す場合、list itemごとにpre-resolved
Promiseを返す場合を比較した。

| workload | throughput | sync比 |
|---|---:|---:|
| sync SV | 106,190 req/s | 100% |
| root Promise | 59,582 req/s | 56% |
| 20 item Promises | 27,927 req/s | 26% |

Promise数に応じて差が拡大するため、当初はdeferred/Promise生成と`then`連鎖が最大要因と
考えた。そこで`perf/dataloader-pending-tickets` branchで、DataLoaderの`load()`が
Promise::XSではなく専用ticketを返し、executorがticketをpending値として認識する試作を
行った。cache、prime、load_many、per-key reject、object/list completion、公開`then()`
互換まで接続し、DataLoaderとPromise fallbackのfocused testを通した。

Perl HashRefとclosureで実装した最初のticketは、10 keysのGraphQL実行でmainより約10%
遅かった。Promise::XSがC実装であるのに対し、ticketの生成・subscribe・settleをPerlで
再実装したことが原因だった。次にticketの生成とsettleをXSへ移し、executorから
subscribeする際のPerl method callも省いた。

同じ`util/dataloader-benchmark.pl`をmainと試作branchで比較した結果:

| workload | main Promise::XS | XS ticket | 差 |
|---|---:|---:|---:|
| loader単体、10 keys | 121,963 req/s | 139,634 req/s | +14.5% |
| GraphQL、1 key、fast resolver | 127,296 req/s | 121,963 req/s | -4.2% |
| GraphQL、10 keys、fast resolver | 30,072 req/s | 30,629 req/s | +1.9% |
| GraphQL、25 keys、fast resolver | 13,273 req/s | 13,389 req/s | +0.9% |

ticketはloader単体ではdeferred/Promise生成を減らしたが、GraphQL実行全体では改善が
約1〜2%に縮み、1 keyでは逆に低下した。したがってsync/async差を支配しているのは
Promise object生成そのものではなく、Houtou側のfieldごとのpending entry、resolve/reject
callback、path/outcome保持、ready判定、scheduler enqueue/drain、completion再開である。

一方、ticketを正式採用すると次の契約をPromise::XSと二重に保守する必要がある。

- resolve/reject、複数subscriber、callback例外、chain flattening
- cache、prime、load_manyとper-key error
- object/list/abstract completionとNon-Null伝播
- request cancellation、未解決ticket破棄、XS handleの所有権
- Promise resolverとticket resolverが混在する場合のscheduler semantics

GraphQL全体で約1〜2%という効果では、このメンテナンスコストとリーク・意味論差異の
リスクに見合わない。ticket試作はcommitせず全変更を破棄し、Promise::XSを単一のpending
契約として維持することにした。

次の改善対象はPromise APIの置換ではなくasync scheduler内部とする。具体的には、
DataLoader dispatch中はsettled entryへ値だけを書き込み、Promiseごとにschedulerを
再入させず、dispatch終了後にready frameを一括enqueue/drainする。さらに同一blockの
completionをまとめ、Promiseが返るまでの同期区間をsync fast lane相当にfuseできるかを
別branchで検証する。

### 14.11 scheduler一括drainとsettled Promise取得の検証

DataLoaderの`on_stall`実行中はschedulerのdrainを抑止し、dispatch完了後にready frameを
一括drainする試作を行った。nested loader、error、deadlock、frame leakのfocused testは
通過したが、1/10/25 keysのthroughputはいずれもmainと同等か僅かに低下した。

既存実装は各Promise callbackでentryへ値を書き込むものの、frameの
`pending_unresolved`が0になる最後のsettleまでready queueへ積まず、drain中の再入も
`async_scheduler_draining`で抑止している。したがって「DataLoaderがN promisesをresolve
するとschedulerがN回再入する」という仮説は誤りだった。外側からbatch区間を通知する
APIだけが増え、実行回数を減らさないため試作をrevertした。

Promise::XSのstashにはFuture::AsyncAwait互換名の`AWAIT_IS_READY`と`AWAIT_GET`も見える。
pre-resolved Promiseを同期取得できればpending machineryを省略できると考えたが、
インストール済みPromise::XSでこれらをPromise objectへ直接呼ぶとプロセスがsegfaultした。
Promise::XS::Promiseの文書にも同期取得APIとして記載されておらず、Houtouから利用できる
安全な公開契約ではない。

25 keys DataLoader実行をmacOS `sample`で5秒計測すると、Promise::XS deferred生成そのもの
より、次が上位に現れた。

- `Perl_call_sv`によるresolverおよびpending callback境界
- `gql_runtime_vm_exec_state_execute_current_op_async_sv`
- recursiveな`gql_runtime_vm_exec_state_execute_block_async_path_sv`
- `gql_runtime_vm_async_scheduler_process_frame`
- native valueのmaterialize/destroy/store
- pending callback、frame arm/finalize、leaf serialization

root Promise解決後のobject listでは大半のchild fieldsが同期値なのに、すべてasyncの
frame/outcome/completion経路を通る。Promise生成やdrain回数の局所最適化ではなく、
Promiseが現れないblockまたはblock内の同期区間をfused executionへ載せることが、残る
sync/async差に対する次の主要候補である。

### 14.12 XS await ticketの再検証

Promise::XSの非公開`AWAIT_*`を呼ぶのではなく、Houtou所有のDataLoader ticketに安全な
`AWAIT_IS_READY`と`AWAIT_GET`をXS APIとして実装した。ticketはpending、fulfilled、
rejectedの3状態を持ち、複数subscriberへの通知、callback例外のrejection化、callbackが
返したticketのflatten、公開`then()`からPromise::XSへの互換bridgeを提供する。

最初の版ではticketの生成とsettleだけをXS化し、派生ticketと継続合成をPerlの
`_subscribe`に残した。この版はmainに対してunique keysで約18%、同一pending keyの共有で
約23%遅かった。Promise生成を省いても、fieldごとにPerl method、`eval`、派生ticket、
返り値判定、resolve/reject再配送を追加したためである。

継続合成をXSへ移し、executorのpending entryをarmする共通経路では派生ticketを作らず、
既存のresolve/reject callbackをticketへ直接登録した。10 fieldsのGraphQL実行をmainの
Promise::XS版と比較した結果:

| workload | main Promise::XS | XS ticket | 差 |
|---|---:|---:|---:|
| unique pending keys、fast resolver | 29,094 req/s | 31,150 req/s | +7.1% |
| repeated pending key、fast resolver | 34,673 req/s | 35,725 req/s | +3.0% |
| primed keys、fast resolver | 32,504 req/s | 63,140 req/s | +94.2% |
| loader単体、10 unique keys | 121,963 req/s | 143,712 req/s | +17.8% |

ready ticketはresolver直後に値またはerrorへ展開され、pending entry、callback、schedulerを
作らない。pending ticketもPromise::XSの汎用chainを経由せず、executor callbackへ直接
通知する。これによりpending workloadの退行を解消しつつ、cache hitとprimeで大きな改善を
得た。Promise::XSは一般resolverが返すPromiseとticketの公開`then()`互換bridgeとして残す。

### 14.13 今後のasync高速化候補

Promise::XSの非公開`AWAIT_*`を同期取得APIとして利用する案は、安全な契約ではなく実測でも
成立しなかった。以降はHoutouが所有するTicketとasync scheduler内部を主な対象とし、外部
resolverが返す本当にpendingなPromiseだけをPromise::XS経路へ残す。

優先順位は次の通り。

1. **Ticket settlementとfield completionの直結**
   Ticket subscriberにblock、op、slot、result path、親frameのpending entryを持たせ、
   settle時にschedulerの汎用再開処理を経ずcompletionを実行する。DataLoaderが返すplain
   hash objectでは、settleからnative object格納までを一続きにできる可能性がある。
2. **Ticket subscriberとpending entryの一体化**
   fieldごとに生成するresolve/reject CV、callback context、subscriber pairを専用C structへ
   まとめる。Ticketからpending entryを直接更新し、Perl callback境界と小オブジェクト生成を
   削減する。
3. **Ticket本体のC struct化**
   現在のblessed AVが持つstate、value、subscriber配列を専用C structへ移す。`av_fetch`と
   callback pair用AV/RVを減らせる一方、request cancellation、循環参照、未解決Ticket破棄の
   ownership監査が必要なため独立した変更として扱う。
4. **DataLoader queue/cacheのnative化**
   `load`時のcache lookup、`[key, ticket]`生成、queue push、dispatch時の`splice`と`map`を
   native loader handleへ移す。loader単体への効果は大きい可能性があるが、GraphQL全体では
   batch関数とresolverの比率も併せて測る。
5. **batch単位のscheduler連携**
   Ticket batchのsettlement中は値とready stateだけを更新し、batch末尾で一度だけschedulerへ
   通知する。ただし既存schedulerは最後のpendingが解決するまでframeをenqueueせず、drain再入も
   抑止済みである。単純な一括drain通知は過去に効果がなかったため、subscriber/pending entryの
   一体化と組み合わせてcallback生成や走査自体を削減できる場合にのみ再検証する。
6. **native valueへの直接settlement**
   実行planとselectionが確定しているexecutor内部subscriberに限り、plain hashをPerlの
   completion中間表現へ戻さずnative objectへ変換する。汎用Ticket APIには型やselectionを
   持ち込まず、executor固有の最適化として隔離する。

小さい変更から進める場合は、batch settlementのPerl/XS反復境界を減らした後、
Ticket subscriberからpending entryを直接更新する構造を試す。その実測を基にTicket本体や
DataLoader全体のnative化へ進むか判断する。

### 14.14 pending直結とDataLoader load missの検証

Ticket subscriberからexecutorのpending entryを直接更新し、fieldごとのresolve/reject CVを
省く試作を行った。20 unique keysではGraphQL実行が約3%改善した一方、repeated/primedでは
最大約4%退行し、subscriberのreentrancy対応とownership管理も大幅に増えた。汎用callback
経路を置き換えるだけでは採用基準に届かないため、この試作は破棄した。

次にDataLoaderのcache miss時に行うTicket生成、`[key, ticket]`生成、queue push、cache storeを
一つのXS呼び出しへまとめた。cache hit判定はPerlに残し、既定のidentity `cache_key` callbackも
省略した。20 keysの測定では、`cache => 0`のloader単体が約25%、GraphQL実行が約5--7%改善した。
通常のcache有効・全key missではloader単体が約4%、GraphQL実行が約3%改善し、repeated hitは
概ね同等だった。DataLoader全体をC handle化せず、hotなmiss処理だけを移す小さい変更でも効果が
得られるため、dispatchのnative化は別の変更として評価する。

### 14.15 DataLoader dispatch制御のXS統合

DataLoaderの公開APIとPerl hash構造を維持したまま、`dispatch`内のqueue chunk抽出、key配列生成、
batch callbackの例外捕捉、戻り値検証、Ticket settlementを一つのXS呼び出しへまとめた。
batch callback自体と、callback実行中に次のloadを新しいqueueへ積むstall契約はPerl側のまま
維持している。

20 keysのmain比較ではloader単体がaccess patternにより約4--9%、GraphQL実行が約1--3%
改善した。100 unique keysではloader単体が約5%、GraphQL実行は同等から約1%改善だった。
幅が増えるほどGraphQL executor自体の比率が高くなるため全体効果は薄まるが、例外、per-key
error、`max_batch_size` chunkingを含む既存契約を変えず、すべてのdispatchで通るPerl/XS境界と
一時配列操作を削減できる。

### 14.16 sync-first root-leaf継続へのDataLoader Ticket統合

GraphQL::HoutouはPSGI前提の同期Webアプリであり、Promise::XSとDataLoader Ticketは
実行時間の重畳ではなくDataLoaderバッチ解決のためだけに存在する。したがって
`docs/sync-first-execution-design-ja.md`で進めているroot-leaf継続の次段階は、汎用
Promise::XSサポートより実際の主要トリガーであるDataLoader Ticketを先に統合する方が
優先度が高いと判断した。

`gql_runtime_vm_fast_lane_guard_promise_sv`にDataLoader Ticket認識を追加した。
resolverの戻り値がTicketで、かつ既にfulfilled/rejected状態(`_dispatch_queue`の
バッチ処理やcache hitで既に決着している場合)であれば、suspension channelへ触れずに
その場で値/errorへ展開する。genuinely pending(state 0)のTicketのみ、従来の
Promise::XSと同じsuspend-or-croak経路に合流する。

genuinely pendingなTicketについては、`gql_runtime_vm_try_execute_fast_root_continuation_sv`
から`gql_runtime_vm_call_then_promise_xs_sv`(Perlメソッド`then`経由)ではなく、
`arm_frame`が既に使っている`gql_runtime_vm_subscribe_dataloader_ticket`をTicketへ
直接呼ぶようにした。Promise::XSの`_settle_result`契約(`isa('Promise::XS::Promise')`
判定)を壊さないよう、この分岐でのみ`Promise::XS::deferred()`を合成し、settle
callbackがそれを`resolve`する側効果を持つ(callbackがG_VOID|G_DISCARD呼び出しに
なるTicket subscriberから呼ばれた場合、戻り値そのものは読まれないため)。

続けて、design docの §13 が次段階として明記していたresolve/reject継続ctxの統合を
行った。従来はsuspendのたびに`gql_runtime_vm_fast_root_continuation_ctx_t`を
resolve用・reject用に個別に2回確保していた(それぞれ6個の`newSVsv`を含む)。
`gql_runtime_vm_pending_callback_ctx_t`が既に使っている`cv_refcnt`パターンを移植し、
1回の`Newxz` + 6回の`newSVsv`で済むようにした。resolve/rejectの2つのXSUBは、ctxに
フラグを持たせず、どちらのXSエントリポイント(`..._resolve_callback`/
`..._reject_callback`)でCVが作られたかで区別する。

回帰テストは`t/39_fast_lane_promise_fallback.t`に、単一のnullable root leaf field
がfulfilled Ticket・pending Ticket(on_stall経由)・rejected Ticketをそれぞれ返す
3ケースと、strict syncレーンでpending Ticketが引き続きactionableなcroakになることを
追加した。`t/54_frame_leak_regression.t`には、200回のpending Ticket駆動root-leaf
継続を連続実行してもblock/path frameがリークしないことを確認するstress testを
追加した。全489 testが成功している。

`util/execution-benchmark.pl`の`benchmark_async_preresolved_leaf`にTicket-ready
(loaderを外側で一度だけprimeし、resolverはcache hitのみ行う)とTicket-pending
(on_stall経由)の2バリアントを追加した。5標本中央値:

| ワークロード | throughput | sync比 |
|---|---:|---:|
| sync leaf | 412,967 req/s | 100% |
| async leaf (Promise::XS pre-resolved、既存) | 277,737 req/s | 67.3% |
| async leaf (Ticket ready、新規) | 321,551 req/s | 77.9% |
| async leaf (Ticket pending、on_stall経由、新規) | 139,515 req/s | 33.8% |

Ticket readyはPromise::XS pre-resolvedに対して約+15.8%改善した。これは
Promise::XSの`then()`が既に決着したpromiseに対しても呼び出しごとにderived promise
objectを生成するのに対し、fulfilled Ticketの認識はsuspension channelにもderived
objectにも触れず値を直接返すためである。Ticket pendingは新しい計測対象であり、
before値は存在しない(旧来この形状のroot leafは全て汎用async executorを通っていた)。
on_stallの駆動ループ自体(Perl側`_settle_result`のwhileループ)のコストが支配的で
あるため、sync比は約34%に留まる。

`util/dataloader-benchmark.pl --scenario execution`(root がobject listで今回の
root-leaf継続の対象外)をPhase 1適用前後でstash比較したところ、unique/primed/repeated
のいずれも数%以内の揺らぎに収まり、全resolver呼び出し箇所に追加したTicket判定
(`gql_runtime_vm_sv_is_dataloader_ticket`、stashポインタ比較のみ)による広範な
退行は見られなかった。

次段階は、design docの§13 step 6が指摘する「Promise callback内で再帰的に完了処理を
行う現在のresume方式をready queueへの統合に置き換える」作業であり、これは複数
sibling pending fieldへ対象を広げる前の前提条件として扱う(`_dispatch_queue`が
1つのCループでbatch内の複数Ticketを続けてsettleするため、現在の直接再帰方式は
sibling数に比例したC stack再帰になり得る)。

### 14.17 resume経路のscheduler統合を試作し、性能退行のため延期(Phase 2)

design doc §13 step 6の実施として、settle callback(`gql_runtime_vm_fast_root_continuation_settle_sv`)
がresponseを直接組み立てる代わりに、既存の汎用async executorが使っている
`gql_runtime_vm_block_frame_t` + scheduler(`enqueue_frame`/`drain`/`process_frame`/
`resolve_frame`)へ委譲する試作を行った。settleごとに最小限の`exec_state_handle_t`
(`native_program`と`writer`のみ実質的に使う、他フィールドはゼロのまま既存の
`ExecState::DESTROY`がNULL安全に解放する)と1エントリの`block_frame_t`を確保し、
完了済みの値を`GQL_VM_PENDING_PROMISE_SV`としてpushしてdrainに委ねることで、
汎用実行レーンと完全に同じ完了経路(response envelope組み立てを含む)を通した。

`util/execution-benchmark.pl`の同一シナリオを共有する300件の独立したrootリーフ継続を
1回の`DataLoader->dispatch`で一括settleするstress test(新規、恒久化はしていない)で
正しさを確認し、ASan(hash seed 1/5/12)でもクリーンだった。

性能面では、Ticket readyケース(suspendせず即決着するため元々settle_svを一切通らない)は
無変化だったが、settle_svを実際に通るケースで実測の退行が出た。5標本中央値:

| ワークロード | Phase 1 (直接構築) | Phase 2試作 (scheduler経由) | 差 |
|---|---:|---:|---:|
| async leaf (Promise::XS pre-resolved) | 277,737 req/s | 258,195 req/s | -7.0% |
| async leaf (Ticket pending, on_stall経由) | 139,515 req/s | 135,886 req/s | -2.6% |
| async leaf (Ticket ready) | 321,551 req/s | 326,123 req/s | ±0(settle_svを通らない) |

settleのたびに`exec_state_handle_t`・heap writer・block_frameを確保し、さらに
Perl SV → native_value_t → Perl SVの往復変換を経由するコストが、直接
`hv_store`+`gql_runtime_vm_fast_response_sv`で組み立てる場合に対して測定可能な
オーバーヘッドとして現れた。

この試作の副産物として、`gql_runtime_vm_native_value_t`のscalar表現に
UTF8フラグを保持するフィールドがなく、resolverが返したUnicode文字列がこの
往復変換を経由すると(promise/ticket経由のフィールド全般、rootリーフに限らず)
UTF8フラグが失われるという、既存の汎用async executorに元々存在していた
バグを発見した(`gql_runtime_vm_native_value_t.scalar_pv_is_utf8`を追加し、
constructor/destroy/materialize/cloneの4箇所で一貫して扱うよう修正)。これは
Phase 2の成否とは独立に価値のある修正であり、Phase 2自体は延期したが
このUTF8修正は採用した。

性能退行が「正しさの検証が目的」というPhase 2自身の位置づけに対して無視できない
規模だったため、ユーザーの判断でPhase 2を単独採用せず、Phase 3(複数sibling
pending fieldへの拡張)を実装する段階まで延期することにした。単一fieldの場合は
Phase 1の軽量な直接構築方式を維持し、block_frame_t/scheduler経由のresumeは
実際に複数sibling を扱う必要が生じた時点で導入する。settle_svの実装は
Phase 1cの状態(直接`hv_store`+`gql_runtime_vm_fast_response_sv`)へ戻した。

### 14.18 複数sibling root fieldへの拡張(Phase 3)

design docの§13 step 3/5、および§7の段階移行計画に沿って、rootの selection set が
「nullableなscalar/enum leafが複数個」の場合に対応する fast root continuation の
拡張を実装した(`perf/sync-first-continuation`ブランチ)。

**eligibility guardの緩和**: `block->op_count != 1`の弾きを`op_count >= 1`へ緩和し、
ブロック内の**全op**が既存の単一条件(GENERIC completion、runtime directiveなし、
nullable、child blockなし)を満たすことを要求する。1つでも満たさないopがあれば
block全体を旧executorへfallbackする。

**重要な発見: bundle上のop_indexはnative_program(生の未剪定プログラム)上の
op_indexと常に一致するとは限らない。** `gql_runtime_vm_prepare_cached_bundle_in_place`
は、静的に評価可能な`@skip`/`@include`directive(`has_directives &&
directives_mode_code == GQL_VM_ARGS_STATIC`)を持つopについて、条件がfalseなら
そのopをbundleの`ops[]`配列から削除する。これにより、削除されたopより後ろにある
opは(それ自身がdirectiveを一切持たなくても)bundle上でインデックスがズレる。
fast laneはbundle上のopを列挙する一方、`gql_runtime_vm_exec_state_complete_async_sv`
は`s->native_program->blocks[block_index]->ops[op_index]`という生のprogramを
直接インデックスするため、この2つの空間が食い違うと誤ったopを参照しうる。対策として
eligibility guardに「このblockで`bundle_block->op_count ==
native_program->blocks[block_index].op_count`である」というblock単位のチェックを
追加した(削除は常にop_countを減らす方向にしか働かないため、この一致は「1つも
削除されていない」ことの十分条件になる)。

なお実験的に検証したところ、今回のeligibility(全op が GENERIC completion 限定)の
下では、`gql_runtime_vm_exec_state_complete_async_sv`は実際には`slot`を
`entry->slot_index`という独立したパラメータ経由で参照しており(`op->slot_index`
経由ではない)、かつ完了処理自体は`slot`の返り値型情報のみに依存するため、この
チェックを外してもテストケースでは可視の破損は再現しなかった(候補となる全opが
同じcomplete_code=GENERICを共有するため)。ただし、これは今回の限定的な
eligibilityがたまたま`op`自身のフィールドに依存しないために表面化しないだけで、
将来complete_codeの制限を緩めるような拡張が`op`の内容に依存するようになった場合に
静かな破損を生みかねないため、コストがほぼゼロの防御的チェックとして維持した。

**既存の汎用scheduler機構をそのまま再利用**: suspendしたopは
`gql_runtime_vm_slot_leaf_kind(...)`が`GQL_VM_LEAF_NONE`(組み込みでないcustom
scalar)かどうかで`GQL_VM_PENDING_PROMISE_GENERIC_VALUE_SV`または
`GQL_VM_PENDING_PROMISE_RESOLVED_VALUE_SV`を選び(`gql_runtime_vm_then_complete_current_sv`
の判定をそのまま踏襲)、`gql_runtime_vm_block_frame_push_pending_pvn_with_meta`で
push する。最初のsuspend時にのみ遅延的に`block_frame_t`と実`exec_state_handle_t`
(実entry pointが使うのと同じ構成: `gql_runtime_vm_new_cursor_struct_for_program`
+ `gql_runtime_vm_new_writer_struct` + `gql_runtime_vm_new_exec_state_handle_sv`)を
確保し、ループを継続する。ループ終了後、`data_hv`に溜まった同期解決済みsiblingを
`gql_runtime_vm_native_value_from_sv`で一括変換して`frame->values_value`へ差し込み、
`gql_runtime_vm_block_frame_finalize_sv`(汎用async executor自身のroot frame
finalizeが使っているのと同じ関数)へ委譲する。専用のctx/callback型は新設していない。

**reentrancy上の重要な発見**: `gql_runtime_vm_block_frame_finalize_sv`は、arm前に
`exec_state->async_scheduler_draining = 1`を立ててから`arm_frame`を呼び、arm後に
元へ戻す、という既存のidiomを使っている。これは、arm中にsiblingの1つが
(Promise::XSの`then()`が同期的にcallbackを呼ぶ場合のように)同期的にsettleし、
その結果`pending_unresolved`が0になった際、settleコールバック自身が
`enqueue_frame`+`drain`を呼んで`process_frame`を再入的に実行してしまうと、
`arm_frame`のループが**まだ回っている最中に**`frame->pending_entries`配列が
`process_frame`によって作り直され(古い配列は`Safefree`される)、`arm_frame`が
保持している古いエントリへのポインタがダングリングになる、という重大な
reentrancy事故を防ぐためのものである。もしこのidiomを踏襲せず`arm_frame`を
裸で呼んでいたら、複数siblingが同一バッチで同期settleするケース(Case B:
pre-resolved Promise::XSとpending Ticketの混在)で発生しうる、検出困難な
use-after-free になっていた可能性が高い。既存の汎用executorがすでにこの問題を
解決済みだったため、車輪の再発明を避けてそのまま再利用した。

**検証**: 正しさは以下のシナリオで手動・自動双方で確認した — 複数siblingが同一
DataLoaderバッチでpending → 一括settle、rejectしたsiblingが他の健全なsiblingを
巻き込まないこと、pre-resolved Promise::XSとpending Ticketの混在(arm中の同期
settleを経由する経路)、50件の独立したrequestが1回のbatch dispatchで settle、
non-null/runtime directive/静的prune各条件でのfallback。全492テスト、49ファイル
個別実行でのASan(複数hash seed)がクリーン。全同期の場合(async runtimeでも
全fieldが同期解決)はsync runtimeと完全に同速(実測差ゼロ)であり、「全同期なら
一切課税しない」というsync-first原則は維持されている。

**性能**: `benchmark_async_multi_leaf`(width 2/5/10、末尾1個がDataLoader
Ticket pending)で、Phase 3導入前(常に旧executorへfallback)と導入後を
git stash比較したところ、**測定可能な改善は見られなかった**(width 2:
122.5k→124.3k req/s、width 5: 100.0k→100.0k req/s、width 10: 78.2k→75.2k req/s、
いずれも誤差範囲)。分析の結果、新経路は「suspendしていないsiblingをfast lane
で安く解決する」利点がある一方、promotion時に`data_hv`全体を
`gql_runtime_vm_native_value_from_sv`で一括変換するコストが新たに発生し、
両者がほぼ相殺していると考えられる。exec_state_handle_t/writer/frame/arm/drainの
固定コストは旧経路と共通(`gql_runtime_vm_block_frame_finalize_sv`を再利用して
いるため)であり、これが支配的である可能性が高い。

Phase 2の「退行」とは異なり「退行はないが改善もない」結果だったが、ユーザーの
判断で正しさ・将来の最適化の土台としての価値を優先し、そのまま採用することにした。
次に性能改善を狙うなら、`data_hv`を経由したPerl SVの一括変換を避け、fast lane
ループ中に解決済みsiblingを直接`native_value_t`へ書き込む設計へ作り直す必要が
ある(promotionが起きるまでは何も確保しないというsync-first原則を保ったまま、
promotion後のperl SV往復自体をなくす設計が要る)。

### 14.19 data_hv往復の除去(§14.18の宿題を実施)

§14.18末尾で指摘した最適化を実装した。`gql_runtime_vm_execute_root_block_fast_multi_sv`
の返り値を`SV *`(RVラップされた`data_hv`)から`void`へ変更し、呼び出し側が
`Newxz`した`block->op_count`要素の`SV **resolved_values`配列へ、op位置をindexとして
解決済みの値を直接書き込む方式にした(suspendしたop・`should_execute_current_op_fast`
でskipされたopはNULLのまま)。data_hvの構築は呼び出し側(`gql_runtime_vm_try_execute_fast_root_continuation_sv`)
がこの配列を見て初めて行う:

- `frame == NULL`(全同期): `resolved_values[]`から`data_hv`を構築し、従来通り
  `gql_runtime_vm_fast_response_sv`へ渡す。1 hv_store/fieldという回数は変わらず、
  単に「ループ中に都度」から「ループ後に一括」へタイミングが変わっただけなので、
  全同期ケースのコストは変化しない(sync-first原則を維持)。
- `frame != NULL`(1つ以上promotion): `data_hv`を一切経由せず、`resolved_values[]`
  から直接`gql_runtime_vm_native_object_store(frame->values_value, slot->result_name,
  /*borrowed=*/1, gql_runtime_vm_new_native_value_scalar(...))`を呼ぶ。

従来の`gql_runtime_vm_native_value_from_sv(data_rv)`(HVの汎用変換)は、
`hv_iterinit`/`hv_iternext`によるtraversalに加えて、`gql_runtime_vm_native_object_store`
呼び出し時に`name_borrowed=0`を渡すため**フィールド名を再度savepvでコピーしていた**
(元々`hv_store`で1回コピー済みの名前を、変換時にもう1回コピーする二重コピーになって
いた)。今回の変更では、fast lane側がすでに知っている`slot->result_name`(plan所有の
borrowed文字列)をそのまま`borrowed=1`で渡すため、このコピーが完全になくなる。

5標本中央値(`benchmark_async_multi_leaf`、旧来のfallback、すなわちPhase 3導入前の
基準との比較):

| width | 旧executor(fallback) | Phase 3(§14.18時点) | 今回(data_hv除去後) |
|---|---:|---:|---:|
| 2 | 122,528 req/s (100%) | 124,254 req/s (101.4%) | 121,963 req/s (99.5%) |
| 5 | 100,014 req/s (100%) | 100,019 req/s (100.0%) | 102,128 req/s (102.1%) |
| 10 | 78,196 req/s (100%) | 75,156 req/s (95.9%) | 79,481 req/s (101.6%) |

width 5・10では旧fallbackに対して初めて明確な(誤差を超えた)改善が確認できた。
widthが大きいほど改善幅が伸びる(width 2はほぼ横ばい、10で+1.6pt)のは、削減した
コストがフィールド数に比例するfixed costだからで、想定通りの傾向である。width 2では
`Newxz`/`Safefree`した配列自体の確保コストが、削減できたコピー1回分の利益とほぼ
相殺していると見られる。

正しさは既存の全492テストに加え、unicode文字列siblingがUTF8フラグを保持したまま
この新しい直接経路を通ることを確認する手動検証、500回のpromotionあり実行+500回の
全同期実行を混ぜたリーク検証、49ファイル個別実行でのASan(複数hash seed)で
確認した。
