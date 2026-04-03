# Parser Performance

## Benchmark

2026-04-03 時点で、`blib` を優先したローカル build を使って
`util/parser-benchmark.pl` を実行した。

実行例:

```sh
env PERL5LIB=... perl util/parser-benchmark.pl --count=-3
env PERL5LIB=... perl util/parser-benchmark.pl --file=t/schema-kitchen-sink.graphql --count=-3
```

### `t/kitchen-sink.graphql`

```text
                     Rate graphql_js_pegex graphql_perl_pegex graphql_js_xs graphql_perl_xs
graphql_js_pegex    423/s               --               -16%          -81%            -94%
graphql_perl_pegex  501/s              18%                 --          -77%            -93%
graphql_js_xs      2227/s             426%               344%            --            -71%
graphql_perl_xs    7680/s            1715%              1432%          245%              --
```

`no_location` を付けた追加比較:

```text
                         Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_js_xs graphql_js_xs_noloc graphql_perl_xs
graphql_js_pegex        425/s               --                    -5%               -16%          -80%                -86%            -94%
graphql_js_pegex_noloc  447/s               5%                     --               -11%          -79%                -86%            -94%
graphql_perl_pegex      504/s              18%                    13%                 --          -76%                -84%            -93%
graphql_js_xs          2129/s             400%                   376%               323%            --                -32%            -70%
graphql_js_xs_noloc    3110/s             631%                   595%               517%           46%                  --            -56%
graphql_perl_xs        7029/s            1552%                  1471%              1295%          230%                126%              --
```

### `t/schema-kitchen-sink.graphql`

```text
                     Rate graphql_js_pegex graphql_perl_pegex graphql_js_xs graphql_perl_xs
graphql_js_pegex    172/s               --               -16%          -81%            -93%
graphql_perl_pegex  205/s              19%                 --          -77%            -92%
graphql_js_xs       893/s             420%               336%            --            -65%
graphql_perl_xs    2538/s            1378%              1140%          184%              --
```

`no_location` を付けた追加比較:

```text
                         Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_js_xs graphql_js_xs_noloc graphql_perl_xs
graphql_js_pegex        171/s               --                    -8%               -16%          -81%                -89%            -93%
graphql_js_pegex_noloc  185/s               9%                     --                -9%          -80%                -88%            -93%
graphql_perl_pegex      204/s              20%                    10%                 --          -78%                -86%            -92%
graphql_js_xs           913/s             435%                   392%               347%            --                -40%            -65%
graphql_js_xs_noloc    1510/s             785%                   714%               640%           65%                  --            -42%
graphql_perl_xs        2599/s            1424%                  1302%              1173%          185%                 72%              --
```

## Notes

`graphql-js + xs` が `graphql-perl + xs` より遅い主因は、XS parse 後に Perl 側で
graphql-js AST へ変換し、その後 `tokenize_xs()` を使って `loc` を再構築している点にある。

`no_location` 比較では `graphql-js + xs` が次の程度改善した。

- `t/kitchen-sink.graphql`: `2129/s` -> `3110/s` で約 `1.46x`
- `t/schema-kitchen-sink.graphql`: `913/s` -> `1510/s` で約 `1.65x`

このため、現時点では `graphql-js + xs` の主要コストの一つは `loc` 再構築だと見てよい。
一方で `no_location` でも `graphql-perl + xs` よりは遅いため、AST 変換そのもののコストもまだ支配的に残っている。

2026-04-03 の後続作業で、executable document については `loc` 適用の一部を
Perl locator から XS helper へ移した。
この変更後の `t/kitchen-sink.graphql` では `graphql_js_xs` が `4165/s` まで改善し、
以前の `2129/s` から約 `1.96x` になった。

```text
                         Rate graphql_js_pegex_noloc graphql_js_pegex graphql_perl_pegex graphql_js_xs_noloc graphql_js_xs graphql_perl_xs
graphql_js_pegex_noloc  439/s                     --              -4%               -11%                -86%          -89%            -94%
graphql_js_pegex        459/s                     5%               --                -6%                -85%          -89%            -94%
graphql_perl_pegex      490/s                    12%               7%                 --                -84%          -88%            -94%
graphql_js_xs_noloc    3074/s                   601%             570%               527%                  --          -26%            -60%
graphql_js_xs          4165/s                   849%             808%               749%                 35%            --            -45%
graphql_perl_xs        7609/s                  1634%            1559%              1452%                148%           83%              --
```

この時点では、少なくとも executable path については `loc` 自体よりも、
`no_location` 用の recursive strip や AST 変換コストのほうが重くなり始めている。

同じタイミングで `graphql-perl` を graphql-js 正準経路から組み立てる
`canonical-xs` も比較した。

```text
                            Rate graphql_js_pegex_noloc graphql_js_pegex graphql_perl_pegex graphql_perl_canonical_xs graphql_js_xs_noloc graphql_js_xs graphql_perl_xs
graphql_js_pegex_noloc     440/s                     --              -6%               -13%                      -83%                -86%          -90%            -94%
graphql_js_pegex           468/s                     6%               --                -8%                      -81%                -85%          -90%            -94%
graphql_perl_pegex         509/s                    16%               9%                 --                      -80%                -84%          -89%            -93%
graphql_perl_canonical_xs 2519/s                   472%             438%               395%                        --                -20%          -44%            -67%
graphql_js_xs_noloc       3159/s                   618%             575%               521%                       25%                  --          -30%            -58%
graphql_js_xs             4485/s                   919%             858%               782%                       78%                 42%            --            -41%
graphql_perl_xs           7548/s                  1615%            1513%              1384%                      200%                139%           68%              --
```

`graphql_perl_canonical_xs` は `graphql_perl_pegex` より大幅に速いが、
まだ `graphql_perl_xs` には届かない。これは graphql-js AST から graphql-perl AST へ戻す
adapter コストがまだ大きいことを示している。

さらに後続の最適化として、`graphql-js + xs` の executable path では
Perl 側で一度 `loc` を大量生成してから XS helper で付け直す無駄を削った。
具体的には、XS executable loc helper を使う経路では初期の location projection を
Perl adapter で省略するようにした。

この変更後の `t/kitchen-sink.graphql` は次の通り。

```text
                            Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_perl_canonical_xs graphql_js_xs graphql_perl_xs graphql_js_xs_noloc
graphql_js_pegex           452/s               --                    -3%                -9%                      -83%          -91%            -93%                -94%
graphql_js_pegex_noloc     466/s               3%                     --                -6%                      -82%          -91%            -93%                -93%
graphql_perl_pegex         494/s               9%                     6%                 --                      -81%          -90%            -93%                -93%
graphql_perl_canonical_xs 2627/s             482%                   463%               432%                        --          -47%            -62%                -63%
graphql_js_xs             4964/s             999%                   964%               905%                       89%            --            -28%                -31%
graphql_perl_xs           6905/s            1429%                  1381%              1299%                      163%           39%              --                 -4%
graphql_js_xs_noloc       7164/s            1486%                  1436%              1351%                      173%           44%              4%                  --
```

`graphql_js_xs` は `4485/s` から `4964/s` へ改善した。
`graphql_js_xs_noloc` は `3159/s` から `7164/s` へ改善しており、
`no_location` 時はほぼ `graphql_perl_xs` に並ぶ。

この結果から、現時点で `graphql-js + xs` の残る主要コストは

- legacy AST から graphql-js AST への変換
- variable directive / extension patch

であり、`no_location` 経路に限れば location projection コストはほぼ解消できたと見てよい。

さらに後続作業で、executable document は Perl fallback converter を経由せず
`graphqljs_build_executable_document_xs()` で直接 graphql-js AST を組み立てるようにした。
当初は object value を含む executable を安全のため Perl adapter に fallback していたが、
empty object / non-empty object の双方を XS builder 側で扱えるようにしたことで、
現在は executable document 全体で XS builder を使っている。

この変更後の `t/kitchen-sink.graphql` は次の通り。

```text
                             Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_perl_canonical_xs graphql_perl_xs graphql_js_xs graphql_js_xs_noloc
graphql_js_pegex            446/s               --                    -4%                -8%                      -87%            -94%          -95%                -97%
graphql_js_pegex_noloc      462/s               4%                     --                -4%                      -87%            -94%          -95%                -97%
graphql_perl_pegex          483/s               8%                     4%                 --                      -86%            -94%          -94%                -97%
graphql_perl_canonical_xs  3516/s             689%                   661%               629%                        --            -55%          -59%                -80%
graphql_perl_xs            7853/s            1662%                  1599%              1527%                      123%              --           -9%                -55%
graphql_js_xs              8616/s            1834%                  1764%              1685%                      145%             10%            --                -51%
graphql_js_xs_noloc       17440/s            3814%                  3673%              3514%                      396%            122%          102%                  --
```

`graphql_js_xs` は `8616/s` まで伸びて、`graphql_perl_xs` (`7853/s`) を上回った。
この時点で executable path の主コストは、graphql-js AST 自体の構築ではなく、
`graphql-perl` dialect に戻す `graphql_perl_canonical_xs` 側の adapter に移っている。

さらに後続作業で、`graphql-js` canonical document から `graphql-perl` legacy AST への
executable 変換も `graphqlperl_build_executable_document_xs()` として XS 化した。
これにより `graphql_perl_canonical_xs` は `3516/s` から `3742/s` まで改善した。

同時点の `t/kitchen-sink.graphql` は次の通り。

```text
                             Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_perl_canonical_xs graphql_perl_xs graphql_js_xs graphql_js_xs_noloc
graphql_js_pegex            436/s               --                    -5%                -8%                      -88%            -94%          -94%                -97%
graphql_js_pegex_noloc      458/s               5%                     --                -3%                      -88%            -94%          -94%                -97%
graphql_perl_pegex          474/s               9%                     3%                 --                      -87%            -93%          -94%                -97%
graphql_perl_canonical_xs  3742/s             758%                   717%               690%                        --            -48%          -50%                -77%
graphql_perl_xs            7242/s            1561%                  1481%              1429%                       94%              --           -3%                -56%
graphql_js_xs              7453/s            1609%                  1528%              1474%                       99%              3%            --                -54%
graphql_js_xs_noloc       16333/s            3646%                  3467%              3349%                      336%            126%          119%                  --
```

改善幅が比較的小さいのは、`graphql_perl_canonical_xs` の残コストが
executable 変換そのものよりも、legacy 互換チェックと SDL / 非 executable fallback 側へ
寄ってきているためである。

## Profile

`util/profile-parser.pl` を `Devel::NYTProf` 付きで実行し、
`graphql-perl + pegex` と `graphql-perl + xs` の profile を取得した。

対象:

- dialect: `graphql-perl`
- backend: `pegex`, `xs`
- file: `t/kitchen-sink.graphql`
- iterations: `300`

出力:

- raw profile
  - `/tmp/graphql-houtou-nytprof-pegex.out`
  - `/tmp/graphql-houtou-nytprof-xs.out`
- HTML / flame graph
  - `/tmp/graphql-houtou-nytprof-pegex/index.html`
  - `/tmp/graphql-houtou-nytprof-pegex/all_stacks_by_time.svg`
  - `/tmp/graphql-houtou-nytprof-xs/index.html`
  - `/tmp/graphql-houtou-nytprof-xs/all_stacks_by_time.svg`

補足:

- pegex 側の `nytprofhtml` 実行では `nytprofcalls` から deep recursion warning が大量に出るが、
  HTML と SVG は生成できている。
- `graphql-js + xs` / `graphql-js + pegex` の benchmark は取り終えているが、
  NYTProf はまだ `graphql-perl` backend 比較を優先している。


2026-04-03 の後続作業として、executable document については Perl fallback converter
を経由しない XS builder `graphqljs_build_executable_document_xs()` を導入した。
ただし現段階では object value を含む executable は Canonical 側で安全に Perl adapter へ
fallback するため、`kitchen-sink` のような入力では builder が部分適用に留まる。

この状態での `t/kitchen-sink.graphql` は次の通り。

```text
                            Rate graphql_js_pegex graphql_js_pegex_noloc graphql_perl_pegex graphql_perl_canonical_xs graphql_js_xs graphql_js_xs_noloc graphql_perl_xs
graphql_js_pegex           418/s               --                    -4%               -10%                      -81%          -89%                -93%            -94%
graphql_js_pegex_noloc     436/s               4%                     --                -6%                      -80%          -88%                -93%            -94%
graphql_perl_pegex         465/s              11%                     7%                 --                      -79%          -87%                -92%            -94%
graphql_perl_canonical_xs 2228/s             433%                   411%               379%                        --          -39%                -63%            -70%
graphql_js_xs             3670/s             779%                   742%               689%                       65%            --                -39%            -51%
graphql_js_xs_noloc       5992/s            1335%                  1274%              1189%                      169%           63%                  --            -20%
graphql_perl_xs           7494/s            1694%                  1619%              1512%                      236%          104%                 25%              --
```

この時点では `graphql_js_xs` の最適化余地はまだ大きく、特に object value を含む value 変換を
XS builder 側で完結させて fallback 条件を縮めるのが次の主要課題になる。

## 2026-04-03 Current XS-only Snapshot

`graphql-js` parser を XS 専用経路に寄せた現時点では、
`util/parser-benchmark.pl` から `graphql-js + pegex` 系の比較軸を外した。

対象:

- file: `t/kitchen-sink.graphql`
- command: `perl util/parser-benchmark.pl --count=-5`

結果:

```text
                             Rate graphql_perl_pegex graphql_perl_canonical_xs graphql_js_xs graphql_js_xs_noloc graphql_perl_xs
graphql_perl_pegex          475/s                 --                      -93%          -94%                -97%            -99%
graphql_perl_canonical_xs  6818/s              1335%                        --          -18%                -60%            -82%
graphql_js_xs              8314/s              1650%                       22%            --                -51%            -79%
graphql_js_xs_noloc       17026/s              3484%                      150%          105%                  --            -56%
graphql_perl_xs           38802/s              8069%                      469%          367%                128%              --
```

観察:

- `graphql-js + xs` は `graphql-perl canonical-xs` を約 22% 上回る。
- `graphql-js + xs + no_location` は `17026/s` で、location 再構築コストの大きさが引き続き見える。
- `graphql-perl + xs` は依然として最速で、legacy AST を直接返す経路の強さが明確である。

同時点の `NYTProf` は `graphql-js + xs` を含めて取り直した。

対象:

- dialect/backend:
  - `graphql-perl + pegex`
  - `graphql-perl + xs`
  - `graphql-perl + canonical-xs`
  - `graphql-js + xs`
- file: `t/kitchen-sink.graphql`
- iterations: `300`

出力:

- raw profile
  - `/tmp/graphql-houtou-nytprof-pegex.out`
  - `/tmp/graphql-houtou-nytprof-xs.out`
  - `/tmp/graphql-houtou-nytprof-canonical-xs.out`
  - `/tmp/graphql-houtou-nytprof-graphql-js-xs.out`
- HTML / flame graph
  - `/tmp/graphql-houtou-nytprof-pegex/index.html`
  - `/tmp/graphql-houtou-nytprof-pegex/all_stacks_by_time.svg`
  - `/tmp/graphql-houtou-nytprof-xs/index.html`
  - `/tmp/graphql-houtou-nytprof-xs/all_stacks_by_time.svg`
  - `/tmp/graphql-houtou-nytprof-canonical-xs/index.html`
  - `/tmp/graphql-houtou-nytprof-canonical-xs/all_stacks_by_time.svg`
  - `/tmp/graphql-houtou-nytprof-graphql-js-xs/index.html`
  - `/tmp/graphql-houtou-nytprof-graphql-js-xs/all_stacks_by_time.svg`

補足:

- `pegex` 側の `nytprofhtml` では今回も `nytprofcalls` 由来の deep recursion warning が大量に出るが、
  `index.html` と `all_stacks_by_time.svg` は生成できている。
- 旧 `GraphQLPerlToGraphQLJS` / `GraphQLJS::PP` は削除済みのため、
  現在の `graphql-js + xs` profile は XS canonical path と location/patch 周辺の実コストをより直接に表す。
