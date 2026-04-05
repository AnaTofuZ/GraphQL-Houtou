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

`GraphQL::Houtou::XS::Execution::execute_xs` is not listed separately there
because the public Houtou facade now routes promise-aware execution through the
XS-backed path internally.

## Results

### simple_scalar

Query:

```graphql
{ hello greet(name: "houtou") }
```

Rates:

- `upstream_string`: `4859/s`
- `upstream_ast`: `42334/s`
- `houtou_facade_string`: `111655/s`
- `houtou_xs_string`: `118791/s`
- `houtou_facade_ast`: `124889/s`
- `houtou_xs_ast`: `133720/s`

Observations:

- Houtou is much faster for both source-string and prebuilt-AST execution.
- The flat-query fixed overhead work that previously hurt `simple_scalar` is no
  longer a bottleneck in this benchmark.

### nested_variable_object

Query:

```graphql
query q($id: ID!) { user(id: $id) { id name } }
```

Rates:

- `upstream_string`: `3084/s`
- `upstream_ast`: `25038/s`
- `houtou_facade_string`: `56170/s`
- `houtou_xs_string`: `59513/s`
- `houtou_facade_ast`: `63352/s`
- `houtou_xs_ast`: `66215/s`

Observations:

- Houtou is far ahead on source-string execution.
- On prebuilt AST, Houtou now clearly beats upstream as well.

### list_of_objects

Query:

```graphql
{ users { id name } }
```

Rates:

- `upstream_string`: `3889/s`
- `upstream_ast`: `17926/s`
- `houtou_facade_string`: `44929/s`
- `houtou_xs_string`: `47184/s`
- `houtou_facade_ast`: `47900/s`
- `houtou_xs_ast`: `49028/s`

Observations:

- Houtou is again much faster on string execution.
- On AST execution, Houtou now has a wide margin in this list-of-objects case.

### abstract_with_fragment

Query:

```graphql
{ searchResult { __typename ... on User { id name } } }
```

Rates:

- `upstream_string`: `3032/s`
- `upstream_ast`: `23801/s`
- `houtou_facade_string`: `34238/s`
- `houtou_xs_string`: `35318/s`
- `houtou_facade_ast`: `36559/s`
- `houtou_xs_ast`: `37449/s`

Observations:

- Houtou still dominates source-string execution.
- The abstract-type / fragment path now also beats upstream on prebuilt AST.

### async_scalar

Query:

```graphql
{ asyncHello }
```

Rates:

- `upstream_string`: `6957/s`
- `upstream_ast`: `42173/s`
- `houtou_facade_string`: `71050/s`
- `houtou_facade_ast`: `74722/s`

Observations:

- Promise-backed execution is now strongly XS-backed through the public facade.
- Houtou now beats upstream even for AST-only promise-backed scalar execution.

### async_list

Query:

```graphql
{ asyncList }
```

Rates:

- `upstream_string`: `6198/s`
- `upstream_ast`: `26212/s`
- `houtou_facade_string`: `40163/s`
- `houtou_facade_ast`: `41505/s`

Observations:

- Promise-backed list execution also now beats upstream on both string and AST paths.
- This case improved materially once prepared execution, field merge, and leaf
  completion stopped crossing the PP bridge.

## Summary

Current takeaways:

- `GraphQL::Houtou` is now strong both for practical source-string execution
  and for the prebuilt-AST workloads covered by this benchmark.
- The execution XS work is paying off across flat, nested, list, abstract, and
  promise-backed cases.
- Promise-backed execution is no longer just a compatibility path in this
  benchmark set; it is now a performance win area too.

In short:

- parser + execute together: Houtou is much faster
- execute on prebuilt AST: Houtou now also wins across the benchmarked cases
- promise-heavy execution: now XS-backed enough to outperform upstream in the
  benchmarked scalar and list cases

## Why `simple_scalar` Used To Lose On Prebuilt AST

The `simple_scalar` case is:

```graphql
{ hello greet(name: "houtou") }
```

This used to be almost the worst case for the XS migration strategy, because it
contains very little of the work that XS currently helps most with:

- no nested object traversal
- no list completion
- no abstract type resolution
- no fragment-heavy field collection
- no meaningful null-propagation work

So the result used to be dominated by fixed per-field overhead rather than deep
execution work.

The main fixed costs were:

- Perl root field collection via `GraphQL::Houtou::Type::Object::_collect_fields`
- per-field `path` copying
- per-field `ResolveInfo` hash construction
- argument hash construction even for tiny argument sets
- result hash merge for a very small number of leaf fields

The later execution work changed that picture by:

- trimming `ResolveInfo` construction
- moving prepared execution into XS
- making top-level field execution promise-aware in XS
- eliminating the remaining PP bridge in promise leaf completion

That is why `simple_scalar` now swings heavily in Houtou's favor.

## Next Optimization Targets

The next likely wins are no longer the old flat-query basics. The more useful
remaining directions are:

1. Shrink the remaining complex object/list completion fallbacks.
2. Push abstract-type and fragment-heavy error paths deeper into XS.
3. Continue reducing compatibility-shape allocation in the AST execution path.
4. Extend benchmark coverage to more schema-heavy and mutation-oriented cases.
- the fast path is present, but the fallback boundary is still comparatively near

This is no longer a parser problem; it is execution-front-end overhead around
abstract selections.

### Promise Paths: Dispatch Is Better, But Continuations Still Cost

Promise-backed execution improved structurally, but prebuilt-AST promise cases
still do not win because:

- promise continuations are still modeled in Perl-visible callback style
- completion still performs promise-specific branching late
- error wrapping and continuation chaining are now more XS-backed, but not yet
  fully internal to the XS execution core

The current promise design is compatibility-correct and adapter-friendly, but it
is not yet a deeply optimized execution model.

## Whole-System Optimization Directions

If the goal is whole-system optimization rather than another isolated micro-opt,
the most important directions are:

1. Move completion continuations deeper into XS.
   Focus on the promise continuation points in `_complete_value*`, so promise
   handling stops bouncing through Perl callbacks for common success/error paths.

2. Push abstract selection handling further away from PP fallback.
   The remaining cost in `abstract_with_fragment` strongly suggests that abstract
   completion and fragment-condition handling should keep moving inward.

3. Cache more execution-shape metadata in the prepared context.
   `ResolveInfo` base caching helped, but the same approach can be extended to
   field-definition lookup and other repeated per-field metadata access.

4. Reduce tiny-result framing for flat leaf selections.
   `simple_scalar` shows that tiny compatibility wrappers still matter. Any
   reduction in leaf-only field framing is likely to pay off.

5. Keep promise hooks adapter-based, but make the execution core treat them as
   pre-resolved function pointers.
   The public API should stay flexible, but the hot path should not repeatedly
   rediscover hook structure.

6. Benchmark by workload family, not only globally.
   The current data already shows that "execution performance" is really several
   different problems: flat leaf queries, nested object queries, abstract
   selections, and promise-backed execution need different optimizations.
