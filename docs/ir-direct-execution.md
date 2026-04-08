# IR Direct Execution

`GraphQL::Houtou` currently parses executable documents into an arena-backed C
IR and then materializes a graphql-perl compatible AST before execution.

That keeps parser compatibility high, but it means string-based execution still
pays for:

- IR parse
- Perl AST materialization
- execution front-end reconstruction from that AST

When the caller does not need to inspect or mutate the AST, the AST
materialization step is pure overhead.

## Design Goal

Add an internal execution path that can avoid full-document AST
materialization without duplicating the whole execution engine or changing the
public AST contract.

Principles:

- keep the public parser and AST APIs unchanged
- keep the graphql-perl-compatible AST execution layer available
- allow compiled-IR-native hot paths to diverge from AST/legacy code when that
  removes measurable bridge costs
- introduce IR-oriented execution in small internal stages

## Compatibility Policy

The working policy for the current optimization phase is:

- keep graphql-perl compatibility for user-visible AST execution
- do not require code-sharing between AST execution and compiled-IR execution
  if that sharing keeps legacy bridge costs in the hot path
- allow duplicated compiled-IR-only execution code, as long as comments point
  to the corresponding legacy / AST-oriented implementation where useful
- allow breaking changes to internal APIs that are not intended for end users
- keep user-visible GraphQL object APIs broadly compatible, but allow
  performance-motivated deviations if they are explicitly reviewed first and
  documented before landing
- treat compatibility-affecting shortcuts such as optional info attachment,
  lighter-weight hashes instead of full objects, or reduced metadata as
  high-signal design decisions that must be called out explicitly
- keep memory-leak risk visible whenever native C tables / structs are added

Additional runtime / type-system policy:

- built-in primitive GraphQL types may be specialized in XS and do not need to
  stay on `Type::Tiny` internally
- the public API should still keep a `Type::Tiny`-friendly path for typical
  user-defined custom scalar / coercion flows
- Moo-based object construction may be replaced or bypassed on internal hot
  paths when measurement justifies it, but user-visible behavior changes still
  require explicit review and documentation

## Why This Work Exists

The current string-query execution path is roughly:

1. parse source into executable IR
2. materialize a graphql-perl compatible AST
3. rebuild operation / fragment / field front-end state from that AST
4. run the XS execution core

The AST step is required for compatibility, but it is not always required for
execution. If the caller never inspects or mutates the AST, then:

- full-document AST materialization
- operation selection from the AST
- fragment map build from the AST
- root field collection from the AST

are front-end costs that can be avoided.

## Alternatives Considered

Several broader approaches were considered before settling on the current
direction.

### 1. Compiled Execution Plan

This is the preferred direction.

Instead of walking parser IR directly on every execution, compile executable IR
into a smaller execution-oriented plan that already contains:

- selected operation
- fragment index
- merged field groups
- schema-resolved field definitions
- nested selection plans
- variable definition metadata

Pros:

- removes repeated front-end work from hot execution paths
- avoids full AST materialization
- keeps resolver/completion logic reusable
- fits naturally with persisted or prepared queries

Cons:

- requires a distinct compiled representation
- must stay coherent with schema changes and validation rules

### 2. Direct IR Execution Without a Compiled Plan

This is useful as a stepping stone, but probably not the end state.

Pros:

- simpler to start with
- reuses parser IR as-is

Cons:

- still leaves repeated front-end work on every execute
- tends to grow ad-hoc bridges instead of a reusable execution representation

### 3. Fully Separate IR-Native Executor

This would likely be fastest in absolute terms, but it is intentionally *not*
the current direction.

Pros:

- maximum freedom for execution-specific optimization

Cons:

- duplicates resolver/completion/promise logic
- increases compatibility risk
- increases maintenance burden significantly

### 4. Keep AST Execution but Micro-optimize It

This remains useful, but it does not remove the structural cost of
materializing the execution front-end from an AST.

Pros:

- low risk
- incremental

Cons:

- cannot remove the main AST materialization cost
- eventually hits diminishing returns

## Chosen Direction

The current conclusion is:

- use IR-direct execution as groundwork
- evolve that groundwork into a reusable **compiled execution plan**
- keep the existing XS execution core for resolver invocation, completion,
  promises, and response shaping

In other words, the preferred architecture is:

1. parse executable source into IR
2. compile IR into an execution plan
3. execute the plan through the existing XS execution core

This avoids both extremes:

- it does not force public AST changes
- it does not require maintaining a completely separate executor

## Native-IR Follow-up

The next major bottleneck is no longer only AST compatibility. It is also that
prepared / compiled IR still retain too many Perl objects (`SV` / `AV` / `HV`)
as bridge structures.

That means the long-term direction is not just "execute compiled IR faster",
but also:

1. keep parser IR and compiled plans in native C structures for as long as
   possible
2. avoid retaining legacy AST-compatible `SV` graphs inside compiled plans
3. materialize legacy `operation` / `fragments` / `field` buckets only when a
   compatibility boundary actually needs them
4. evolve compiled field plans toward native execution plans that can
   eventually be executed by a VM-like runner

This is the practical bridge between the current executor work and a future
compiled-IR VM.

Recent executor shaping follows that same path:

- root/native child loops are being collapsed into a shared "execute one field
  entry" helper
- runtime state needed for that helper is being gathered into explicit native
  execution env / accumulator structs
- native field-plan entries are starting to carry explicit dispatch metadata so
  future opcode lowering can distinguish meta fields, inherited resolver calls,
  and explicit resolver calls without rediscovering that shape at runtime
- the field-entry executor is also being split into smaller helper phases so
  opcode lowering can replace one phase at a time instead of reworking the
  whole root/child dispatch loop in one step
- completion behavior is also being lifted into explicit plan metadata, so
  future opcode lowering can treat trivial leaf completion as a separate op
  family instead of inferring it ad hoc from resolver results
- that completion metadata is now already consumed through a dedicated helper,
  which means the current executor boundary is closer to an explicit
  `resolve -> complete -> consume` pipeline than to one large field routine
- the post-resolve side is also now separated into explicit completion and
  consume helpers, which should make future opcode lowering a matter of
  replacing helper calls with op dispatch instead of rediscovering boundaries
- the shared field-entry executor now also uses a stage dispatcher that is
  written in a direct-threading-friendly shape: on compilers with computed-goto
  support it dispatches via a label table, and otherwise falls back to a
  `switch`-based stage loop with the same stage boundaries
- native field execution is now also moving operand ownership onto the plan
  entry itself: root-side missing `nodes` / `field_def` / `type` operands are
  lazily materialized once and then retained on the entry, so the dispatcher
  can execute from a single field-op record instead of being fed extra runtime
  operands from each loop site
- that field-op record is also being normalized into smaller native enum
  operands (`meta`, `resolve`, `args`, `completion`) rather than one broader
  dispatch shape inferred from Perl objects at runtime
- the field-entry executor now dispatches over a fixed op array stored on each
  compiled plan entry instead of carrying a hard-coded stage enum internally;
  this is still a small fixed sequence, but it moves control flow ownership
  onto the compiled plan and is closer to true opcode execution
- the aim is for compiled IR execution to look like dispatch over a sequence of
  field ops, while still reusing existing completion / promise helpers where
  that does not dominate cost

## Current Groundwork

The codebase now has an internal prepared executable IR handle:

- `GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs($source)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_stats_xs($handle)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_plan_xs($handle, $operation_name)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_frontend_xs($handle, $operation_name)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_context_seed_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_selection_plan_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_buckets_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_plan_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_legacy_fields_xs(...)`
- `GraphQL::Houtou::XS::Execution::execute_prepared_ir_xs(...)`

The prepared handle owns:

- the parsed `gql_ir_document_t`
- a retained copy of the source `SV`

The current prepared-IR execution path already proves an important point:

- a full-document AST is not required to reach the existing XS execution core

However, the current path still rebuilds bridge structures on every execute.
That is why the next step is *not* "more ad-hoc prepared IR helpers", but a
compiled plan that caches reusable front-end state.

Recent follow-up on that direction:

- compiled root plans now cache runtime `nodes` / `path` data directly
- compiled root plans are beginning to retain native C entries instead of
  keeping `field_order` / `fields` Perl containers as the primary form
- compiled abstract child execution can use direct field plans for simple
  single-node concrete cases
- compiled abstract child direct-plan lookup is also moving away from
  type-name Perl hash lookup toward native node-attached tables
- plain compiled field buckets on compiled nodes/fragments are likewise moving
  toward native bucket tables that the merge path can consume directly
- compiled handles are moving away from retaining eager legacy
  `operation` / `fragments` / `root_fields` state
- those legacy structures are increasingly treated as lazy compatibility
  materializations rather than as the compiled representation itself

## Reuse Strategy

Avoid a second full executor.

Instead, the long-term direction is:

1. parse executable source into IR
2. compile IR into an execution plan
3. build the smallest execution context needed from that plan
4. feed the existing XS field execution / completion machinery with
   plan-derived structures

This keeps reuse focused on:

- argument coercion
- resolver invocation
- completion
- promise handling
- response shaping

The new work should stay limited to the front-end pieces that currently assume
a graphql-perl AST:

- operation selection
- fragment indexing
- variable definition extraction
- field / directive / selection traversal

It should *not* fork the already-optimized XS execution core unless there is a
clear measured reason to do so.

## Planned Stages

### Stage 1

Internal handle and ownership only.

Status: landed.

### Stage 2

Prepared IR metadata and minimal execution bridge:

- operation metadata
- fragment metadata
- root selection metadata
- root field buckets / plans
- minimal reachable legacy bridge

Status: landed.

### Stage 3

Reduce retained Perl-object state inside compiled plans.

Target changes:

- stop treating legacy `SV` maps as the canonical compiled representation
- keep selected operation / fragment / field metadata in native IR-oriented
  form
- materialize legacy `operation`, `fragments`, and `root_fields` only on
  demand
- continue replacing compiled field buckets with execution-oriented field plans

Status: in progress.

### Stage 4

Native child execution plans and VM-oriented lowering.

Target changes:

- compile object / abstract child selections into native child plans
- lower more arguments / directives into compile-time data
- make the hot execution loop consume plan arrays / structs instead of Perl
  hashes
- converge on a VM-like executor without prematurely forking GraphQL
  semantics

Status: planned.

### Execution Rollout 1

Internal prepared-IR execution path:

- build a shared execution context
- bridge only the reachable root subtree
- reuse `_execute_fields_xs` and `_build_response_xs`

Status: landed.

### Execution Rollout 2

Introduce a compiled execution plan object:

- selected operation
- fragment index
- root field plan
- nested selection metadata
- schema-resolved field definitions where profitable

The plan should be reusable across repeated executions of the same query.

Status: active next step.

Current implementation note:

- compiled plans already cache:
  - operation metadata
  - fragment map
  - root legacy fields
  - root type
  - root selection metadata
  - root field plan metadata
- the next expansion is to make nested selection metadata and schema-resolved
  field definitions increasingly authoritative so execution no longer rebuilds
  front-end state below the root selection boundary

## Current Optimization Conclusion

Recent abstract/fragment-heavy tuning work clarified an important boundary.

For `abstract_with_fragment`-shaped workloads:

- runtime cache improvements and small AST-path fast paths help a little
- callback lookup caching is valid but modest
- abstract fragment matching can be made cheaper
- low-risk bucket / refcount micro-optimizations are acceptable

But the measured gains remain small and noisy once the easy cache lookups are
in place.

That means the next meaningful speedups are unlikely to come from further
incremental AST-compatible tuning alone.

## Preferred Direction If AST Compatibility Is Not A Goal

If the caller does not need graphql-perl AST compatibility, and limited
execution-only duplication is acceptable, the preferred direction is now:

1. parse executable source into arena IR
2. compile IR into an execution-oriented plan
3. optionally compile that plan again into a schema-specialized runtime plan
4. execute the runtime plan through an IR-native hot path

This is effectively a multi-stage compilation strategy:

- parser IR
- execution plan IR
- runtime-specialized executable plan

The goal is not "duplicate all execution logic", but to stop paying legacy
bridge costs inside the hot path.

## Highest-Value IR-Native Targets

If optimization work continues on the IR-direct side, these are the most
promising targets in order:

### 1. Native compiled field execution

Current compiled IR still stores and executes legacy structures such as:

- `operation_sv`
- `fragments_sv`
- `root_fields_sv`

and eventually feeds them into the AST/legacy-oriented field executor.

That means compiled IR is still paying for:

- legacy selection/node materialization
- hash/array bucket merging
- legacy context shape expectations

The most valuable next step is a compiled-IR-only field executor that consumes
native field plans directly instead of `root_fields_sv`.

### 2. IR-native execution context

Current compiled execution still builds a Perl `HV` execution context with:

- schema
- fragments
- operation
- variable values
- field resolver
- resolve info base

That is convenient for reuse but not ideal for hot execution.

The preferred next step is to keep hot-path data in a C struct and materialize
Perl hashes only on demand, especially for resolver info.

### 3. Per-concrete-type abstract child plans

Abstract completion is still expensive because even compiled plans eventually
fall back toward selection/bucket structures.

The preferred compiled representation for abstract fields is:

- one abstract field plan
- plus one precompiled child plan per concrete runtime object type

Then `resolve_type` can jump directly to a child executable plan instead of
rebuilding or merging nested selections.

### 4. Compile-time argument and directive lowering

IR execution still keeps legacy conversion helpers for arguments, directives,
and values.

A stronger compiled plan should lower:

- static argument values
- include/skip metadata
- selection flags

so runtime only resolves variables and executes.

### 5. Index-based fragment/type dispatch

Where possible, compiled plans should use IDs / indexes instead of repeated:

- name SV creation
- fragment-name lookup
- type-name lookup

This matters most once a native compiled executor exists.

## Acceptable Duplication Boundary

Some duplication is now considered acceptable if it stays inside the
compiled-IR execution layer.

Reasonable duplication:

- compiled-IR-only execution context structs
- compiled-IR-only field execution loop
- compiled abstract child-plan dispatch

Duplication to avoid unless clearly justified by measurement:

- separate GraphQL semantics for directives
- separate variable coercion semantics
- separate error/path semantics
- separate promise semantics

In short:

- duplicate the execution front-end and plan runner if needed
- do not casually duplicate GraphQL semantics or promise/error behavior

## AST-Path Maintenance Rule

AST-path tuning remains worthwhile only while changes are:

- low risk
- low complexity
- shared with IR execution

If an AST-focused optimization requires substantial special cases for
abstract/fragment-heavy execution and still yields only single-digit or noisy
gains, prefer not to land it.

At that point effort should move to compiled IR native execution instead.

## Runtime Schema Direction

NYTProf snapshots still show cost from Perl meta layers such as:

- `Exporter::Tiny`
- `Type::Tiny`
- `Moo`

That cost does not come from query parsing alone. It also comes from reading
schema/type objects at runtime.

The current conclusion is that query-side compiled plans should eventually be
paired with a **runtime schema snapshot**:

- public `GraphQL::Houtou::Schema` / `GraphQL::Houtou::Type::*` stay unchanged
- execution compiles those objects into a smaller runtime schema form
- compiled plans then target that runtime schema instead of the original Moo /
  Type::Tiny object graph

This keeps compatibility while removing Perl meta-layer costs from hot
execution paths.

### Stage 5

Add an internal string-query fast path that compiles and executes from the
plan directly when AST exposure is not needed.

AST input continues to use the current path.

### Stage 6

Optionally expose a prepared-query API, for example:

- `prepare($query)`
- `execute_prepared($schema, $prepared, ...)`

Only after the internal path has stabilized.

## Complexity Guardrails

To keep this maintainable:

- do not add a second copy of resolver/completion logic
- do not add a second public AST shape
- do not let "IR direct execute" turn into a permanently half-duplicated
  executor front-end
- prefer shared helper functions over AST-specific and IR-specific versions
- keep IR-direct logic isolated to the execution front-end boundary
- prefer compiling and caching reusable plan pieces over rebuilding lightweight
  bridges on every execute

## Current VM-Readiness State

The compiled-IR executor is now past the "shared loop with some native caches"
stage and into a more explicit execution-plan form:

- each native field-plan entry owns a fixed op array
- the dispatcher can use direct threading / computed goto where supported
- resolver-call ops are now specialized as:
  - fixed resolver + empty args
  - fixed resolver + built args
  - context/default resolver + empty args
  - context/default resolver + built args
- completion ops are also now specialized as:
  - trivial completion
  - generic completion

This matters less for immediate throughput than for architecture:

- runtime no longer has to rediscover as much branch structure from Perl data
- plan entries are closer to real bytecode operands
- the remaining large costs are no longer the dispatch shape itself, but
  completion work, Perl callback boundaries, and delayed legacy materialization

Near-term implication:

- keep pushing branch structure into native plan entries
- avoid introducing new Perl object bridges on the compiled path
- treat further dispatcher tuning as secondary until more completion/path/info
  work moves behind native operands
- keep a single native "finish execution" boundary so root/native-child loops
  share one result materialization / promise-merge terminal step
- keep native execution-frame initialization shared too, so a future VM can
  enter with one stable env/accumulator shape regardless of root vs child plan
- keep the field-plan loop itself shared too, so root/native-child execution
  diverges only where root plans still need lazy runtime operand fill
- keep that distinction expressed at plan granularity, not as per-entry loop
  rediscovery, so a compiled root plan that is already self-contained can run
  through the same hot loop as a native child plan
- when sync abstract completion can resolve to a native child plan, prefer
  consuming that child plan directly into the parent accumulator instead of
  materializing a temporary `{ data, errors }` Perl result hash and unpacking
  it again
- keep pending async field results in native arrays and materialize Perl AVs
  only at the final promise-merge boundary
- keep per-field execution state in a native frame struct as well, so the
  stage dispatcher does not need to shuttle a growing set of loose locals; this
  makes a future bytecode / VM runner much closer to "run op against frame"
  than to "rebuild transient Perl-facing state for each helper call"
- move per-field completion results into a native outcome slot on that frame,
  so `meta`, `complete`, and `consume` communicate through a small native kind
  plus payload rather than ad hoc `completed_sv` ownership conventions
