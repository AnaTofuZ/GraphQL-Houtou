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

- `upstream_string`: `4902/s`
- `upstream_ast`: `41261/s`
- `houtou_facade_string`: `115904/s`
- `houtou_xs_string`: `122504/s`
- `houtou_prepared_ir`: `126079/s`
- `houtou_facade_ast`: `129465/s`
- `houtou_compiled_ir`: `139515/s`
- `houtou_xs_ast`: `139565/s`

Observations:

- Houtou is much faster for source-string, prepared-IR, compiled-IR, and
  prebuilt-AST execution.
- `compiled_ir` is now effectively tied with `houtou_xs_ast` on this flat case.
- The flat-query fixed overhead work that previously hurt `simple_scalar` is no
  longer a bottleneck.

### nested_variable_object

Query:

```graphql
query q($id: ID!) { user(id: $id) { id name } }
```

Rates:

- `upstream_string`: `3078/s`
- `upstream_ast`: `25041/s`
- `houtou_facade_string`: `64804/s`
- `houtou_xs_string`: `67684/s`
- `houtou_prepared_ir`: `66566/s`
- `houtou_facade_ast`: `74011/s`
- `houtou_xs_ast`: `77441/s`
- `houtou_compiled_ir`: `79130/s`

Observations:

- Houtou is far ahead on source-string execution.
- `compiled_ir` now clearly beats both upstream AST and `houtou_xs_ast`.
- The win here is the clearest sign that compiled execution-plan reuse is
  paying off for nested object execution.

### list_of_objects

Query:

```graphql
{ users { id name } }
```

Rates:

- `upstream_string`: `3901/s`
- `upstream_ast`: `17816/s`
- `houtou_facade_string`: `53315/s`
- `houtou_xs_string`: `55083/s`
- `houtou_prepared_ir`: `54287/s`
- `houtou_facade_ast`: `57273/s`
- `houtou_compiled_ir`: `57941/s`
- `houtou_xs_ast`: `58659/s`

Observations:

- Houtou is again much faster on string execution.
- `compiled_ir` improves on `prepared_ir`, but `houtou_xs_ast` is still slightly
  ahead on this case.
- This suggests that list-heavy execution still leaves some nested front-end
  work on the compiled path.

### abstract_with_fragment

Query:

```graphql
{ searchResult { __typename ... on User { id name } } }
```

Rates:

- `upstream_string`: `3031/s`
- `upstream_ast`: `23641/s`
- `houtou_facade_string`: `37547/s`
- `houtou_xs_string`: `38397/s`
- `houtou_prepared_ir`: `40215/s`
- `houtou_facade_ast`: `40588/s`
- `houtou_compiled_ir`: `41647/s`
- `houtou_xs_ast`: `41687/s`

Observations:

- Houtou still dominates source-string execution.
- `compiled_ir` and `houtou_xs_ast` are now effectively tied here.
- The remaining cost is no longer basic fragment caching; it is mostly the
  dynamic runtime-type and abstract-condition work that still has to happen at
  execution time.

### async_scalar

Query:

```graphql
{ asyncHello }
```

Rates:

- `upstream_string`: `6776/s`
- `upstream_ast`: `41389/s`
- `houtou_facade_string`: `74256/s`
- `houtou_prepared_ir`: `74244/s`
- `houtou_compiled_ir`: `77535/s`
- `houtou_facade_ast`: `78946/s`

Observations:

- Promise-backed execution remains strongly XS-backed through the public facade.
- `compiled_ir` is ahead of `prepared_ir`, but `houtou_facade_ast` is still
  slightly ahead here.
- This points to remaining plan reuse opportunities in promise-aware execution,
  not to a parser bottleneck.

### async_list

Query:

```graphql
{ asyncList }
```

Rates:

- `upstream_string`: `6014/s`
- `upstream_ast`: `26131/s`
- `houtou_facade_string`: `42202/s`
- `houtou_prepared_ir`: `42601/s`
- `houtou_facade_ast`: `43260/s`
- `houtou_compiled_ir`: `43671/s`

Observations:

- Promise-backed list execution also now beats upstream on both string and AST
  paths.
- `compiled_ir` is modestly ahead of `prepared_ir` and `houtou_facade_ast`.
- This case improved materially once prepared execution, field merge, and leaf
  completion stopped crossing the PP bridge.

## Summary

Current takeaways:

- `GraphQL::Houtou` is now strong for practical source-string execution,
  prebuilt-AST execution, and the new prepared/compiled IR execution paths.
- `compiled_ir` consistently improves on `prepared_ir`.
- `compiled_ir` is already best on some nested cases, but still only tied with
  `houtou_xs_ast` on abstract/fragment-heavy execution.
- Promise-backed execution is no longer just a compatibility path in this
  benchmark set; it is now a performance win area too.

In short:

- parser + execute together: Houtou is much faster
- execute on prebuilt AST: Houtou wins across the benchmarked cases here
- prepared/compiled IR: already worthwhile, with compiled plans giving a clear
  benefit over prepared IR
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

1. Expand compiled plans deeper into nested selection execution, especially
   where `compiled_ir` still trails `houtou_xs_ast`.
2. Push abstract-type and fragment-heavy runtime-type work closer to compiled
   concrete subtrees.
3. Continue reducing compatibility-shape allocation in the AST execution path.
4. Keep moving schema/runtime lookups out of Moo / Type::Tiny / Exporter::Tiny
   hot paths by growing runtime schema snapshots.
5. Extend benchmark coverage to more schema-heavy and mutation-oriented cases.

This is no longer a parser problem. The remaining cost is mostly execution
front-end overhead around abstract selections and schema/runtime dispatch.

### Promise Paths: Dispatch Is Better, But Plan Reuse Still Matters

Promise-backed execution improved structurally, and the public facade now wins
clearly over upstream. The remaining promise work is less about PP bridging and
more about how much plan/runtime reuse can be preserved once promise-aware
execution branches begin.

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
