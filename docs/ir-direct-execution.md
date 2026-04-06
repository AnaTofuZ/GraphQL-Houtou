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
- keep the existing XS execution hot paths reusable
- do not fork business logic into a second completely independent executor
- introduce IR-oriented execution in small internal stages

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

Internal prepared-IR execution path:

- build a shared execution context
- bridge only the reachable root subtree
- reuse `_execute_fields_xs` and `_build_response_xs`

Status: landed.

### Stage 4

Introduce a compiled execution plan object:

- selected operation
- fragment index
- root field plan
- nested selection metadata
- schema-resolved field definitions where profitable

The plan should be reusable across repeated executions of the same query.

Status: active next step.

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
