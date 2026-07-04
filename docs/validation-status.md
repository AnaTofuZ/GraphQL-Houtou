# Validation Status

Last updated: 2026-04-27

This note records the current state of `GraphQL::Houtou` validation work.
It exists so validation can be deprioritized without losing the current
 migration point.

## Current Architecture

- public entrypoint: `GraphQL::Houtou::Validation`
- XS bundle owner: `GraphQL::Houtou::_bootstrap_xs`
- XSUB package: `GraphQL::Houtou::XS::Validation::validate_xs`
- native implementation: `src/validation.h`

The public facade bootstraps the shared XS bundle through `GraphQL::Houtou`
and then calls the validation XSUB package directly. The previous internal PP
bridge has been removed from the mainline.

## Rules Currently Implemented In XS

- no operations supplied
- operation name uniqueness
- lone anonymous operation
- subscription single root field
- fragment cycle detection
- root operation type existence
- variable definitions are input types
- undefined variable use
- field existence
- argument existence and required arguments
- fragment target existence
- fragment spread type compatibility
- inline fragment type compatibility
- input object field validation

These rules now execute directly in `src/validation.h`.

## Schema Build-Time Validation (2026-07-04)

Query validation above is separate from schema validation. Schema-level
checks now run once per schema in `GraphQL::Houtou::Schema`:

- public surface: `$schema->validation_errors` (arrayref of messages) and
  `$schema->assert_valid` (dies with all messages joined)
- `compile_runtime` calls `assert_valid` once (memoized), so
  `build_runtime` / `build_native_runtime` / `execute` all fail fast on an
  invalid schema

Implemented rules:

- object/interface fields must be Output types; arguments and input object
  fields must be Input types
- objects must implement each declared interface: field presence, covariant
  field types (spec IsValidImplementationFieldType), invariant argument
  types, no extra required arguments
- union member types must be Object types (also enforced with a clear
  message in `Union->get_types`); unions and enums must be non-empty

Coverage: `t/30_schema_build_validation.t`.

## Integration Strategy

The current validation path is:

1. parse/coerce document once
2. compile schema once
3. collect operations / fragments once
4. run native rule passes directly over the coerced AST and compiled schema

The old PP bridge is no longer part of the active mainline.

## Current Priority

Validation is no longer the highest-priority workstream for this repository.
The current implementation is sufficient for the active suite, so follow-up
work should focus on:

- directive validation parity
- richer input coercion edge cases
- alignment with the runtime / VM mainline

## Verification

Current verification command:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5/darwin-2level ./Build test
```

Current result at the time of this note:

- `12 files / 156 tests / PASS`
