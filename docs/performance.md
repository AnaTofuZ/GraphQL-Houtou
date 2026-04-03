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
