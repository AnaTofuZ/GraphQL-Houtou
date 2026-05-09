[![Actions Status](https://github.com/AnaTofuZ/GraphQL-Houtou/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/AnaTofuZ/GraphQL-Houtou/actions?workflow=test)
# NAME

GraphQL::Houtou - XS-backed GraphQL parser and execution toolkit for Perl

# SYNOPSIS

    use GraphQL::Houtou qw(
      parse
      parse_with_options
      execute
      compile_runtime
      compile_native_bundle
      execute_native
    );
    use GraphQL::Houtou::Schema;
    use GraphQL::Houtou::Type;
    use GraphQL::Houtou::Type::Object;
    use GraphQL::Houtou::Type::Scalar;

    my $ast = parse('{ user { id } }');

    my $fast_ast = parse_with_options('{ user { id } }', {
      no_location => 1,
    });

    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          hello => {
            type => GraphQL::Houtou::Type::Scalar->new(
              name => 'String',
              graphql_to_perl => sub { $_[0] },
              perl_to_graphql => sub { $_[0] },
            ),
            resolve => sub { 'world' },
          },
        },
      ),
    );

    my $result = execute($schema, '{ hello }');
    my $runtime = compile_runtime($schema);
    my $bundle = compile_native_bundle($schema, '{ hello }');
    my $native = execute_native($schema, '{ hello }');

# DESCRIPTION

GraphQL::Houtou provides an XS-first GraphQL parser and runtime for Perl.
The parser surface returns the library's canonical Perl AST, while the
execution mainline is the compiled runtime / VM pipeline.

The current direction is:

- XS-required public compiler / validation facades
- runtime-first execution through compiled programs and native bundles
- legacy implementation tests and snapshots preserved under `legacy-tests/`
instead of shaping the active mainline

# USAGE

## Parsing

The default `parse()` entry point returns the canonical parser AST used by
this library.

    my $ast = parse($source);

If you want to tune parser options explicitly, use `parse_with_options()`.

    my $ast = parse_with_options($source, {
      no_location => 1,
    });

For throughput-sensitive parsing where you do not need location data, passing
`no_location => 1` is still recommended.

    my $doc = parse_with_options($source, {
      no_location => 1,
    });

## Executing Queries

The top-level runtime API is:

    my $result = GraphQL::Houtou::execute($schema, $document, \%vars);

Where `$document` can be either:

- a source string
- a pre-parsed parser AST returned by `parse()` or `parse_with_options()`

If you need a reusable compiled runtime, use:

    my $runtime = GraphQL::Houtou::compile_runtime($schema);
    my $program = $runtime->compile_program($document);
    my $result  = $runtime->execute_program($program, variables => \%vars);

If you want a boot-time native artifact, use:

    my $bundle = GraphQL::Houtou::compile_native_bundle($schema, $document);
    my $runtime = GraphQL::Houtou::build_native_runtime($schema);
    my $result = $runtime->execute_bundle($bundle);

Or execute directly through the cached native runtime:

    my $result = GraphQL::Houtou::execute_native($schema, $document);

This runtime-backed API is native-first on the sync path. Programs that stay
within the current native-safe subset are specialized into the native VM and
executed there. If a resolver yields a `Promise::XS::Promise`, execution
automatically continues on the Promise::XS-backed async path.

The runtime-backed API above is the intended mainline. The public compiler and
validation facades now require XS. Older implementation tests and snapshots
live under `legacy-tests/` and are no longer part of the active suite.

## Promise Support

Async execution now targets `Promise::XS` directly and is detected
automatically. If a resolver returns a `Promise::XS::Promise`, the runtime
will continue on the async path and may return a `Promise::XS::Promise` as
the top-level result.

Generic promise adapters and `promise_code` injection are no longer part of
the active runtime path.

# PARSER SURFACE

The public parser surface is fixed to the library's canonical parser AST.
`parse_with_options()` only accepts parser-local knobs such as
`no_location`.

# PERFORMANCE NOTES

Computing location data costs real time. If you do not need `location` or
`loc` information, passing `no_location => 1` is more efficient and is
recommended for throughput-sensitive workloads.

Example:

    my $doc = parse_with_options($source, {
      no_location => 1,
    });

# BENCHMARK SNAPSHOT

現在の比較対象は旧 executor ではなく、runtime/VM mainline です。

主な評価軸は次の 2 系統です。

- cached runtime (Perl VM)
- cached native bundle (XS VM)

ベンチマークでは resolver の結果をキャッシュするのではなく、
schema/runtime/program のコンパイル済み実行計画を再利用した時の
スループットを見ます。

典型的なコマンドは次です。

    perl util/execution-benchmark.pl --count=-3
    perl util/execution-benchmark-checkpoint.pl --repeat=5 --count=-3

\`fd72137\` 時点の中央値は次のとおりです。

- sync \`runtime\_program\`

        - `nested_variable_object`: `3266/s`
        - `list_of_objects`: `3266/s`
        - `abstract_with_fragment`: `3257/s`

- sync \`native\_bundle\`

        - `nested_variable_object`: `582772/s`
        - `list_of_objects`: `515525/s`
        - `abstract_with_fragment`: `576014/s`

- async \`Promise::XS\` auto-detect path

        - `async_scalar`: `3083/s`
        - `async_list`: `3082/s`
        - `async_object`: `3082/s`
        - `async_abstract`: `3054/s`

要点は、現在の最速経路は依然として \`native\_bundle\` の specialized
sync fast lane であり、public の \`runtime\_program\` / Promise::XS async
mainline はおおむね \`3.0k/s\` 前後に揃っている、ということです。
async path は undocumented な \`Promise::XS\` 内部 await hook には依存せず、
documented な \`then\` / \`all\` と Promise::XS 型判定だけを使います。

詳細な評価軸は `docs/execution-benchmark.md`、現在の実装前提は
`docs/current-context.md` と `docs/runtime-vm-architecture.md` にあります。

# NAME ORIGIN

The name `Houtou` comes from several overlapping references:

- Japanese `hotou` / "treasured sword" (宝刀)
- Yamanashi's noodle dish `houtou` (ほうとう)
- the VTuber `宝灯桃汁` (Houtou Momojiru)

# LICENSE

Copyright (C) anatofuz.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

anatofuz <anatofuz@gmail.com>
