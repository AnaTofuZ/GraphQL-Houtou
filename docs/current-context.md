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

Still delegated to PP helpers:

- resolve info construction
- argument coercion
- resolver invocation
- value completion
- final hash merge

## Testing Snapshot

Latest local verification:

- `./Build build`
- `./Build test`
- `12 files / 146 tests / PASS`

## Next Work

Execution is now the active compatibility surface and the public path already
prefers XS.

Key constraint:

- upstream `GraphQL::Execution` cannot be reused directly as the public entry
  point because it type-checks against upstream `GraphQL::Schema`.
- Houtou runtime helpers should stop calling upstream execution internals and
  instead call Houtou-owned execution helpers.

Immediate next step:

- move `_build_resolve_info`, `_resolve_field_value_or_error`, and
  `_get_argument_values` from `GraphQL::Houtou::Execution::PP` into
  `src/houtou_xs/execution.h`
- keep completion in PP until resolver and coercion boundaries are cleaner
