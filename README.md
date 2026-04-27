[![Actions Status](https://github.com/AnaTofuZ/GraphQL-Houtou/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/AnaTofuZ/GraphQL-Houtou/actions?workflow=test)
# NAME

GraphQL::Houtou - XS-backed GraphQL parser and execution toolkit for Perl

# SYNOPSIS

    use GraphQL::Houtou qw(
      parse
      parse_with_options
      execute
      compile_runtime
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

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },
      is_promise => sub { my ($value) = @_; ... },
    });

# DESCRIPTION

GraphQL::Houtou provides XS-backed GraphQL parsing and execution with
compatibility layers for both the legacy `graphql-perl` AST and a
`graphql-js`-style AST.

This distribution was split out from local parser work that originally lived
in a fork of [graphql-perl](https://github.com/graphql-perl/graphql-perl).
It still uses the upstream `GraphQL` distribution as a dependency for some
compatibility behavior, while making the XS path the normal fast path for both
parser and execution work.

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
    my $program = $runtime->compile_operation($document);
    my $result  = $runtime->execute_operation($program, variables => \%vars);

This runtime-backed API prefers the native XS engine when the lowered program
stays within the current native-safe subset. Programs that still require
features not yet lowered into the native engine automatically fall back to the
Perl VM. The Perl VM remains available as an explicit cold path via
`execute_runtime_perl(...)`/`execute_program_perl(...)`.

The runtime-backed API above is the intended mainline. Older execution
compatibility tests live under `legacy-tests/` and are no longer part of the
active suite.

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

As of 2026-04-06, practical execution benchmarks using
`util/execution-benchmark.pl --count=-3` produced the following snapshot:

- `simple_scalar` AST execution:
`houtou_xs_ast` about 139,565/s, `houtou_compiled_ir` about 139,515/s,
`upstream_ast` about 41,261/s
- `nested_variable_object` AST execution:
`houtou_compiled_ir` about 79,130/s, `houtou_xs_ast` about 77,441/s,
`upstream_ast` about 25,041/s
- `list_of_objects` AST execution:
`houtou_xs_ast` about 58,659/s, `houtou_compiled_ir` about 57,941/s,
`upstream_ast` about 17,816/s
- `abstract_with_fragment` AST execution:
`houtou_xs_ast` about 41,687/s, `houtou_compiled_ir` about 41,647/s,
`upstream_ast` about 23,641/s
- `async_scalar` AST execution:
`houtou_facade_ast` about 78,946/s, `houtou_compiled_ir` about 77,535/s,
`upstream_ast` about 41,389/s
- `async_list` AST execution:
`houtou_compiled_ir` about 43,671/s, `houtou_facade_ast` about 43,260/s,
`upstream_ast` about 26,131/s

This confirms several practical points:

- the XS path is now materially faster than upstream execution in the benchmarked
AST and source-string cases
- compiled IR plans are now a real execution path, not just parser metadata; they
already improve over prepared IR and are competitive with, or better than, the
best AST-based Houtou path in several practical cases
- the execution XS work is paying off not only for nested/list/object workloads
but also for promise-backed scalar and list cases
- turning off parser location handling still materially improves parse-only
throughput when you do not need `loc` or `location` data

The exact benchmark command and more detailed performance notes are kept in
`docs/execution-benchmark.md` and `docs/current-context.md`.

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
