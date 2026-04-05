# Current Context

Last updated: 2026-04-05

This file is a handoff note for continuing work in `GraphQL-Houtou`.
It now covers the current parser status, the Houtou-owned schema/type
migration, the PP/XS facade layout, and the next migration steps before
moving deeper into XS-backed validation and execution.

## Current State

- `graphql-js` parser runtime is XS-first and keeps `loc` resolution in XS.
- executable `graphql-js` parsing is `source -> IR -> graphql-js AST`.
- executable `graphql-js` AST building now lazily materializes:
  - `arguments`
  - `directives`
  - `variableDefinitions`
  - object fields
- lazy array materialization has an XS fast path and an explicit Perl/XS
  contract guarded by tests.
- parser/lazy-state safety fixes are in place:
  - source buffer lifetime is retained by lazy state
  - temporary parser SV leaks identified in review were fixed
- XS implementation has been split into `src/houtou_xs/*.h` fragments and
  `minil.toml` now points `c_source` at `src`.
- schema compilation now has a public facade with:
  - XS-preferred path
  - PP fallback path
- validation now has a public facade with:
  - XS-preferred path
  - PP fallback path
- Houtou-owned public type classes now exist for:
  - `Type`
  - `Type::List`
  - `Type::NonNull`
  - `Type::Scalar`
  - `Type::Enum`
  - `Type::InputObject`
  - `Type::Object`
  - `Type::Interface`
  - `Type::Union`
- Houtou-owned public schema/directive classes now exist:
  - `GraphQL::Houtou::Schema`
  - `GraphQL::Houtou::Directive`
- `GraphQL::Houtou::Type::Library` is now Houtou-owned instead of wrapping
  upstream `GraphQL::Type::Library`.

## Recent Commits

- `1812f6b` `Split XS sources into src fragments`
- `02f2b67` `Add initial schema compiler`
- `d4656f0` `Split schema compiler into XS and PP paths`
- `d3df5fa` `Add initial validation facade and rules`
- `1f77e36` `Extend validation for subscriptions and fragments`
- `b85b776` `Add Houtou-owned GraphQL type wrappers`
- `70b94cb` `Move type library into Houtou namespace`
- `791b6c8` `Implement Houtou list, non-null, and scalar types`
- `b061db1` `Implement Houtou enum and input object types`
- `89547bd` `Implement Houtou object, interface, and union types`

## Dirty Worktree At Save Time

The following migration work was present but not yet committed when this
context file was updated:

- `GraphQL::Houtou::Directive` converted from upstream subclass to standalone
  Houtou implementation
- `GraphQL::Houtou::Schema` converted from upstream subclass to standalone
  Houtou implementation
- PP/XS schema compiler updated to accept both upstream and Houtou schema
  objects during transition
- schema compiler tests updated to assert that Houtou schema/directive objects
  no longer use upstream classes

## Build And Test

Build:

```sh
./Build build
```

Full test:

```sh
env PERL5LIB=/Users/anatofuz/src/github.com/graphql-perl/GraphQL-Houtou/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/lib:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5:/Users/anatofuz/src/github.com/graphql-perl/graphql-perl/local/lib/perl5/darwin-2level ./Build test
```

Current result:

- `9 files / 116 tests / PASS`

## Current Validation Coverage

The PP validator currently checks:

- operation name uniqueness
- lone anonymous operation
- root operation type existence
- variable definitions use input types
- undefined variable use
- field existence
- unknown and missing required arguments
- fragment target existence
- fragment cycle detection
- directive existence, location, and uniqueness
- subscription single root field
- fragment spread type compatibility
- inline fragment type compatibility

## Remaining Upstream GraphQL Dependencies

The largest remaining upstream dependency in Houtou public types is the role
layer. Houtou classes still consume upstream roles such as:

- `GraphQL::Role::Input`
- `GraphQL::Role::Output`
- `GraphQL::Role::Composite`
- `GraphQL::Role::Leaf`
- `GraphQL::Role::Abstract`
- `GraphQL::Role::Named`
- `GraphQL::Role::FieldsEither`
- `GraphQL::Role::FieldsInput`
- `GraphQL::Role::FieldsOutput`
- `GraphQL::Role::FieldDeprecation`
- `GraphQL::Role::HashMappable`

Related runtime checks still inspect upstream role names via `DOES(...)` and
Type::Tiny `ConsumerOf[...]` constraints.

## Next Work

Priority order at this point:

1. migrate `GraphQL::Role::*` usage into `GraphQL::Houtou::Role::*`
2. update Houtou type/schema/compiler/validator code to depend on Houtou roles
3. add tests that lock the Houtou role contract in place
4. only after the role migration stabilizes, begin XS validation work
5. after validation, move toward execution/subscription compatibility work

## Notes

- keep parser/runtime verification using `./Build build` and `./Build test`
- use PP implementations as behavior oracles before moving hot paths to XS
- preserve compatibility with upstream `GraphQL` inputs during transition,
  but keep the public Houtou namespace authoritative
