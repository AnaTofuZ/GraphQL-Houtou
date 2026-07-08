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

## Building a schema from SDL

`build_schema()` turns a Schema Definition Language document into an
executable [GraphQL::Houtou::Schema](https://metacpan.org/pod/GraphQL%3A%3AHoutou%3A%3ASchema). Field resolvers, abstract type
dispatch, and custom scalar coercion can be attached through the
`resolvers` option:

    use GraphQL::Houtou qw(build_schema execute);

    my $schema = build_schema(<<'SDL',
    type Query {
      dog(id: ID = "1"): Dog
      pets: [Pet!]
    }
    interface Pet { name: String! }
    type Dog implements Pet { name: String! }
    SDL
      resolvers => {
        Query => {
          dog  => sub { my (undef, $args) = @_; load_dog($args->{id}) },
          pets => sub { all_pets() },
        },
        Pet => { resolve_type => sub { 'Dog' } },
      },
    );

    my $result = execute($schema, '{ dog { name } }');

Fields without an explicit resolver use the default hash/method resolver.
Custom scalars default to pass-through `serialize` / `parse_value`; supply
your own through `resolvers` when coercion matters. `@deprecated`,
`@specifiedBy`, `@oneOf`, and `repeatable` directive definitions in the
SDL are reflected on the built types. The same functionality is available as
`GraphQL::Houtou::Schema->from_doc($sdl, %opts)` and
`->from_ast($ast, %opts)`. Type extensions (`extend type`) are not
supported yet.

The inverse direction is `print_schema()` (also available as
`$schema->to_doc`), which renders any schema back to SDL — including
schemas assembled from Perl type objects:

    use GraphQL::Houtou qw(print_schema);
    my $sdl = print_schema($schema);

Built-in scalars, introspection meta types, and the specified directives
(`@include`, `@skip`, `@deprecated`, `@specifiedBy`) are omitted from
the output, matching graphql-js `printSchema`. Types are emitted sorted by
name, so the output is stable and diff-friendly.

## Batching resolvers (DataLoader / the on\_stall hook)

SQL-backed schemas avoid the N+1 problem by batching: resolvers return
promises from a loader, and the queued keys are fetched in one query when
execution cannot proceed any further. Pass an `on_stall` callback to
`execute()` (or `execute_document` / `execute_program`) to drive this:

    use GraphQL::Houtou::DataLoader;

    my $users = GraphQL::Houtou::DataLoader->new(batch => sub {
      my ($ids) = @_;
      my %row = map { $_->{id} => $_ } $db->select_users_in(@$ids);
      return [ map { $row{$_} } @$ids ];
    });

    my $result = execute($schema, $query, $variables,
      context => { users => $users },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users),
    );

With `on_stall` the request runs on the async-capable lane and is driven
to completion internally: whenever every remaining field is waiting on a
promise, the callback is invoked and must make progress (return its
dispatch count) by resolving promises - flushing loaders, typically. The
finished response is returned synchronously; callers never see promises.
If the callback reports no progress while promises remain pending, the
request fails with a deadlock error instead of hanging.

The contract is loader-agnostic: anything that can resolve the pending
promises may implement `on_stall`. [GraphQL::Houtou::DataLoader](https://metacpan.org/pod/GraphQL%3A%3AHoutou%3A%3ADataLoader) is the
bundled reference implementation.

### Declaring an async schema (async => 1)

Batching is the normal deployment shape, so runtimes accept a single
declaration instead of per-request plumbing:

    my $runtime = build_native_runtime($schema, async => 1);

An async runtime starts every request on the async-capable lane: promise
resolvers work with or without variables, `execute_document` returns the
settled envelope (or a promise while pending), and
`execute_document_to_json` renders JSON as soon as the response settles.
Per-request `on_stall` hooks compose with it as usual and remain the way
DataLoader batches are flushed.

Without the declaration, requests with variables run on the synchronous
fast lane, which cannot suspend. A resolver returning a Promise::XS
promise there fails immediately with an error pointing at `async => 1`
and `on_stall` - promise objects never leak into response data.
`engine => 'native'` forces the strict sync lane even on an async
runtime.

## Serving JSON responses directly

When the response is going straight onto the wire (PSGI handlers and other
HTTP servers), `execute_to_json()` renders the GraphQL response as UTF-8
JSON bytes entirely inside the XS fast lane - the Perl response hash is
never materialized and no JSON module runs:

    use GraphQL::Houtou qw(execute_to_json);
    my $bytes = execute_to_json($schema, '{ users { id name } }');
    # => {"data":{"users":[...]},"errors":[]}

The same lane is available on a reusable runtime:

    my $runtime = build_native_runtime($schema);
    my $bytes = $runtime->execute_document_to_json($query, variables => \%vars);
    my $bytes = $runtime->execute_bundle_to_json($bundle);   # persisted queries

Properties:

- roughly twice the effective throughput of `execute()` followed by
a JSON module, since response hashes and arrays are never built
- response keys appear in query field order, as the GraphQL spec
recommends (plain `execute()` returns Perl hashes, which cannot preserve
order)
- the envelope matches `execute()`: `"data"` plus `"errors"`
(message and path), with `"errors":[]` when the request succeeded
- without `on_stall`, the lane is synchronous - a resolver returning
a Promise::XS promise croaks

### Batching resolvers and JSON output

`execute_to_json()` and `execute_document_to_json()` accept the same
`on_stall` option as `execute()`. The request then runs on the
async-capable lane and the completed response is serialized to JSON bytes
directly from the native result tree when it resolves - the Perl envelope
hash is still never built:

    my $loader = GraphQL::Houtou::DataLoader->new(batch => \&batch_users);
    my $bytes = execute_to_json(
      $schema, $query, \%vars,
      context  => { users => $loader },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );

Two properties differ from the synchronous JSON lane: response keys appear
in completion order (synchronously resolved fields first, batched fields
as they settle) rather than query order, and Boolean-typed leaves render
as the resolver returned them (`0`/`1`) rather than JSON booleans,
matching what `execute()` plus a JSON module produces for the same async
request. JSON object member order carries no meaning, and both points are
slated to converge with the sync lane as the async hot path work lands.

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

# CAVEATS

## Perl ithreads are not supported

The runtime keeps request and schema state in C structures referenced by
opaque XS handles. Duplicating those raw pointers across `ithreads` would
lead to double frees, so every handle class defines `CLONE_SKIP`, making
thread clones drop them (they become `undef` in the child thread) instead
of crashing. Use process-based concurrency (prefork PSGI servers or fork)
for parallelism.

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
