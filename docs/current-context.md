# Current Context

This note is the compressed handoff for the current `GraphQL::Houtou` worktree.
It should stay short enough to recover momentum quickly after context resets.

## Snapshot

- Goal has moved beyond parser-only work toward broader `GraphQL` compatibility.
- Parser / graphql-js compatibility / lazy AST materialization remain in XS and
  are stable enough for incremental work on schema, validation, introspection,
  and execution.
- XS source has been split under `src/houtou_xs/` and `lib/GraphQL/Houtou.xs`
  is now a thin entrypoint.
- Houtou now owns its public type / schema / directive / role namespaces
  instead of only subclassing upstream wrappers.

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
- `a17a659` Add global default promise hooks
- `7a5d061` Normalize promise hooks for XS execution
- `ad56343` Move promise adapter dispatch into XS
- `cabaf0f` Use XS helpers for promise hash merging
- `71d0bc7` Route promise resolve and reject through adapter hooks
- `13dcc3d` Move execution response shaping into XS
- `9050567` Move located execution errors into XS
- `88266c0` Refactor promise completion continuations

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
- deeper promise completion continuations
- promise-backed execution now keeps upstream-style `promise_code`, supports a
  global default hook set, and allows optional `then` / `is_promise` hooks so
  the caller can adapt arbitrary promise libraries without Houtou hardcoding
  backend names
- promise dispatch, list/hash merge, response shaping, and located error
  decoration are now XS-backed

## Testing Snapshot

Latest local verification:

- Always run sequentially:
  1. `./Build build`
  2. `./Build test`
- Do not run `build` and `test` in parallel.
- Latest local verification:
  - `./Build build`
  - `./Build test`
  - `13 files / 172 tests / PASS`

## Next Work

Execution is now the active compatibility surface and the public path already
prefers XS.

Key constraint:

- upstream `GraphQL::Execution` cannot be reused directly as the public entry
  point because it type-checks against upstream `GraphQL::Schema`.
- Houtou runtime helpers should stop calling upstream execution internals and
  instead call Houtou-owned execution helpers.

Immediate next step:

- benchmark practical execute workloads against upstream `GraphQL`
- keep promise-heavy execution in PP for now
- continue shrinking common-case PP fallbacks only where benchmarks justify it
- benchmark analysis shows `simple_scalar` on prebuilt AST is still limited by
  fixed overhead rather than deep execution work
- recent benchmark snapshot:
  - `simple_scalar`
    - `houtou_xs_ast`: about `40.3k/s`
    - `upstream_ast`: about `43.0k/s`
  - `nested_variable_object`
    - `houtou_xs_ast`: about `27.8k/s`
    - `upstream_ast`: about `25.5k/s`
  - `list_of_objects`
    - `houtou_xs_ast`: about `20.0k/s`
    - `upstream_ast`: about `18.1k/s`
  - `abstract_with_fragment`
    - `houtou_xs_ast`: about `19.1k/s`
    - `upstream_ast`: about `23.8k/s`
  - `async_scalar`
    - `houtou_facade_ast`: about `31.2k/s`
    - `upstream_ast`: about `42.6k/s`
- current execution-focused optimization themes are:
  - keep shrinking fixed overhead for flat AST queries
  - move abstract fragment / abstract completion deeper into XS
  - move promise completion continuations deeper into XS
  - keep adapter flexibility while treating promise hooks as pre-resolved
    execution hooks
