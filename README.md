[![Actions Status](https://github.com/AnaTofuZ/GraphQL-Houtou/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/AnaTofuZ/GraphQL-Houtou/actions?workflow=test)
# NAME

GraphQL::Houtou - XS-backed GraphQL parser and execution toolkit for Perl

# SYNOPSIS

    use GraphQL::Houtou qw(execute build_native_runtime compile_native_bundle);
    use GraphQL::Houtou::Schema;
    use GraphQL::Houtou::Type::Object;
    use GraphQL::Houtou::Type::Scalar qw($String);

    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name   => 'Query',
        fields => {
          hello => { type => $String, resolve => sub { 'world' } },
        },
      ),
    );

    # --- one-off ---
    my $result = execute($schema, '{ hello }');

    # --- dynamic queries with variables (production) ---
    my $runtime = build_native_runtime($schema);
    my $result  = $runtime->execute_document(
      '{ user(id: $id) }', variables => { id => 42 },
    );

    # --- fixed query, maximum throughput (no variables) ---
    my $bundle  = compile_native_bundle($schema, '{ hello }');
    my $result  = $runtime->execute_bundle($bundle);

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

## API Selection Guide

Choose the execution API that fits your use case.

### One-off or development execution

    my $result = execute($schema, '{ hello }');
    my $result = execute($schema, '{ user(id: $id) }', { id => 42 });

`execute()` is the simplest entry point. It builds and caches a native
runtime automatically. Use this for one-off calls or during development.

### Repeated execution with different variables (dynamic queries)

For production workloads where the same schema serves many queries or the
same query with different variable sets, obtain a runtime once and reuse it:

    my $runtime = build_native_runtime($schema);

    # compile_program result is cached per query string (FIFO, default 1000).
    # Repeated calls with the same query string skip the compiler entirely.
    my $result = $runtime->execute_document($query, variables => \%vars);

You can tune the cache size:

    my $runtime = build_native_runtime($schema, program_cache_max => 500);

### Persisted queries

A persisted query is a pre-compiled artifact stored outside the automatic
program cache and reused across requests by application code.

**Fixed query (no variables)** — compile once into a native bundle at startup,
execute any number of times with zero compile overhead per request:

    use GraphQL::Houtou qw(build_native_runtime compile_native_bundle);

    my $runtime = build_native_runtime($schema);
    my %store = (
      hello => compile_native_bundle($schema, '{ hello }'),
    );

    # request time
    my $result = $runtime->execute_bundle($store{hello});

**Variable-bearing query** — compile once into a program object; supply
different variables per request:

    my $runtime = build_native_runtime($schema);
    my %store = (
      greet => $runtime->compile_program(
        'query($name: String){ greet(name: $name) }',
      ),
    );

    # request time — same compiled program, different variables each call
    my $alice = $runtime->execute_program(
      $store{greet}, variables => { name => 'alice' },
    );
    my $bob = $runtime->execute_program(
      $store{greet}, variables => { name => 'bob' },
    );

**Bundle descriptor** — a serialisable representation of a fixed query bundle,
useful when the artifact must cross a process boundary or be stored on disk:

    use GraphQL::Houtou qw(build_native_runtime compile_native_bundle_descriptor);

    # at build / warm-up time
    my %store = (
      hello => compile_native_bundle_descriptor($schema, '{ hello }'),
    );

    # request time
    my $result = $runtime->execute_bundle_descriptor($store{hello});

Use a native bundle object for in-process reuse; use a descriptor when the
artifact needs to be serialised.

### Fixed queries compiled at boot time (maximum throughput)

If your query is known at startup and uses **no GraphQL variables**, compile it
once into a native bundle and reuse it across all requests:

    my $bundle  = compile_native_bundle($schema, '{ hello }');
    my $runtime = build_native_runtime($schema);

    # Hot path — no Perl VM compile overhead per request
    my $result  = $runtime->execute_bundle($bundle);

**Important:** a native bundle bakes argument values into its binary
representation at compile time. Queries that accept GraphQL variables
(`$id`, `$name`, etc.) must use the dynamic query path above — passing
variables to `execute_bundle` at request time is not supported.

### Async / Promise resolvers

No extra configuration is needed. If any resolver returns a
`Promise::XS::Promise`, the runtime automatically switches to the async path
and may return a `Promise::XS::Promise` as the top-level result.

Mutation fields always execute serially: each resolver is called only after
the previous resolver's promise has resolved, in conformance with the GraphQL
specification.

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

The current benchmark baseline is the runtime/VM mainline rather than the
legacy executor.

The primary sync measurements focus on two execution modes:

- cached runtime (Perl VM)
- cached native bundle (XS VM)

These benchmarks do not cache resolver return values. They measure throughput
when the compiled schema/runtime/program artifacts are reused across requests.

Typical commands are:

    perl util/execution-benchmark.pl --count=-3
    perl util/execution-benchmark-checkpoint.pl --repeat=5 --count=-3

Median results at `fd72137` were:

- sync `runtime_program`

        - C<nested_variable_object>: C<3266/s>
        - C<list_of_objects>: C<3266/s>
        - C<abstract_with_fragment>: C<3257/s>

- sync `native_bundle`

        - C<nested_variable_object>: C<582772/s>
        - C<list_of_objects>: C<515525/s>
        - C<abstract_with_fragment>: C<576014/s>

- async `Promise::XS` auto-detect path

        - C<async_scalar>: C<3083/s>
        - C<async_list>: C<3082/s>
        - C<async_object>: C<3082/s>
        - C<async_abstract>: C<3054/s>

The key point is that the specialized sync fast lane for `native_bundle`
remains the fastest path by a wide margin, while the public
`runtime_program` path and the Promise::XS async mainline currently cluster
around `3.0k/s`. The async path no longer depends on undocumented
Promise::XS await hooks and uses only documented `then`, `all`, and
Promise::XS type detection.

For detailed methodology, see `docs/execution-benchmark.md`. For the current
implementation assumptions, see `docs/current-context.md` and
`docs/runtime-vm-architecture.md`.

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
