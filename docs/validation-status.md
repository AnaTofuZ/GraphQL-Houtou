# Validation Status

Last updated: 2026-04-05

This note records the current state of `GraphQL::Houtou` validation work.
It exists so validation can be deprioritized without losing the current
 migration point.

## Current Architecture

- public entrypoint: `GraphQL::Houtou::Validation`
- XS entrypoint: `GraphQL::Houtou::XS::Validation::validate_xs`
- PP implementation: `GraphQL::Houtou::Validation::PP`

The public facade prefers XS when available. The XS layer currently owns
selected validation rules and then delegates the remaining work to the PP
validator through `validate_prepared`.

## Rules Currently Implemented In XS

- no operations supplied
- operation name uniqueness
- lone anonymous operation
- subscription single root field
- fragment cycle detection

These rules are executed in `src/houtou_xs/validation.h`.

## Rules Still Running In PP

- root operation type existence
- variable definitions are input types
- undefined variable use
- field existence
- argument existence and required arguments
- fragment target existence
- fragment spread type compatibility
- inline fragment type compatibility
- directive existence, location, and uniqueness
- input object field validation

These still run in `lib/GraphQL/Houtou/Validation/PP.pm`.

## Integration Strategy

The current transition pattern is:

1. parse/coerce document once
2. compile schema once
3. run selected XS rules
4. pass seeded errors and skip flags into PP
5. let PP run the remaining rules

This keeps error ordering close to the PP implementation while allowing rule
 migration one piece at a time.

## Current Priority

Validation is no longer the highest-priority workstream for this repository.
The current implementation is considered sufficient for now, and further rule
 migration is intentionally deprioritized.

That means:

- keep the existing XS/PP split working
- do not spend more time moving minor rules into XS unless needed for a real
  workload
- shift focus to other compatibility surfaces such as introspection,
  execution, and subscription

## Verification

Current verification command:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5/darwin-2level ./Build test
```

Current result at the time of this note:

- `9 files / 130 tests / PASS`
