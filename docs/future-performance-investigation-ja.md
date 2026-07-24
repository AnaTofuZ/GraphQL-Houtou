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
