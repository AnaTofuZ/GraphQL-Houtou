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
      set_default_promise_code
    );
    use GraphQL::Houtou::Schema;
    use GraphQL::Houtou::Type;
    use GraphQL::Houtou::Type::Object;
    use GraphQL::Houtou::Type::Scalar;

    my $legacy_ast = parse('{ user { id } }');

    my $js_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-js',
      backend => 'xs',
    });

    my $legacy_xs_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

    my $fast_js_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-js',
      backend => 'xs',
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

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },
      is_promise => sub { my ($value) = @_; ... },
    });

# DESCRIPTION

GraphQL::Houtou provides an XS-first GraphQL parser and runtime for Perl.
The parser still exposes both a legacy `graphql-perl` AST and a
`graphql-js`-style AST, but the execution mainline is the compiled
runtime / VM pipeline.

The current direction is:

- parser compatibility where the public API still needs it
- XS-required public compiler / validation facades
- runtime-first execution through compiled programs and native bundles
- legacy implementation tests and snapshots preserved under `legacy-tests/`
instead of shaping the active mainline

# USAGE

## Parsing

The default `parse()` entry point returns the traditional
`graphql-perl`-compatible AST.

    my $ast = parse($source);

If you want to choose the dialect explicitly, use `parse_with_options()`.

    my $legacy = parse_with_options($source, {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

    my $graphql_js = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
    });

For throughput-sensitive parsing where you do not need location data, passing
`no_location => 1` is still recommended.

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
      no_location => 1,
    });

## Executing Queries

The top-level runtime API is:

    my $result = GraphQL::Houtou::execute($schema, $document, \%vars);

Where `$document` can be either:

- a source string
- a pre-parsed `graphql-perl`-compatible AST

If you need a reusable compiled runtime, use:

    my $runtime = GraphQL::Houtou::compile_runtime($schema);
    my $program = $runtime->compile_program($document);
    my $result  = $runtime->execute_program($program, variables => \%vars);

If you want a boot-time native artifact, use:

    my $bundle = GraphQL::Houtou::compile_native_bundle($schema, $document);
    my $result = $bundle->execute;

Or execute directly through the cached native runtime:

    my $result = GraphQL::Houtou::execute_native($schema, $document);

This runtime-backed API prefers the native XS engine when the lowered program
stays within the current native-safe subset. Programs that still require
features not yet lowered into the native engine automatically fall back to the
Perl VM. The Perl VM remains available as an explicit cold path via
`engine => 'perl'`.

The runtime-backed API above is the intended mainline. The public compiler and
validation facades now require XS. Older implementation tests and snapshots
live under `legacy-tests/` and are no longer part of the active suite.

## Promise Hooks

Promise support is configured by user-supplied hooks rather than by naming a
specific promise library. You can set global defaults via:

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },    # optional
      is_promise => sub { my ($value) = @_; ... },             # optional
    });

The intended contract is:

- `resolve($value)` returns a fulfilled promise
- `reject($error)` returns a rejected promise
- `all(@promises)` returns an aggregate promise that fulfills to the resolved
values
- `then($promise, $on_fulfilled, $on_rejected)` chains a promise
- `is_promise($value)` returns true when the value should be treated as a
promise

Per-request overrides are also supported by the execution layer. The public
API keeps the hook contract generic so that adapters can be supplied by user
code for `Promises`, `Future`, `Promise::XS`, `Promise::ES6`,
`Mojo::Promise`, or any other library with a suitable wrapper.

# DIALECTS

## graphql-perl compatible layer

The default `parse()` entry point returns the traditional `graphql-perl`
compatible AST.

    my $ast = parse($source);

If you want to be explicit about the backend, use `parse_with_options()`.

    my $ast = parse_with_options($source, {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

The `pegex` backend is still available for compatibility, but the intended
default path is `xs`.

## graphql-js compatible layer

If you want a `graphql-js`-style AST, select the `graphql-js` dialect.

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
    });

The `graphql-js` parser currently supports only the `xs` backend.

# PERFORMANCE NOTES

Computing location data costs real time. If you do not need `location` or
`loc` information, passing `no_location => 1` is more efficient and is
recommended for throughput-sensitive workloads.

Example:

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
      no_location => 1,
    });

# BENCHMARK SNAPSHOT

現在の比較対象は旧 \`compiled\_ir\` 系ではなく、runtime/VM mainline です。

主な評価軸は次の 2 系統です。

- cached runtime (Perl VM)
- cached native bundle (XS VM)

ベンチマークでは resolver の結果をキャッシュするのではなく、
schema/runtime/program のコンパイル済み実行計画を再利用した時の
スループットを見ます。

典型的なコマンドは次です。

    perl util/execution-benchmark.pl --count=-3
    perl util/execution-benchmark-checkpoint.pl --repeat=5 --count=-3

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
