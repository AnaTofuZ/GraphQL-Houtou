# Current Context

Compressed handoff for the current `GraphQL::Houtou` worktree.

## Snapshot

- Main compatibility work stays on `main`.
- IR-direct execution work stays on `ir-direct-execution` only.
- Public parser / AST APIs are unchanged.
- graphql-perl-compatible AST execution remains the compatibility boundary.
- compiled-IR hot paths may diverge from AST/legacy code if that removes
  measurable bridge overhead.
- internal execution APIs may be changed destructively when needed.
- any user-visible compatibility tradeoff must be reviewed first and then
  documented before landing.
- compiled-IR-only code duplication is acceptable when comments identify the
  corresponding AST/legacy path and measurement shows the bridge cost matters.
- Current strategy has two parallel tracks:
  - query-side compiled execution plans
  - schema/runtime caches that also help AST execution

## Recent IR Branch Commits

- `f950c6d` Add initial prepared IR execution path
- `e1bcd5f` Add compiled IR execution plans
- `161c828` Cache nested metadata in compiled IR plans
- `5c9eeb5` Warm schema runtime caches for execution
- `a030daf` Use runtime schema caches in Perl abstract paths
- `45d816a` Reuse compiled nested field buckets
- `b2ccbac` Cache schema field maps for execution lookups
- `b35320d` Fold simple inline fragments into compiled buckets
- `690ffb8` Reuse compiled fragment buckets in nested selections
- `42a9d9f` Cache runtime schema lookups in execution contexts
- `646c10f` Use execution runtime caches in Perl abstract paths
- `6d7c2af` Attach compiled field defs to nested IR nodes
- `e7c04b8` Attach compiled field defs to fragment plans
- `c42263f` Use runtime caches in abstract fragment matching
- `0685c33` Precompute possible type maps in runtime cache
- `ec98231` Reduce retained legacy state in compiled IR
- `2bbee63` Store compiled IR root plans natively
- `c2f8742` Lazy-load compiled IR root selection plans
- `e817212` Use native tables for abstract child plans
- `5608d70` Use native tables for concrete subfields
- `e99c79e` Prefer native tables for compiled field buckets
- `edf499a` Strip legacy buckets from compiled root nodes
- `0918e04` Strip legacy buckets from compiled fragments
- `de6e3da` Cache hot execution context lookups
- `61eae3c` Lazy-load resolve info in field completion
- `3e98dc6` Run native abstract child field plans directly

## Current Execution State

### Shared XS execution core

Already XS-owned:

- AST coercion
- fragment map build
- operation selection
- field execution loop
- resolve info construction
- final response merge
- resolver invocation and error coercion
- simple / variable argument coercion fast paths
- built-in scalar fast paths
- enum fast paths
- common object/list/abstract completion fast paths
- promise dispatch / merge / response shaping

Still PP fallback:

- full argument coercion fallback
- complex object/list completion fallback

### IR direct execution

Available internal APIs:

- `_prepare_executable_ir_xs($source)`
- `_compile_executable_ir_plan_xs($schema, $prepared, $operation_name = undef)`
- `execute_prepared_ir_xs(...)`
- `execute_compiled_ir_xs(...)`

Current compiled plan caches:

- selected operation metadata
- root type
- root selection plan
- native root field plan entries
- nested selection metadata under root plans
- nested `compiled_fields` for simple reusable buckets
- nested/root `compiled_field_def`
- fragment child nodes can also carry `compiled_field_def`
- abstract child direct plans can also be retained in native node-attached
  lookup tables
- plain `compiled_fields` buckets on compiled nodes/fragments can also be
  mirrored into native bucket tables for direct merge paths

Legacy compatibility structures still exist, but the current direction is to
stop treating them as the canonical compiled form:

- `operation`
- `fragments`
- `root_fields`

Those are increasingly being treated as lazy materializations rather than
retained compiled state.

Additional note:

- root field plans are now retained primarily as native C entries and only
  materialized back to legacy `HV`/`AV` form on demand

Current compiled-plan execution reuse:

- root-level `field_def` lookup is short-circuited from compiled metadata
- plain nested field selections can carry `compiled_fields`
- `collect_simple_object_fields()` now reuses those nested compiled buckets
- simple inline fragments can be folded into compiled buckets
- nested fragment buckets can now be reused as well
- simple abstract single-node child execution can now use direct compiled field
  plans instead of rebuilding legacy field buckets first
- simple abstract single-node child execution can now prefer native compiled
  field plans and run them directly without going back through legacy
  `field_plan_sv` execution
- compiled abstract child direct-plan lookup now prefers native node-attached
  tables keyed by runtime object identity
- compiled field-bucket merges can also prefer native node/fragment-attached
  bucket tables before falling back to legacy `compiled_fields`
- hot execution-context members are now cached behind a context-attached magic
  struct so repeated `hv_fetch` calls are reduced in `resolve_info`,
  `execute_fields`, field-plan execution, and compiled-root execution
- per-field `path` materialization is now also deferred so compiled/object field
  execution does not eagerly allocate Perl path objects on the happy path

This means compiled IR is already faster than prepared IR and is now beating
`houtou_xs_ast` in several nested cases.

Current strategic conclusion:

- low-risk AST-path tuning still has some value
- abstract/fragment-heavy AST optimization now shows diminishing returns
- larger wins are more likely to come from compiled-IR-native execution than
  from adding more AST-compatible special cases
- if AST compatibility is not required, prefer multi-stage IR compilation over
  further incremental AST-path complexity
- reducing retained Perl-object state in prepared / compiled IR is now a
  first-class optimization target, not just a cleanup task

## Runtime Schema Cache

`GraphQL::Houtou::Schema` now has:

- `prepare_runtime`
- `runtime_cache`
- `clear_runtime_cache`

Current runtime cache contents:

- `root_types`
- `name2type`
- `interface2types`
- `possible_type_map`
- `possible_types`
- `field_maps`

Current runtime cache consumers:

- XS root type lookup
- XS abstract default path
- XS `get_field_def`
- XS execution context runtime cache lookups
- Perl `Object::_fragment_condition_match`
- Perl `Interface::_ensure_valid_runtime_type`

This is the current main path for "global" optimization that also improves
AST execution, not only IR execution.

Additional cached runtime data now also includes:

- `resolve_type_map`
- `is_type_of_map`

## Benchmark Direction

Known shape of results after latest landed work:

- `compiled_ir` > `prepared_ir`
- `compiled_ir` > `houtou_xs_ast` on nested object cases
- `compiled_ir` ~= `houtou_xs_ast` on abstract/fragment-heavy cases
- `compiled_ir` can now edge past `houtou_xs_ast` on
  `abstract_with_fragment` in favorable runs, but the margin is still small
- `compiled_ir` now has direct fast paths for trivial default-field resolution
  and `__typename` meta fields, so more child fields avoid allocating
  `resolve_info` / `path` objects in the happy path
- `compiled_ir` now carries lazy per-field resolve-info state through
  completion, so non-resolver object/list/abstract completion can defer
  `resolve_info` materialization until a callback or PP fallback actually needs
  it
- runtime-cache work targets AST and IR paths simultaneously
- abstract/fragment-heavy tuning on AST paths is now close to a diminishing
  returns region
- native root-plan retention does not regress `abstract_with_fragment` and
  pushes `nested_variable_object` further ahead of `houtou_xs_ast`

Current sampled numbers (`util/execution-benchmark.pl --count=-3`):

- `simple_scalar`
  - `houtou_prepared_ir`: `129787/s`
  - `houtou_compiled_ir`: `145878/s`
  - `houtou_xs_ast`: `141723/s`
- `nested_variable_object`
  - `houtou_prepared_ir`: `68776/s`
  - `houtou_compiled_ir`: `81177/s`
  - `houtou_xs_ast`: `79130/s`
- `list_of_objects`
  - `houtou_prepared_ir`: `54119/s`
  - `houtou_compiled_ir`: `57982/s`
  - `houtou_xs_ast`: `58298/s`
- `abstract_with_fragment`
  - `houtou_prepared_ir`: `38128/s`
  - `houtou_compiled_ir`: `41647/s`
  - `houtou_xs_ast`: `42173/s`
- `async_scalar`
  - `houtou_prepared_ir`: `77551/s`
  - `houtou_compiled_ir`: `78884/s`
  - `houtou_facade_ast`: `79696/s`
- `async_list`
  - `houtou_prepared_ir`: `44283/s`
  - `houtou_compiled_ir`: `44797/s`
  - `houtou_facade_ast`: `44655/s`

More recent spot checks after native child-plan/native bucket/context-cache
work:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `83039/s`
  - `houtou_xs_ast`: `79643/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `43320/s`
  - `houtou_xs_ast`: `43114/s`

Latest spot check after lazy `resolve_info` materialization in field
completion (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `81662/s`
  - `houtou_xs_ast`: `78695/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `43114/s`
  - `houtou_xs_ast`: `42775/s`

Latest spot check after lazy `path` materialization and direct native abstract
child field-plan execution (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `85187/s`
  - `houtou_xs_ast`: `82525/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45420/s`
  - `houtou_xs_ast`: `44940/s`

Latest spot check after caching `type` / `resolve` / field-arg metadata on
native field-plan entries (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `86706/s`
  - `houtou_xs_ast`: `83544/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `43626/s`
  - `houtou_xs_ast`: `43626/s`

Latest spot check after dropping eager retained root-plan `path` objects
(`--count=-6`):

- `abstract_with_fragment`
  - `houtou_compiled_ir`: `46264/s`
  - `houtou_xs_ast`: `45096/s`

Latest spot check after treating compiled-IR root `path` as implicit `undef`
until fallback (`--count=-6`):

- `abstract_with_fragment`
  - `houtou_compiled_ir`: `42791/s`
  - `houtou_xs_ast`: `43067/s`

Latest spot check after caching the first field node on native plan entries
(`--count=-6`):

- `abstract_with_fragment`
  - `houtou_compiled_ir`: `44167/s`
  - `houtou_xs_ast`: `43720/s`

Latest spot check after caching trivial-completion metadata on native plan
entries (`--count=-6`):

- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45278/s`
  - `houtou_xs_ast`: `44392/s`

Latest spot check after sync native executors flatten completed field envelopes
directly into result data/errors (`--count=-6`):

- `abstract_with_fragment`
  - `houtou_compiled_ir`: `44478/s`
  - `houtou_xs_ast`: `43694/s`

Latest spot check after native sync executors bypass trivial response-envelope
allocation for `__typename` and leaf fast paths (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `85615/s`
  - `houtou_xs_ast`: `83240/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45727/s`
  - `houtou_xs_ast`: `45420/s`

Interpretation:

- the current compiled-IR direction is still valid
- lazy `resolve_info` materialization is a better fit than adding more
  AST-compatible special cases, because it removes Perl `HV` allocation from
  both nested-object and abstract completion hot paths
- lazy `path` materialization pairs well with lazy `resolve_info`, because
  it removes another per-field Perl allocation that used to survive even after
  resolver fast paths were added
- direct native abstract child field-plan execution is the first step that
  removes part of the remaining `field_plan_sv` / legacy execution bridge from
  the `abstract_with_fragment` hot path
- native field-plan entries now cache `type`, `resolve`, and field-argument
  metadata, which reduces repeated `HV` inspection in both compiled root and
  abstract-child execution
- native root plans no longer need to retain eager per-field Perl `path`
  objects; legacy `path` arrays are synthesized only when compatibility code
  asks for them
- compiled-IR root execution now treats the root path as implicit until a
  fallback path actually needs a Perl array; this is a small simplification and
  allocation reduction, but measurement impact is modest
- native field-plan entries now also cache the first field node, which trims a
  small amount of `AV` traversal and node-shape checking on argument-heavy
  paths without adding much complexity
- native field-plan entries now also cache trivial-completion metadata so leaf
  field fast paths do not need to rediscover non-null/leaf structure on every
  execution
- sync compiled-IR executors now flatten completed field envelopes directly
  into result `data` / `errors` instead of always retaining per-field response
  hashes until the final merge step
- sync compiled-IR executors now also bypass per-field `{ data => ... }`
  response-envelope allocation for trivial `__typename`, nullable-null, and
  leaf fast paths; the native executor writes serialized values straight into
  the final response hash and only falls back to legacy completion when GraphQL
  semantics actually require it
- compiled-IR native executors now also use a borrowed default-field fast path
  before falling back to `share_or_copy_sv()`, which trims another allocation
  out of trivial hash-property reads such as `id` / `name`
- `abstract_with_fragment` is still close enough to `houtou_xs_ast` that the
  remaining gap should be attacked by eliminating more Perl-object allocation,
  not by adding more AST-compatible branching
- further wins should come from removing more runtime Perl-object work, not
  from micro-tuning legacy bucket reshaping

## Testing Rule

Primary verification workflow:

1. `minil test`

Use `./Build build` only when benchmark / profiling utilities need repo-root
`blib`.

## Next IR Direction

If the next optimization round targets raw performance rather than AST
compatibility, the preferred order is:

1. make `compiled_ir` execute native field plans instead of `root_fields_sv`
2. stop retaining eager legacy `operation` / `fragments` / `root_fields`
   objects inside compiled plans unless compatibility requires them
3. replace hot-path Perl execution-context hashes with IR-native structs where
   practical
4. compile abstract fields into per-concrete-type child execution plans
5. lower more arguments/directives at compile time

Concrete interpretation of the current plan:

- compiled handles should prefer native pointers / spans / plan arrays over
  retained `SV` graphs
- plan export / resolve-info compatibility is allowed to materialize legacy
  `SV` structures lazily
- VM work should start from native child/root execution plans, not from more
  `HV`/`AV` reshaping

Practical guidance:

- duplicating the plan runner for compiled IR is acceptable
- duplicating GraphQL semantics, error semantics, or promise semantics is not
  the preferred direction unless measurement forces it

Immediate next candidates for `abstract_with_fragment`:

1. replace more child-execution `HV/AV` plan state with native tables/arrays
   so abstract child execution no longer needs legacy bucket materialization at
   all
2. move path handling for compiled child plans from lazy Perl materialization
   toward native path segments or precompiled path templates
3. replace more compiled-IR execution-context / resolve-info state with native
   structs so the remaining hot-path `HV` traffic is minimized

## Promise::XS Experiment Note

A separate experiment branch (`promise-xs-fastpath`) tested a dedicated
`Promise::XS` backend.

Conclusion:

- do not merge the dedicated backend as-is
- real `Promise::XS` with public-API specialization was effectively tied with
  the existing generic hook path
- the remaining async overhead is in promise continuation / merge work, not in
  adapter dispatch alone

Measured with real `Promise::XS` installed locally and repo-root `blib`:

- `async_scalar`
  - generic hook: `81683/s`
  - dedicated `promise_xs`: `81704/s`
- `async_list`
  - generic hook: `40883/s`
  - dedicated `promise_xs`: `40758/s`

So the recommended direction remains:

- keep the generic promise-hook contract
- optimize continuation / merge internals instead of adding a Promise::XS-only
  execution mode

Latest verification:

- `minil test`
- `13 files / 189 tests / PASS`

## Coding Rule

When creating a temporary `SV` and passing it into another helper, the caller
owns that temporary unless ownership transfer is explicitly documented.

Perl API ownership model:

- track ownership, not just raw refcounts
- a temporary pushed only for stack/lifetime purposes should normally be made
  mortal with `sv_2mortal(...)`
- do not mortalize the same owned reference twice
- when embedding a freshly-created referent into an RV/container, prefer the
  `_noinc` form if ownership is being transferred rather than shared
- prefer APIs like `hv_store(...)` when the key is not already an `SV`, because
  they avoid creating temporary key SVs in the first place

Practical rule:

- `newSVsv(...)`
- `newSVpvf(...)`
- `newRV_noinc(...)`

If these are created only for a helper call, the call site must decide whether
to `SvREFCNT_dec(...)` afterward.

The same applies to temporary key SVs used with hash helpers.

- `hv_store_ent(...)` does not consume the key SV
- `hv_store_ent(...)` takes ownership of one reference to `val` on success, but
  not of `key`
- `hv_fetch_ent(...)` does not transfer ownership of a temporary key SV
- `hv_iterkeysv(...)` returns a mortal copy; treat it as borrowed temporary data

Practical rule:

- if a temporary key SV is created only to call `hv_store_ent(...)`, the call
  site must `SvREFCNT_dec(...)` it afterward unless the SV was made mortal
- avoid inline patterns like `hv_store_ent(hv, newSVsv(...), ...)` because they
  hide ownership and make leaks easy to miss; bind the temporary key SV to a
  local variable, call `hv_store_ent(...)`, then `SvREFCNT_dec(...)`
- treat the same ownership rule as applying to all same-shape patterns where a
  temporary SV is created solely to serve as a lookup/store key
- use `util/lint-xs-ownership.pl` before landing ownership-related XS changes;
  it checks for the most common inline temporary-key and nested-mortal patterns

## Next Step

Keep pushing compiled-plan reuse deeper without creating a second executor.

Best next move:

- push compiled-plan reuse deeper into nested execution
- keep improving runtime schema snapshots so AST and IR paths both benefit
- focus next on abstract/concrete subtree reuse rather than fragment caching
  alone

## Breaking-API Speed Notes

If public compatibility constraints were relaxed, the highest-probability extra
speed wins would likely be:

- execute against a frozen XS/runtime schema snapshot instead of Moo/Type::Tiny
  objects
- expose a prepared/compiled query handle whose variable/default coercion is
  prevalidated against that runtime schema
- allow an execution-only node/selection shape instead of graphql-perl
  compatibility hashes for resolve info, field nodes, and fragment maps
