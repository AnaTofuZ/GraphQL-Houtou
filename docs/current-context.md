# Current Context

Last updated: 2026-04-03

This file is a handoff note for continuing work in `GraphQL-Houtou`.
It records the current parser state, how to run verification, how to run
benchmarks, how to generate NYTProf output, and what remains to be done next.

## Current State

- `graphql-js` parser runtime path is XS-only.
- executable `graphql-js` parsing is `source -> IR -> graphql-js AST`.
- executable `loc` is assigned during XS build, not by a separate traversal.
- executable IR nodes are arena-allocated.
- legacy `graphql-perl` XS parser now honors `no_location`.
- XS string decoding now handles `\\uXXXX` and surrogate pairs.
- parser `line_starts` cleanup now survives `croak`/unwind by using save-stack cleanup.

## Recent Commits

- `dca58ee` `Fix XS Unicode string escapes`
- `2bb9b80` `Fix parser line_starts cleanup on croak`
- `51693a4` `Unescape GraphQL strings in XS`
- `6832f7f` `Speed up XS location lookup`
- `93b5dd0` `Thin graphql-js canonical wrapper`
- `62f4010` `Fix multi-line graphql-js loc mapping`

## Local Environment

Perl used during current verification:

```sh
/Users/anatofuz/.local/share/mise/installs/perl/5.42.0.0/perl-darwin-arm64/bin/perl
```

Working repository:

```sh
/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou
```

`PERL5LIB` used for local build/test/benchmark:

```sh
/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch
```

## Build And Test

Build:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch \
  ./Build build
```

Full test:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch \
  ./Build test
```

Current result:

- `7 files / 74 tests / PASS`

## Benchmark

Current benchmark command:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch \
  /Users/anatofuz/.local/share/mise/installs/perl/5.42.0.0/perl-darwin-arm64/bin/perl \
  util/parser-benchmark.pl --count=-5
```

Current `t/kitchen-sink.graphql` result:

```text
                             Rate graphql_perl_pegex graphql_perl_canonical_xs graphql_js_xs graphql_js_xs_noloc graphql_perl_xs
graphql_perl_pegex          485/s                 --                      -96%          -98%                -99%            -99%
graphql_perl_canonical_xs 13524/s              2687%                        --          -41%                -61%            -76%
graphql_js_xs             22756/s              4590%                       68%            --                -35%            -60%
graphql_js_xs_noloc       35076/s              7129%                      159%           54%                  --            -38%
graphql_perl_xs           56879/s             11623%                      321%          150%                 62%              --
```

Interpretation:

- `graphql-perl + xs` is still the fastest path.
- `graphql-js + xs` is now much faster than `canonical-xs`, but `loc` is still a major cost.
- `graphql-js + xs + no_location` shows the remaining non-`loc` cost floor.

## NYTProf

### Raw profile collection

Example for `graphql-perl + xs`:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch \
  NYTPROF=file=/tmp/graphql-houtou-nytprof-xs.out \
  /Users/anatofuz/.local/share/mise/installs/perl/5.42.0.0/perl-darwin-arm64/bin/perl \
  -d:NYTProf util/profile-parser.pl \
  --dialect graphql-perl --backend xs --file t/kitchen-sink.graphql --iterations 300
```

Example for `graphql-js + xs`:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/local/lib/perl5/darwin-2level:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/lib:/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/blib/arch \
  NYTPROF=file=/tmp/graphql-houtou-nytprof-graphql-js-xs.out \
  /Users/anatofuz/.local/share/mise/installs/perl/5.42.0.0/perl-darwin-arm64/bin/perl \
  -d:NYTProf util/profile-parser.pl \
  --dialect graphql-js --backend xs --file t/kitchen-sink.graphql --iterations 300
```

### HTML and flame graph generation

`graphql-perl + xs`:

```sh
nytprofhtml --file=/tmp/graphql-houtou-nytprof-xs.out --out=/tmp/graphql-houtou-nytprof-xs
```

`graphql-js + xs`:

```sh
nytprofhtml --file=/tmp/graphql-houtou-nytprof-graphql-js-xs.out --out=/tmp/graphql-houtou-nytprof-graphql-js-xs
```

Artifacts:

- HTML entry: `/tmp/.../index.html`
- flame graph: `/tmp/.../all_stacks_by_time.svg`

Previously used output locations:

- `/tmp/graphql-houtou-nytprof-pegex`
- `/tmp/graphql-houtou-nytprof-xs`
- `/tmp/graphql-houtou-nytprof-canonical-xs`
- `/tmp/graphql-houtou-nytprof-graphql-js-xs`

## Recent Work Log

- removed redundant directive `loc` rebasing in canonical processing
- thinned the Perl wrapper around the graphql-js canonical XS entrypoint
- made executable graphql-js parsing IR-first
- moved executable `loc` assignment into the XS build path
- added chunk arena allocation for executable IR nodes
- added `\\uXXXX` and surrogate pair decoding in XS string unescape
- fixed `line_starts` cleanup so parser-owned line tables are freed on `croak`

## Next Work

Priority order at this point:

1. extend `canonical-xs -> graphql-perl` parity, especially `location` semantics
2. re-profile `graphql-js + xs` and continue reducing `loc` overhead
3. decide how much of upstream `GraphQL` parser dependency should remain
4. refresh README / POD / release metadata for standalone distribution quality

## Notes

- keep using raw `require`; do not switch these call sites to `Module::Load`
- tests and benchmarks assume local dependencies under `GraphQL-Houtou/local`
- always rebuild before running tests or benchmarks after XS changes
