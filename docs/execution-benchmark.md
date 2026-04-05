# Execution Benchmark Snapshot

## Purpose

This note records a practical execution benchmark comparing upstream
`GraphQL` and `GraphQL::Houtou`.

The goal is not to isolate one micro-path. Instead, the benchmark covers
realistic `execute(...)` usage patterns:

- source string to execute
- pre-parsed AST to execute
- nested objects
- variable coercion
- list completion
- abstract type / fragment handling
- a basic promise-backed case

The benchmark driver is:

- `util/execution-benchmark.pl`

## Measurement Setup

Command used:

```sh
perl util/execution-benchmark.pl --count=-3
```

Compared implementations:

- upstream `GraphQL::Execution::execute`
- `GraphQL::Houtou::Execution::execute`
- `GraphQL::Houtou::XS::Execution::execute_xs`

Modes:

- `*_string`: execute from source string
- `*_ast`: execute from pre-parsed AST

For promise-backed execution, the benchmark currently compares:

- upstream `GraphQL::Execution::execute`
- `GraphQL::Houtou::Execution::execute`

`GraphQL::Houtou::XS::Execution::execute_xs` is not included there because
promise-heavy execution still intentionally stays on the PP path.

## Results

### simple_scalar

Query:

```graphql
{ hello greet(name: "houtou") }
```

Rates:

- `upstream_string`: `4959/s`
- `houtou_facade_string`: `34829/s`
- `houtou_xs_string`: `35763/s`
- `houtou_facade_ast`: `35968/s`
- `houtou_xs_ast`: `37486/s`
- `upstream_ast`: `43305/s`

Observations:

- Houtou is much faster for end-to-end string execution.
- Upstream still wins when AST is already available and the query is flat.

### nested_variable_object

Query:

```graphql
query q($id: ID!) { user(id: $id) { id name } }
```

Rates:

- `upstream_string`: `3110/s`
- `houtou_facade_string`: `25418/s`
- `houtou_xs_string`: `26131/s`
- `upstream_ast`: `25444/s`
- `houtou_facade_ast`: `26891/s`
- `houtou_xs_ast`: `27629/s`

Observations:

- Houtou is far ahead on source-string execution.
- For nested object execution with variable coercion, Houtou XS also edges out upstream AST.

### list_of_objects

Query:

```graphql
{ users { id name } }
```

Rates:

- `upstream_string`: `3912/s`
- `upstream_ast`: `18038/s`
- `houtou_facade_string`: `18562/s`
- `houtou_xs_string`: `18850/s`
- `houtou_facade_ast`: `19095/s`
- `houtou_xs_ast`: `19183/s`

Observations:

- Houtou is again much faster on string execution.
- On AST execution, Houtou is slightly ahead in this list-of-objects case.

### abstract_with_fragment

Query:

```graphql
{ searchResult { __typename ... on User { id name } } }
```

Rates:

- `upstream_string`: `3012/s`
- `houtou_facade_string`: `17706/s`
- `houtou_xs_string`: `17940/s`
- `houtou_facade_ast`: `18390/s`
- `houtou_xs_ast`: `18608/s`
- `upstream_ast`: `23655/s`

Observations:

- Houtou still dominates source-string execution.
- Upstream remains stronger when AST is already materialized and abstract-type work is involved.

### async_scalar

Query:

```graphql
{ asyncHello }
```

Rates:

- `upstream_string`: `6507/s`
- `houtou_facade_string`: `31970/s`
- `houtou_facade_ast`: `34449/s`
- `upstream_ast`: `41008/s`

Observations:

- Even on the current PP-oriented promise path, Houtou is much faster for source-string execution.
- Upstream still wins for AST-only promise-backed execution.

## Summary

Current takeaways:

- `GraphQL::Houtou` is already strong for practical end-to-end execute from source strings.
- The execution XS work is paying off most in nested object, list, and variable-heavy paths.
- Upstream `GraphQL` still has an advantage when AST is already parsed, especially in flatter or more abstract-type-heavy cases.
- Promise-backed execution is not yet an XS-driven win area. It remains mostly a PP path by design.

In short:

- parser + execute together: Houtou is already very competitive and often much faster
- execute on prebuilt AST only: still a meaningful optimization target
- promise-heavy execution: still primarily a compatibility path, not yet a performance path

## Why `simple_scalar` Still Loses On Prebuilt AST

The `simple_scalar` case is:

```graphql
{ hello greet(name: "houtou") }
```

This is almost the worst case for the current XS migration strategy, because it
contains very little of the work that XS currently helps most with:

- no nested object traversal
- no list completion
- no abstract type resolution
- no fragment-heavy field collection
- no meaningful null-propagation work

So in this case, the result is dominated by fixed per-field overhead rather than
deep execution work.

In the current Houtou implementation, that fixed overhead still includes:

- Perl root field collection via `GraphQL::Houtou::Type::Object::_collect_fields`
- per-field `path` copying
- per-field `ResolveInfo` hash construction
- argument hash construction even for tiny argument sets
- result hash merge for a very small number of leaf fields

For more complex queries, XS fast paths amortize these costs well enough to pull
ahead. For `simple_scalar`, they do not.

That explains the current pattern:

- source-string execution: Houtou wins due to parser + execute integration
- prebuilt AST execution on a flat query: upstream still wins on lower fixed overhead

## Next Optimization Targets

The most likely next wins for prebuilt-AST flat queries are:

1. Reduce `ResolveInfo` construction cost.
2. Add a thinner no-args leaf-field fast path.
3. Move root `_collect_fields()` into XS.
4. Trim result merge overhead for tiny leaf-only selections.

In practice, the first two are likely the best low-risk next step, while root
field collection in XS is the larger structural improvement.
