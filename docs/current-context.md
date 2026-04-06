# Current Context

This note is the compressed handoff for the current `GraphQL::Houtou` worktree.
It should stay short enough to recover momentum quickly after context resets.

## Snapshot

- Main compatibility work remains on `main`.
- IR-direct execution work now lives on the dedicated
  `ir-direct-execution` branch only.
- Public parser / AST APIs remain unchanged.
- Current IR work is intentionally limited to the execution front-end
  boundary so resolver / completion / promise logic can keep reusing the
  existing XS execution core.

## Recent Landed Work

- `70b94cb` Move type library into Houtou namespace
- `791b6c8` Implement Houtou list, non-null, and scalar types
- `b061db1` Implement Houtou enum and input object types
- `89547bd` Implement Houtou object, interface, and union types
- `268ad5b` Migrate Houtou types onto Houtou roles
- `2da0329` Add initial XS validation entrypoint
- `db5f559` Move fragment cycle validation into XS
- `0a75b01` Add validation status note and introspection wrapper
- `1260ccc` Own introspection types in Houtou
- `ad99ad2` Move runtime type helpers into Houtou
- `962e411` Add initial Houtou execution facade
- `d49a2d7` Move execution context setup into XS
- `64fa2e3` Move execution field loop into XS
- `83f81a3` Move execution info build and merge into XS
- `93a85b8` Move execution resolver calls into XS
- `73991f5` Coerce XS resolver failures into GraphQL errors
- `8ec0444` Add XS fast path for simple argument coercion
- `cc8642f` Expand XS execution fast paths
- `da8259d` Add XS list completion fast path
- `01bd372` Add XS object completion fast path
- `4bfe85d` Handle simple object directives in XS
- `a0b8d35` Handle simple fragments in XS object completion
- `a75af49` Support object completion fast paths in XS
- `fdfba8c` Add XS abstract completion fast paths
- `3dc64b4` Support default abstract completion in XS
- `5c42d7d` Expand XS list completion coverage
- `91451a7` Skip irrelevant concrete fragments in XS
- `171a072` Handle execution callback exceptions in XS
- `758f0f9` Normalize promise code hooks
- `0c0b9f7` Reduce XS execution fixed overhead
- `838747b` Reduce promise execution merge overhead
- `8eb07cc` Profile PP bridges and batch promise list completion
- `1343219` Move prepared execution entrypoint into XS
- `41477aa` Make XS field execution promise-aware
- `095fc8e` Skip PP variable defaults for empty operations
- `f8d5699` Handle promise leaf completion in XS
- `a17a659` Add global default promise hooks
- `7a5d061` Normalize promise hooks for XS execution
- `ad56343` Move promise adapter dispatch into XS
- `cabaf0f` Use XS helpers for promise hash merging
- `71d0bc7` Route promise resolve and reject through adapter hooks
- `13dcc3d` Move execution response shaping into XS
- `9050567` Move located execution errors into XS
- `88266c0` Refactor promise completion continuations
- `2b3681b` Add target-specific NYTProf utilities
- `84e6322` Add XS fast paths for built-in scalars
- `3701691` Finish XS fast paths for built-in scalars
- `07d78ac` Use scalar refs for XS boolean values
- `c5e3ffe` Reduce enum and abstract execution overhead

### IR Direct Execution Branch

These commits exist on `ir-direct-execution`, not on `main`:

- `8a444ec` Add prepared executable IR groundwork
- `79d2989` Add prepared IR operation metadata
- `7572cf7` Expose prepared IR frontend metadata
- `ce92623` Add prepared IR frontend metadata
- `fbd786e` Add prepared IR context seed metadata
- `d2441c6` Add prepared IR root selection plan
- `48582f7` Add prepared IR root field buckets
- `656c77a` Add prepared IR legacy field bridge

## Current Architecture

### Parser / AST

- `GraphQL::Houtou::XS::Parser` remains the primary parser backend.
- graphql-js executable documents use IR-first parsing and XS builders.
- Lazy materialization exists for expensive graphql-js child arrays.

### Schema / Types

- `GraphQL::Houtou::Schema`
- `GraphQL::Houtou::Directive`
- `GraphQL::Houtou::Type::*`
- `GraphQL::Houtou::Role::*`

These are now Houtou-owned public classes and roles.

### Schema Compiler

- Public facade: `GraphQL::Houtou::Schema::Compiler`
- PP reference: `GraphQL::Houtou::Schema::Compiler::PP`
- XS entrypoint: `GraphQL::Houtou::XS::SchemaCompiler`

The public API prefers XS and falls back to PP.

### Validation

- Public facade: `GraphQL::Houtou::Validation`
- PP reference: `GraphQL::Houtou::Validation::PP`
- XS entrypoint: `GraphQL::Houtou::XS::Validation`

Currently migrated to XS:

- no operations supplied
- operation name uniqueness
- lone anonymous operation
- subscription single root field
- fragment cycle detection

Further rule-by-rule migration is currently deprioritized; see
`docs/validation-status.md`.

### Introspection

- `GraphQL::Houtou::Introspection` is now Houtou-owned.
- Meta types and meta fields no longer depend on the upstream package name.
- Transition-time compatibility for mixed upstream/Houtou type objects is still
  intentionally preserved in resolver logic.

### Runtime Helpers

Moved into Houtou type/role code as groundwork for execution work:

- `GraphQL::Houtou::Type::Object::_collect_fields`
- `GraphQL::Houtou::Type::Object::_fragment_condition_match`
- `GraphQL::Houtou::Type::Object::_should_include_node`
- `GraphQL::Houtou::Type::Object::_complete_value`
- `GraphQL::Houtou::Type::List::_complete_value`
- `GraphQL::Houtou::Role::Abstract::_complete_value`

### Execution

- Public facade: `GraphQL::Houtou::Execution`
- PP reference: `GraphQL::Houtou::Execution::PP`
- XS entrypoint: `GraphQL::Houtou::XS::Execution`

Current XS-owned pieces:

- AST coercion
- fragment map build
- operation selection
- variable default application dispatch
- field execution loop
- resolve info construction
- final hash merge
- resolver invocation and error coercion
- simple / variable argument coercion common cases
- leaf / null / non-null completion common cases
- leaf list completion common cases
- object completion common cases
  - plain nested selections
  - simple `@include` / `@skip`
  - simple inline fragments
  - simple fragment spreads
  - abstract fragment conditions via `schema->is_possible_type`
  - `is_type_of` happy path / false / exception paths
  - abstract type completion happy paths
    - explicit `resolve_type`
    - default `get_possible_types` + `is_type_of`

Still delegated to PP helpers:

- full argument coercion fallback
- complex object/list completion fallback
- promise-backed execution now keeps upstream-style `promise_code`, supports a
  global default hook set, and allows optional `then` / `is_promise` hooks so
  the caller can adapt arbitrary promise libraries without Houtou hardcoding
  backend names
- promise dispatch, list/hash merge, response shaping, and located error
  decoration are now XS-backed
- prepared operation execution now runs in XS
- promise-aware top-level field execution now runs in XS
- promise leaf completion now runs in XS

### IR Direct Execution Groundwork

Internal-only IR helpers now exist for executable documents:

- `GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs($source)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_stats_xs($handle)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_plan_xs($handle, $operation_name)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_frontend_xs($handle, $operation_name)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_operation_legacy_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_context_seed_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_execution_context_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_selection_plan_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_buckets_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_plan_xs(...)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_legacy_fields_xs(...)`
- `GraphQL::Houtou::XS::Execution::execute_prepared_ir_xs(...)`

Newest in-progress step:

- `GraphQL::Houtou::XS::Execution::execute_prepared_ir_xs(...)`
  now executes a prepared executable IR handle by:
  - building a minimal legacy-compatible operation / fragment / variable front-end
  - building a shared execution context
  - bridging only the reachable root field subtree
  - reusing `_execute_fields_xs` and `_build_response_xs`

This is the first end-to-end IR-direct execution path.
It avoids full document AST materialization, but still bridges the reachable
execution subtree into the existing XS engine instead of introducing a second
executor.

## Testing Snapshot

Latest local verification:

- Always run sequentially:
  1. `minil test`
- Do not use `./Build build` / `./Build test` as the primary workflow anymore.
- Latest local verification:
  - `minil test`
  - `13 files / 182 tests / PASS`

## XS Memory Rule

When creating a temporary `SV` and passing it to another helper, the caller
owns that temporary and must release it unless ownership is explicitly
transferred.

Practical rule:

- if a call site does `newSVsv(...)`, `newSVpvf(...)`, or `newRV_noinc(...)`
  only to pass the value into another function, the call site is responsible
  for deciding whether that temporary must be `SvREFCNT_dec(...)`'d after the
  callee returns
- do not assume `gql_execution_call_*` helpers consume ownership unless that is
  documented explicitly

## Memory Leak Check

- Leak-check harness: `perl util/leak-check.pl`
- Backend policy:
  - macOS: `leaks`
  - other platforms: `asan`
- Latest run on 2026-04-05:
  - `parser_graphqljs`: `0 leaks`
  - `xs_smoke`: `0 leaks`
  - `execution`: `0 leaks`
  - `promise`: `0 leaks`
- Detailed usage and notes: `docs/memory-leak-check.md`

## Next Work

Execution is now the active compatibility surface and the public path already
prefers XS.

Key constraint:

- upstream `GraphQL::Execution` cannot be reused directly as the public entry
  point because it type-checks against upstream `GraphQL::Schema`.
- Houtou runtime helpers should stop calling upstream execution internals and
  instead call Houtou-owned execution helpers.

Recent benchmark snapshot:

- `simple_scalar`
  - `houtou_xs_ast`: about `120k/s` to `126k/s`
  - `upstream_ast`: about `40k/s` to `44k/s`
- `nested_variable_object`
  - `houtou_xs_ast`: about `70k/s`
  - `upstream_ast`: about `25k/s`
- `list_of_objects`
  - `houtou_xs_ast`: about `49.0k/s`
  - `upstream_ast`: about `17.9k/s`
- `abstract_with_fragment`
  - `houtou_xs_ast`: about `38.6k/s`
  - `upstream_ast`: about `24.0k/s`
- `async_scalar`
  - `houtou_facade_ast`: about `74.7k/s`
  - `upstream_ast`: about `42.2k/s`
- `async_list`
  - `houtou_facade_ast`: about `41.5k/s`
  - `upstream_ast`: about `26.2k/s`

Recent PP bridge profile snapshot (`HOUTOU_PROFILE_PP_BRIDGE=1`):

- `async_scalar`
  - `variables_apply_defaults=0`
  - `execute_prepared_context=0`
  - `complete_value_catching_error=0`
- `async_list`
  - `variables_apply_defaults=0`
  - `execute_prepared_context=0`
  - `complete_value_catching_error=0`

Immediate next step on `ir-direct-execution`:

- benchmark `execute_prepared_ir_xs(...)` against the existing string-query path
- reduce the remaining front-end bridge cost so root field execution can stay
  AST-free deeper into nested execution
- replace wrapper-level fallback shims with cleaner XS-side defaults where safe

Immediate next step on `main`:

- continue shrinking complex object/list completion fallbacks
- keep abstract/object error paths moving deeper into XS
