# Production release audit (2026-07-18)

## Decision

The current tree is suitable for a high-performance preview release, but it
should not yet be presented as ready for an untrusted, high-traffic public
GraphQL endpoint. The main remaining release blocker is incomplete executable
document validation. Runtime performance and the XS robustness controls are
already substantially stronger than the older readiness notes suggest.

## Verified baseline

- The complete local suite passes on Perl 5.44 / macOS arm64: 45 files and
  403 tests.
- The normal CI matrix covers Perl 5.24 through 5.42 on Linux.
- Robustness CI includes ASan with hash-seed sweeping, parser fuzzing, an RSS
  soak gate, full-suite Valgrind, compiler warnings, and XS ownership linting.
- Request errors, result coercion, Non-Null propagation, parser nesting and
  token limits, request-body limits, and alias/node limits are implemented.
- POD syntax and META.json validation pass locally.

## Release blockers

### P0-1: complete executable document validation

The validator implements important structural rules, but does not yet cover
the full GraphQL executable-document rule set. Concrete probes accepted the
following invalid documents without request errors:

```graphql
{ user }
query Q($x: Int, $x: Int) { hello(x: $x) }
{ hello(x: 1, x: 2) }
fragment F on Query { hello }
query Q { hello }
query Q($x: Int) { hello }
```

The validation work should be completed against the graphql-js validation
corpus (adapted as fixtures), including at least:

- leaf fields must not have selection sets and composite fields must have one;
- unique variable, argument, and fragment names;
- no unused variables and fragments;
- variables in allowed positions for ordinary field arguments as well as
  directives;
- values of correct type;
- overlapping fields can be merged;
- remaining fragment and subscription-root edge cases.

The canonical AST currently stores arguments and variable definitions in
hashes. Duplicate names are overwritten during parsing, so the two uniqueness
rules require either parser-time duplicate metadata or a backward-compatible
ordered representation in addition to the existing hashes.

Implementation progress:

- completed: unique fragment names;
- completed: leaf field selections / composite field subselections;
- completed: no unused variables, including variables used through fragments;
- completed: no unused fragments, using transitive operation reachability;
- completed: duplicate argument/variable detection through a validation-only
  parser error sink, without changing the public canonical AST;
- completed: unused variable/fragment graph traversal moved from Pure Perl to
  XS; cached documents still bypass validation entirely;
- performance check: the existing kitchen-sink parser benchmark measured
  about 67k parses/s with locations and 84k parses/s without locations on the
  development macOS arm64 host after these changes;
- completed: variables in allowed positions for direct arguments, list items,
  and input object fields, including default-value exceptions, in XS;
- completed: built-in scalar literal validation uses SV flags directly in
  XS, avoiding a Perl method call per literal;
- completed: Enum literal shape and membership validation uses direct XS hash
  lookup against the compiled enum descriptor;
- completed: variable default values are checked against their declared input
  types using the XS literal validator;
- completed: field merging conflicts are grouped by response key, expanded
  through named and inline fragments, and compared only across overlapping
  runtime type conditions in XS;
- performance: identical fields in a response-key bucket collapse to one
  representative per type condition, and comparison stops after the first
  conflict for that key, preventing quadratic same-key duplicate floods;
- completed: field response shape validation compares Non-Null/List wrappers
  and leaf type identity in XS, including mutually-exclusive type conditions;
- completed: compatible composite fields recursively validate their combined
  subfield selections in XS rather than validating each occurrence in isolation;
- performance: composite occurrences retain a linear merge list while semantic
  duplicates share one comparison representative, avoiding pairwise recursion;
- next: custom scalar literal API, complete field merging, and the remaining
  rules.

### P0-2: cost control beyond AST node count

`max_depth` and `max_nodes` defend against nesting and alias flooding, but a
small query can still request very large lists at several levels. Before a
public production claim, add weighted field cost/list multipliers or document
and enforce strict pagination limits in schema/resolver code.

### P0-3: production-shaped load qualification

Run a prefork PSGI server with a real database pool and request-scoped
DataLoaders. Record cache-hit/miss mixtures, p50/p95/p99 latency, RSS and CPU
under concurrent load, slow/erroring resolvers, graceful restart, and a long
soak. Existing microbenchmarks establish excellent engine throughput but do
not yet constitute capacity planning for a deployed service.

## Release preparation

- Replace the template `Changes` entry with the actual 0.01 history.
- Consolidate stale status documents; several older files describe features
  now implemented as missing.
- Add a production deployment guide covering prefork operation, timeouts,
  pagination/cost policy, rate limiting, logging, GraphiQL/CSP, and shutdown.
- State unsupported features prominently: ithreads, GET query execution,
  subscriptions, defer/stream, Federation, SDL type extensions, generic
  promise adapters, and variables with fixed bundles.
- Add macOS and Perl 5.44 jobs plus distribution/POD/minimum-version tests.
- Consider GET query execution and stricter GraphQL-over-HTTP content
  negotiation for broad client and CDN compatibility.

## Recommended order

1. Complete validation and import a conformance corpus.
2. Add production cost controls.
3. Qualify a realistic PSGI + database deployment under concurrent load.
4. Finish Changes, user-facing documentation, distribution tests, and a
   release candidate before publishing 0.01 to CPAN.
