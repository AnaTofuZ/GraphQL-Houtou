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

- `upstream_string`: `5009/s`
- `houtou_facade_string`: `37118/s`
- `houtou_xs_string`: `37716/s`
- `houtou_facade_ast`: `39565/s`
- `houtou_xs_ast`: `40328/s`
- `upstream_ast`: `42991/s`

Observations:

- Houtou is much faster for end-to-end string execution.
- Upstream still wins when AST is already available and the query is flat.

### nested_variable_object

Query:

```graphql
query q($id: ID!) { user(id: $id) { id name } }
```

Rates:

- `upstream_string`: `3170/s`
- `houtou_facade_string`: `26314/s`
- `houtou_xs_string`: `26625/s`
- `upstream_ast`: `25497/s`
- `houtou_facade_ast`: `27722/s`
- `houtou_xs_ast`: `27825/s`

Observations:

- Houtou is far ahead on source-string execution.
- For nested object execution with variable coercion, Houtou XS also edges out upstream AST.

### list_of_objects

Query:

```graphql
{ users { id name } }
```

Rates:

- `upstream_string`: `3974/s`
- `upstream_ast`: `18095/s`
- `houtou_facade_string`: `19243/s`
- `houtou_xs_string`: `19611/s`
- `houtou_facade_ast`: `19756/s`
- `houtou_xs_ast`: `20032/s`

Observations:

- Houtou is again much faster on string execution.
- On AST execution, Houtou is slightly ahead in this list-of-objects case.

### abstract_with_fragment

Query:

```graphql
{ searchResult { __typename ... on User { id name } } }
```

Rates:

- `upstream_string`: `3081/s`
- `houtou_facade_string`: `18095/s`
- `houtou_xs_string`: `18466/s`
- `houtou_facade_ast`: `18794/s`
- `houtou_xs_ast`: `19079/s`
- `upstream_ast`: `23801/s`

Observations:

- Houtou still dominates source-string execution.
- Upstream remains stronger when AST is already materialized and abstract-type work is involved.

### async_scalar

Query:

```graphql
{ asyncHello }
```

Rates:

- `upstream_string`: `7062/s`
- `houtou_facade_string`: `29281/s`
- `houtou_facade_ast`: `31220/s`
- `upstream_ast`: `42593/s`

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

## Updated Performance Read

After the recent execution work, the benchmark picture is now more polarized:

- `simple_scalar` on prebuilt AST is close, but upstream still leads by a small margin.
- `nested_variable_object` and `list_of_objects` now favor Houtou even on prebuilt AST.
- `abstract_with_fragment` still leaves a larger gap on prebuilt AST.
- `async_scalar` remains the weakest area for Houtou when AST is already available.

This suggests that Houtou is no longer broadly "slow on AST execution". Instead,
the remaining gaps are concentrated in two kinds of workloads:

1. very flat queries where fixed overhead dominates
2. promise-heavy or abstract-type-heavy queries where more work still falls back
   through Perl continuations and object-heavy compatibility structures

## Why The Remaining Gaps Exist

### Flat AST Queries: Fixed Overhead Still Matters

`simple_scalar` is now much closer than before, but it still pays for:

- `ResolveInfo` and path object construction
- field-definition lookup and dispatch glue
- leaf-field completion framing even when the field body is trivial
- compatibility-shape result objects and error/result wrappers

Those costs are small individually, but on a two-field flat query they dominate.

### Abstract Fragments: Compatibility Shape Still Costs

`abstract_with_fragment` remains slower mainly because the compatibility path
still materializes and checks more Perl-visible structure than upstream in the
already-parsed-AST case:

- abstract runtime type resolution still crosses compatibility layers
- fragment condition checks still require more shape adaptation than the simplest
  object/list paths
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
