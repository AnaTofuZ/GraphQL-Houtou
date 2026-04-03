[![Actions Status](https://github.com/AnaTofuZ/GraphQL-Houtou/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/AnaTofuZ/GraphQL-Houtou/actions?workflow=test)
# NAME

GraphQL::Houtou - XS recursive-descent GraphQL parser toolkit for Perl

# SYNOPSIS

    use GraphQL::Houtou qw(parse parse_with_options);

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

# DESCRIPTION

GraphQL::Houtou provides an XS recursive-descent GraphQL parser plus
compatibility layers for both the legacy `graphql-perl` AST and a
`graphql-js`-style AST.

This distribution was split out from local parser work that originally lived
in a fork of [graphql-perl](https://github.com/graphql-perl/graphql-perl).
It still uses the upstream `GraphQL` distribution as a dependency for some
compatibility behavior, while making the XS parser path the normal fast path.

# DIALECTS AND USAGE

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

As of 2026-04-03, a local benchmark on `t/kitchen-sink.graphql` produced the
following rough results:

- `graphql_perl_pegex`: about 485 parses/sec
- `graphql_perl_canonical_xs`: about 13,524 parses/sec
- `graphql_js_xs`: about 22,756 parses/sec
- `graphql_js_xs_noloc`: about 35,076 parses/sec
- `graphql_perl_xs`: about 56,879 parses/sec

This confirms two practical points:

- the XS parser path is substantially faster than the Pegex path
- turning off location handling materially improves throughput

The exact benchmark command and more detailed performance notes are kept in
`docs/current-context.md` and `docs/performance.md`.

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
