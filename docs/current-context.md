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
- native root and child executors now share a single "execute one field entry"
  helper plus explicit native execution env/accumulator structs, so the hot
  loop is closer to a VM-style dispatch over field ops than to duplicated
  root/child Perl-bridge code
- native field plan entries now also carry an explicit dispatch kind
  (`typename` / explicit resolver / inherited resolver / generic), so a future
  opcode executor can map field-plan entries to a smaller dispatch table
  without first re-deriving resolver shape from legacy Perl objects
- native field execution is now further split into helper-sized phases
  (`meta dispatch`, `resolver selection`, `resolver call`), so upcoming opcode
  lowering can move one phase at a time without re-cutting the main field loop
- native field plan entries now also carry completion dispatch kind, so
  trivial completion and generic completion are explicit operands on the plan
  rather than implicit branches rediscovered inside the field executor
- the field-entry executor now uses that completion dispatch kind through a
  dedicated trivial-completion helper, which further separates "resolve" from
  "complete" work in a VM-friendly way
- field execution is now also explicitly split into `complete` and `consume`
  helper phases after resolution, so the current native executor already
  resembles a fixed `resolve -> complete -> consume` pipeline
- that field-stage pipeline is now dispatched through a VM-friendly stage
  dispatcher as well: on GCC/Clang the executor uses computed-goto based
  direct threading, while other compilers use a matching `switch` fallback
  over the same explicit stage enum
- native field entries now also own the operands needed by the field-stage
  dispatcher; root execution lazily fills missing `nodes` / `field_def` /
  `type` once and then reuses the entry as a self-contained field-op record
- the field-op record is now further normalized into separate native enum
  operands for `meta`, `resolve`, `args`, and `completion`, which reduces
  runtime shape rediscovery from Perl objects and is closer to a future opcode
  stream
- field execution control flow is now also owned by the compiled plan entry:
  each native field entry carries a fixed op array, and the executor dispatches
  over that array rather than over a hard-coded internal stage enum

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

Most recent VM-shaping refactor checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77972/s`
  - `houtou_xs_ast`: `73397/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41351/s`
  - `houtou_xs_ast`: `39919/s`

Most recent dispatch-kind shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77825/s`
  - `houtou_xs_ast`: `74591/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `42308/s`
  - `houtou_xs_ast`: `41714/s`

Most recent helper-splitting checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77379/s`
  - `houtou_xs_ast`: `74513/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41954/s`
  - `houtou_xs_ast`: `41813/s`

Most recent completion-dispatch shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `78245/s`
  - `houtou_xs_ast`: `74854/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41518/s`
  - `houtou_xs_ast`: `40766/s`

Most recent completion-op shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `78245/s`
  - `houtou_xs_ast`: `74854/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41518/s`
  - `houtou_xs_ast`: `40766/s`

Most recent complete/consume shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `80397/s`
  - `houtou_xs_ast`: `76095/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `42809/s`
  - `houtou_xs_ast`: `41565/s`

Most recent direct-threaded stage-dispatch checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `79109/s`
  - `houtou_xs_ast`: `78887/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `42048/s`
  - `houtou_xs_ast`: `42507/s`

Most recent operand-on-entry shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `80842/s`
  - `houtou_xs_ast`: `79853/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41751/s`
  - `houtou_xs_ast`: `42729/s`

Most recent enum-operand shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77433/s`
  - `houtou_xs_ast`: `76554/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41751/s`
  - `houtou_xs_ast`: `42210/s`

Most recent fixed-op-array shaping checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77008/s`
  - `houtou_xs_ast`: `75037/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `42629/s`
  - `houtou_xs_ast`: `42430/s`

Most recent shared native field-loop checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `76463/s`
  - `houtou_xs_ast`: `76023/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41248/s`
  - `houtou_xs_ast`: `42313/s`

Interpretation:

- this change is VM-readiness work, not a direct throughput play
- root compiled plans and native child plans now share the same field-plan loop
- the main remaining difference is whether root execution must lazily fill
  runtime operands (`nodes` / `field_def` / `type`) before dispatch
- the next structural step should keep shrinking that distinction so field
  execution can be treated as one native op runner regardless of root vs child

Most recent self-contained root-plan checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77094/s`
  - `houtou_xs_ast`: `77754/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41324/s`
  - `houtou_xs_ast`: `42210/s`

Interpretation:

- root compiled plans now carry a plan-level `requires_runtime_operand_fill`
  flag
- when a compiled root plan is already self-contained, the shared native
  field-plan loop no longer pays the per-entry "do I need lazy operand fill?"
  branch
- this is still primarily VM-readiness work: the hot loop is closer to "run the
  plan as-is" and less tied to execution-time frontend reconstruction

Most recent abstract direct-consume checks:

- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir`: `77433/s`
  - `houtou_xs_ast`: `74953/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir`: `41917/s`
  - `houtou_xs_ast`: `41917/s`

Interpretation:

- sync abstract completion can now execute a native child field plan directly
  into the parent accumulator
- that removes one `completed` result `HV` build/consume round-trip from the
  native abstract path
- this is still only a first step toward the larger goal; `abstract` execution
  is not yet staying native all the way through completion/error handling

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

Latest spot check after caching native field `return_type` metadata and passing
it directly into XS completion (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `85289/s`
  - `houtou_xs_ast`: `79906/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `46116/s`
  - `houtou_xs_ast`: `44237/s`

Latest spot check after lazy `resolve_info` started reusing cached
`field_name` / `return_type` metadata instead of re-reading them from
`nodes[0]` and `field_def` (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `83503/s`
  - `houtou_xs_ast`: `78825/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45229/s`
  - `houtou_xs_ast`: `43058/s`

Latest spot check after making native executor error arrays lazy so success
paths do not allocate `errors` storage unless a child completion actually
produces one (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `86658/s`
  - `houtou_xs_ast`: `82311/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `43286/s`
  - `houtou_xs_ast`: `42112/s`
- `async_scalar`
  - `houtou_compiled_ir`: `79906/s`
  - `houtou_facade_ast`: `79379/s`

Latest spot check after adding a compiled-IR-only sync fast path that consumes
abstract root-field native child plans directly back into the parent result
writer instead of round-tripping them through a field-level envelope
(`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `81660/s`
  - `houtou_xs_ast`: `77825/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45366/s`
  - `houtou_xs_ast`: `43484/s`

Latest spot check after extending that same direct-consume abstract fast path
to compiled native child execution as well, so sync abstract child fields can
reuse native concrete child plans without building a completed field envelope
first (`--count=-6`):

- `nested_variable_object`
  - `houtou_compiled_ir`: `84883/s`
  - `houtou_xs_ast`: `82197/s`
- `abstract_with_fragment`
  - `houtou_compiled_ir`: `45635/s`
  - `houtou_xs_ast`: `44812/s`

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
- that direct-consume path now exists for both root and child compiled-native
  execution, so sync abstract fields can stay inside the native writer path
  for longer before falling back to legacy completion
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
- compiled-IR promise executors now keep already-resolved trivial/native fields
  in direct `data` accumulation while only promise-bearing fields flow through
  `Promise::Adapter::all`; the final merge helper recombines the sync head with
  the async tail instead of forcing everything back through per-field envelopes
- the promise-tail recombination step is now also in XS: Perl still owns the
  `then_promise(...)` control flow, but `_then_merge_hash_with_head_xs` no
  longer rebuilds hashes in Perl after fulfillment
- native field-plan entries now also cache `return_type`, so XS completion no
  longer needs to rediscover `field_def->{type}` on the hot path when compiled
  root/native child executors already know the answer
- lazy `resolve_info` materialization now also reuses cached `field_name` and
  `return_type` metadata, so building the Perl info hash no longer has to read
  `nodes[0]{name}` and `field_def->{type}` again once the native executor has
  already identified the field
- native root/child executors now keep `errors` arrays lazy as well; sync and
  promise paths only allocate Perl `AV`s for errors when a child completion
  actually returns them, instead of paying that cost unconditionally
- compiled-IR sync root execution now also has an abstract-field fast path that
  recognizes `runtime type -> native child plan` and feeds the child result
  straight back into the parent writer, which is the first concrete step toward
  a true native abstract executor instead of a field-level completion envelope
- `abstract_with_fragment` is still close enough to `houtou_xs_ast` that the
  remaining gap should be attacked by eliminating more Perl-object allocation,
  not by adding more AST-compatible branching
- further wins should come from removing more runtime Perl-object work, not
  from micro-tuning legacy bucket reshaping

Latest promise-path spot checks after preserving sync native head fields during
compiled-IR promise merges (`--count=-6`):

- `async_scalar`
  - `houtou_compiled_ir`: `81920/s`
- `async_list`
  - `houtou_compiled_ir`: `46265/s`

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

Keep pushing compiled-native execution toward an envelope-less happy path.

Best next move:

- keep specializing compiled-native field ops so plan entries own more of the
  runtime branch structure; the current fixed op arrays now split resolver calls
  into `FIXED/CONTEXT x EMPTY/BUILD_ARGS`, which is the first useful step
  toward true opcode execution
- let compiled-native child execution write successful object/list completions
  into parent result state without first materializing `{ data, errors }`
- keep shrinking `resolve_info`, error, and path materialization in success
  paths so abstract/native child execution stays out of legacy completion
  helpers longer
- continue moving compiled child metadata from Perl `HV` / `AV` state into
  native plan entries and node-attached tables
- keep the native executor's terminal materialization in one shared helper so
  root/native-child execution already has a stable post-VM boundary
- keep execution-frame setup shared as well; root/native-child now initialize
  the same native env/accumulator shape before entering the field-op loop
- keep promise-pending field state in native arrays until the final merge step;
  `result_keys_av` / `result_values_av` no longer need to exist on the hot path
  before a promise actually appears

Latest spot verification after specializing native field call ops:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 80200/s`
  - `houtou_xs_ast 76740/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 41724/s`
  - `houtou_xs_ast 41616/s`

Interpretation:

- the resolver-op specialization is mainly a VM-readiness change, not a large
  speed win by itself
- `nested_variable_object` stays comfortably ahead, while
  `abstract_with_fragment` remains essentially tied
- this is consistent with the current model: dispatch is getting cheaper, but
  completion, Perl callback boundaries, and legacy bridge points still dominate
  the abstract hot path

After that, completion dispatch was also specialized in the fixed op array:

- `COMPLETE_TRIVIAL`
- `COMPLETE_GENERIC`

Latest spot verification after completion-op specialization:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 79824/s`
  - `houtou_xs_ast 77457/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 41421/s`
  - `houtou_xs_ast 41125/s`

Interpretation:

- splitting completion into explicit op kinds is also primarily a VM-readiness
  change
- the runtime remains neutral-to-slightly-positive while more branch structure
  moves from execution helpers into the compiled native plan

Latest spot verification after moving per-field execution state into a native
field frame struct:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 82267/s`
  - `houtou_xs_ast 78569/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42308/s`
  - `houtou_xs_ast 41714/s`

Interpretation:

- the hot-loop field state is now carried in one native frame struct instead of
  a loose set of local Perl-facing temporaries
- this is primarily VM-readiness work: `resolve`, `complete`, and `consume`
  now operate over a more self-contained native execution state
- the change is neutral-to-positive on both spot cases, so it is a good
  foundation for moving more completion/error work out of ad hoc `SV *`
  temporaries and into native outcome structs

## Breaking-API Speed Notes

If public compatibility constraints were relaxed, the highest-probability extra
speed wins would likely be:

- execute against a frozen XS/runtime schema snapshot instead of Moo/Type::Tiny
  objects
- expose a prepared/compiled query handle whose variable/default coercion is
  prevalidated against that runtime schema
- allow an execution-only node/selection shape instead of graphql-perl
  compatibility hashes for resolve info, field nodes, and fragment maps
