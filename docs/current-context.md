# Current Context

Compressed handoff for the current `GraphQL::Houtou` worktree.

## April 2026 VM Reset

The active branch for the next phase is `proj/compiled-ir-vm-runtime`.

Recent conclusions that matter more than older commit-by-commit history:

- `compiled_ir` micro-optimizations around `resolve_type` are no longer the
  main focus
- `omit_resolve_type_info` did not produce a meaningful stable win on
  `abstract_with_fragment`
- `sv_does` / `sv_derived_from` / possible-type fast-path experiments also did
  not produce a clean strategic win
- the next profitable direction is a separate execution-lowered runtime for
  `compiled_ir`, not more mixed-mode shortcuts inside the current executor
- `docs/ecosystem-feature-gap.md` is now tracked and must be treated as a
  design constraint for that runtime
- the next concrete design task is to split the current lowered runtime into:
  - an owned lowered program
  - immutable field metadata
  - mutable execution frames
  - a dedicated native result writer
- the first code step in that split is now landed: `lowered_plan` no longer
  conceptually owns only a root field plan, and instead routes through an
  owned `program -> root_block -> field_plan` boundary
- the next code step is also underway: immutable field metadata is now being
  split from mutable field execution state, with the native field frame
  carrying a metadata pointer instead of rediscovering every stable operand
  directly from the entry
- the next code step after that is now landed as well: the native result
  writer has been split out of the execution accumulator so field execution
  can target a writer-owned boundary instead of reaching directly into
  accumulator state
- the latest follow-up step is also landed locally: field execution now
  receives the native writer plus promise-state separately, so `accum` is
  starting to collapse toward execution-level finalization state instead of
  being the hot-path write surface
- sync trivial completion paths now normalize `completed { data, errors }`
  hashes into direct native outcomes before `consume`, which further narrows
  the surface where the writer has to interpret Perl completed envelopes
- sync generic completion now also tries a plain-object native child-plan
  direct path for compiled IR single-node object children before falling back
  to generic completed envelopes
- that plain-object direct path has now been hoisted into
  `gql_execution_complete_value_catching_error_xs_lazy_data_fast(...)`, so the
  compiled-IR generic completion path can reuse a narrower execution helper
  instead of carrying the special case inline
- sync generic completion in `compiled_ir` now also has a compiled-IR-only
  narrow list path: if a list field is sync/no-promise and every item can be
  completed through the existing direct-data helper, the executor now produces
  a direct native list outcome instead of immediately falling back to
  completed-envelope list completion
- sync child-plan execution no longer needs a full `exec_accum` in the
  `*_sync_to_outcome(...)` path; it now runs against `writer + promise_present`
  directly, which is closer to the intended VM/runtime split between hot-path
  writing and execution-level finalization
- VM/runtime work is now also explicitly targeting memory locality:
  native field metadata is no longer a separately allocated heap object per
  entry, and instead lives inline with the compiled field-plan entry so the
  field loop can touch one less pointer-indirection and one less tiny
  allocation/free pair per field
- latest writer-boundary spot measurements remain in-range:
  - `nested_variable_object --count=-3`
    - `houtou_compiled_ir 81517/s`
    - `houtou_xs_ast 81766/s`
  - `list_of_objects --count=-3`
    - `houtou_compiled_ir 62637/s`
    - `houtou_xs_ast 61250/s`
  - `abstract_with_fragment --count=-3`
    - `houtou_compiled_ir 43609/s`
    - `houtou_xs_ast 42897/s`

## Ecosystem Gap Guardrail

`docs/ecosystem-feature-gap.md` is now a tracked planning document and should
be treated as a guardrail for optimization work, not only as a feature-gap
inventory.

Implications for optimization planning:

- compiled-IR / VM work may freely discard internal AST / legacy execution
  shapes, but must not accidentally make high-priority missing features harder
  to add later
- in particular, runtime work should keep a clean insertion point for:
  - mutation serial execution
  - modern introspection data
  - execution `extensions` hooks / middleware-like interception
  - future incremental-delivery / subscription transport boundaries
- performance work that only wins by hard-coding away those insertion points
  is not strategic progress
- when choosing between two similar optimizations, prefer the one that leaves
  room for high-priority ecosystem gaps listed in
  `docs/ecosystem-feature-gap.md`

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

Latest spot verification after moving per-field completion results into a
native outcome state owned by that frame:

- `minil test t/11_execution.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 43017/s`
  - `houtou_xs_ast 42722/s`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 78887/s`
  - `houtou_xs_ast 78010/s`

Interpretation:

- `meta`, `trivial completion`, and generic completion now hand results to
  `consume` through a native outcome kind instead of scattering direct `HV`
  writes and `completed_sv` ownership across multiple helpers
- this is again mainly VM-readiness work, but it also keeps the dispatcher's
  dataflow more regular and does not regress the spot cases

Latest spot verification after routing sync abstract-native child completion
through the same frame outcome/consume boundary:

- `minil test t/11_execution.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42430/s`
  - `houtou_xs_ast 42619/s`

Interpretation:

- sync abstract completion no longer needs a special "write directly into the
  parent accumulator here" ownership convention
- native child plans now hand object results and child error lists back through
  the field frame outcome, and `consume` remains the single boundary that
  mutates the parent accumulator
- the throughput result is effectively flat, which is acceptable because this
  change reduces one more special-case branch on the path to a VM-like runner

Latest spot verification after normalizing sync generic completed hashes into
frame outcomes before `consume`:

- `minil test t/11_execution.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42643/s`
  - `houtou_xs_ast 41724/s`

Interpretation:

- sync generic completion now extracts `{ data, errors }` into the field
  frame's native outcome state before `consume`, instead of making `consume`
  reinterpret every completed hash itself
- the completed-hash allocation is still present upstream, but the execution
  boundary is more regular and ready for a future "generic complete directly to
  outcome" lowering

Latest spot verification after accumulating sync completed hashes directly into
head data/errors inside the XS execution loops:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 78758/s`
  - `houtou_xs_ast 76204/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42308/s`
  - `houtou_xs_ast 42111/s`

Interpretation:

- `gql_execution_execute_fields(...)` and
  `gql_execution_execute_field_plan(...)` no longer retain sync completed
  `{ data, errors }` hashes in `result_values_av`; they now extract into a
  direct head accumulator immediately and only keep promises in the pending
  arrays
- this does not yet remove the upstream completed-hash allocation, but it
  aligns the AST/XS sync loops more closely with the compiled-IR
  `head data + pending promises` execution shape
- spot numbers are neutral-to-positive, so this is a good staging step before
  pushing `execution.h` completion helpers toward native outcomes as well

Latest spot verification after applying the same `head data + pending promises`
shape to list completion in `execution.h`:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 77207/s`
  - `houtou_xs_ast 74974/s`
- `async_list` (`--count=-4`)
  - `houtou_compiled_ir 44032/s`
  - `houtou_facade_ast 44032/s`
- `abstract_with_fragment` (`--count=-4`)
  - run 1: `houtou_compiled_ir 40573/s`
  - run 2: `houtou_compiled_ir 42212/s`

Interpretation:

- sync list items are now accumulated directly into list `data/errors`, and
  promise items are tracked only as `(index, promise)` pending entries until
  the final merge step
- this is mainly a shape-alignment change for the non-IR XS executor; it
  reduces retained completed-hash arrays on the list path and gives the promise
  path a direct "head + pending" merge API too
- `nested_variable_object` and `async_list` hold up, while
  `abstract_with_fragment` remains noisy; keep the change as VM-readiness and
  continue focusing abstract-path work on native outcome lowering rather than
  list-specific shortcuts

Latest spot verification after trying trivial default-resolver completion
against borrowed values before copying in the non-IR XS field loops:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 78195/s`
  - `houtou_xs_ast 76025/s`
- `async_list` (`--count=-4`)
  - `houtou_compiled_ir 42407/s`
  - `houtou_facade_ast 42884/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 41228/s`
  - `houtou_xs_ast 40983/s`

Interpretation:

- `gql_execution_execute_fields(...)` and
  `gql_execution_execute_field_plan(...)` now try trivial completion against a
  borrowed default-resolver property first, and only `share_or_copy` that value
  if execution has to fall through to the generic completion path
- this is a small but safe allocation reduction on the XS/AST side; it is not
  a major abstract-path win by itself, but it keeps the field loops closer to
  the compiled-IR "borrow first, materialize later" strategy

Latest spot verification after re-trying the previously crashed direct-data
idea in a narrower, ownership-safe form:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 77882/s`
  - `houtou_xs_ast 75568/s`
- `async_list` (`--count=-4`)
  - `houtou_compiled_ir 42729/s`
  - `houtou_facade_ast 43300/s`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 41421/s`
  - `houtou_xs_ast 42708/s`

Interpretation:

- the crashed experiment was reintroduced only for the `__typename` trivial
  path in `gql_execution_execute_fields(...)` and
  `gql_execution_execute_field_plan(...)`
- instead of building a temporary completed `{ data => ... }` hash for that
  case, the loop now materializes the scalar directly into the top-level
  `direct_data_hv`
- the broader "borrowed default resolver -> direct data" retry was measured and
  dropped again because it duplicated trivial-completion metadata work and
  regressed `abstract_with_fragment`
- keep the narrow `__typename` direct-data path; it is ownership-safe, test
  clean, and directionally aligned with removing completed-hash allocation from
  success paths

Planned medium-term compiler direction:

- introduce multiple lowering/optimization stages between parsed IR and final
  execution instead of relying on ad hoc runtime fast paths
- a plausible pipeline is:
  - normalized IR
  - typed/specialized IR
  - execution-lowered IR with native field operands and child-plan tables
  - late specialization / fusion passes
  - final threaded-op / VM emission
- this fits the current strategy better than piling on more local runtime
  shortcuts, because it moves branching, specialization, and ownership
  decisions into compile time where they are easier to reason about and less
  likely to regress hot-path stability

Latest structural progress toward that staged pipeline:

- `compiled_ir` no longer conceptually owns a raw `root_field_plan` directly;
  it now owns an explicit execution-lowered plan object whose current stage is
  `LOWERED_NATIVE_FIELDS`
- the lowered plan currently wraps the existing native root field plan, so this
  is mostly a structural ownership change rather than a new optimization pass
- this is still useful because it creates a concrete insertion point for future
  typed/specialized IR and late lowering passes without having to overload the
  `compiled_exec` handle itself

Latest spot verification after introducing the explicit lowered-plan boundary:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 43216/s`
  - `houtou_xs_ast 43039/s`

Interpretation:

- this step is effectively neutral-to-slightly-positive on the target case
- the real value is architectural: the next pass can target the lowered-plan
  layer directly instead of bolting more specialization logic onto
  `compiled_exec` or the runtime field loop

Latest structural progress on abstract-specialized lowering:

- lowered native field-plan entries now own a lowered abstract-child table for
  the single-node native-plan case instead of borrowing the node-attached
  concrete-plan table directly
- the lowered table retains only `(possible_type, native_field_plan)` pairs and
  clones the native child field plan into lowered-plan-owned storage
- sync abstract completion on the compiled-IR path now consults that owned
  lowered table first, instead of rediscovering the concrete native child plan
  by rewalking `nodes` through the legacy helper path
- destruction now runs through lowered-plan teardown, so ownership is explicit
  and no longer depends on the lifetime of node-attached compiled metadata

Latest spot verification after owning that lowered abstract child lookup:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 43749/s`
  - `houtou_xs_ast 43442/s`

Interpretation:

- the change is still mostly a lowering/ownership step rather than a large
  throughput win
- it removes one more runtime and lifetime dependency on "look back into legacy
  node state to rediscover the concrete child native plan"
- this is the right insertion point for the next real optimization pass:
  lowering abstract child execution into a more self-contained specialized plan
  whose native child table is already owned by the lowered execution plan

Latest structural follow-up on that owned lowered abstract-child table:

- cloned lowered abstract-child plans now recursively clone nested lowered
  abstract-child tables as well, so self-contained ownership is preserved below
  the first abstract child boundary
- this removes another fallback path where nested abstract child execution would
  have had to rebuild lowered lookup state from node-attached metadata

Latest spot verification after recursive lowered abstract-child cloning:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42722/s`
  - `houtou_xs_ast 43649/s`

Interpretation:

- this step is primarily about making the lowered plan recursively
  self-contained, not about immediate throughput
- the target case remains in the same general band, which is acceptable for
  this ownership/VM-readiness pass
- the next profitable step is still to specialize abstract completion/result
  writing, not to add more lookup micro-optimizations

Latest completion-side allocation reduction:

- `execution.h` now exposes a narrow sync fast helper that returns direct
  `data/errors` for `null`, leaf, and simple `NonNull` completions without
  first materializing a completed `{ data => ... }` `HV`
- compiled-IR generic completion uses that helper before falling back to the
  older completed-`HV` path, so sync happy paths can skip one more Perl object
  boundary

Latest spot verification after wiring the direct-data completion helper:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42007/s`
  - `houtou_xs_ast 42308/s`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 80765/s`
  - `houtou_xs_ast 79800/s`

Interpretation:

- this is a modest but directionally correct object-allocation reduction
- target-case gains are still small and noisy, but the helper does not regress
  the broader compiled-IR sync path
- the next high-value step remains extending this approach past trivial
  completion and into object/abstract completion outcomes themselves

Latest generic XS-loop follow-up:

- the same sync direct-data completion helper is now used in the generic
  `execute_fields()` / `execute_field_plan()` loops before falling back to
  completed-`HV` materialization
- borrowed default-resolver values now try the direct-data trivial path before
  they are copied into owned Perl scalars
- this broadens the object-allocation reduction beyond compiled-IR-specific
  code paths and keeps the "happy path stays in direct data" idea aligned
  across both legacy XS execution and lowered native execution

Latest spot verification after widening direct-data use in generic XS loops:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `abstract_with_fragment` (`--count=-4`)
  - `houtou_compiled_ir 42708/s`
  - `houtou_xs_ast 42516/s`
- `nested_variable_object` (`--count=-4`)
  - `houtou_compiled_ir 80397/s`
  - `houtou_xs_ast 77193/s`

Interpretation:

- the target case stays roughly flat, which is acceptable for this broader
  object-allocation cleanup
- the broader XS sync path benefits more clearly than the abstract target case
- this is still a supporting step; the main remaining abstract cost is the
  object/abstract completion shape itself, not trivial leaf completion

## Breaking-API Speed Notes

If public compatibility constraints were relaxed, the highest-probability extra
speed wins would likely be:

- execute against a frozen XS/runtime schema snapshot instead of Moo/Type::Tiny
  objects
- expose a prepared/compiled query handle whose variable/default coercion is
  prevalidated against that runtime schema
- allow an execution-only node/selection shape instead of graphql-perl
  compatibility hashes for resolve info, field nodes, and fragment maps

## April 2026 Reset

The next optimization project is now treated as a separate runtime effort.

Recent conclusions:

- `omit_resolve_type_info` was useful to prove that `build_resolve_info`
  materialization is not the main bottleneck for `abstract_with_fragment`
- `sv_does` / `sv_derived_from` / possible-type micro-optimizations also did
  not produce a strong stable win by themselves
- therefore the next meaningful step is not another local shortcut; it is a
  new `compiled_ir`-only execution-lowered runtime / VM path

Current project decision:

- keep public execute / schema / promise APIs compatible
- allow `compiled_ir` internal execution to stop sharing internal AST /
  legacy-compatible shapes
- build a new lowered plan and VM runtime beside the current executor rather
  than continuing to stretch the mixed executor

See:

- `docs/compiled-ir-vm-runtime.md`

## April 2026 VM Runtime Follow-Up

The current branch is now pushing the new compiled-IR runtime in a direction
that is explicitly cache-locality-aware, not only "fewer Perl objects".

Current implementation status:

- lowered program ownership exists as `program -> root_block -> field_plan`
- field execution already separates immutable metadata, mutable frame state,
  and a native result writer
- sync child-plan runners already operate on `(writer, promise_present)` rather
  than a full execution accumulator
- sync trivial completion, sync object-child direct paths, and sync list fast
  paths can already produce native outcomes instead of always flowing through
  Perl `{ data, errors }` envelopes

Newest structural step:

- each lowered field-plan entry now has an inline immutable metadata block and
  a separate inline "hot operand" view for values that the execution loop
  touches on nearly every field
- the hot view currently carries `field_def`, `return_type`, `type`, `resolve`,
  `nodes`, `first_node`, and `abstract_child_plan_table`
- hot paths such as resolver selection, generic completion, frame setup, and
  abstract-child native lookup now prefer this hot view instead of repeatedly
  reading the colder full entry

Latest spot verification after landing the first hot-operand pass:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-3`)
  - `houtou_compiled_ir 80894/s`
  - `houtou_xs_ast 78156/s`
- `abstract_with_fragment` (`--count=-3`)
  - `houtou_compiled_ir 42593/s`
  - `houtou_xs_ast 42575/s`

Interpretation:

- the first hot/cold split step does not yet create a large standalone win
- it does keep the broader sync object case ahead while leaving the abstract
  target roughly tied
- this is acceptable because the main value of the change is architectural:
  the runtime loop is starting to traverse a denser hot working set

Current next steps:

- move more frequently touched operands out of the full entry and into the
  hot view, while pushing path/count/debug-style data into colder storage
- keep shrinking the places where compiled-IR still uses Perl completed
  envelopes as an internal currency
- preserve an explicit fallback boundary so future VM lowering can retire
  mixed paths block by block

Follow-up after the first hot-operand pass:

- path/count-style fields are now also split behind a cold view
- frame setup, frame cleanup, metadata extraction, cloning, and legacy
  materialization now prefer the cold view instead of reading those values
  directly from the full entry
- this keeps the inner execution loop focused on `meta + hot + writer`, while
  path/count/debug-style data move further away from the hot working set

Latest spot verification after the first cold split:

- `minil test t/11_execution.t`
- `minil test t/12_promise.t`
- `nested_variable_object` (`--count=-3`)
  - `houtou_compiled_ir 82048/s`
  - `houtou_xs_ast 79626/s`
- `abstract_with_fragment` (`--count=-3`)
  - `houtou_compiled_ir 42575/s`
  - `houtou_xs_ast 42306/s`

Interpretation:

- the cold split is small but directionally correct
- the broader sync object case benefits a little more clearly
- the abstract target stays effectively tied or slightly ahead, which is good
  enough for a structural locality improvement
