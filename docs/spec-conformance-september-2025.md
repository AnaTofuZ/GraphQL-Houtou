# GraphQL September 2025 conformance matrix

Audit date: 2026-07-18

Baseline: [GraphQL Specification, September 2025](https://spec.graphql.org/September2025/).

This document records what GraphQL::Houtou 0.01 can accurately claim. It is
an implementation index, not a claim that passing the local suite proves every
normative example in the specification.

Status meanings:

- **Implemented**: the feature is implemented and has direct regression tests.
- **Partial**: the main path works, but a normative case or public surface is
  missing.
- **Unsupported**: intentionally unavailable in the 0.01 profile.
- **Not applicable**: grammar or tooling that is not consumed by the server
  execution API.

## Release conformance statement

The accurate 0.01 claim is:

> GraphQL::Houtou implements the September 2025 query and mutation execution
> profile, modern introspection, and all stable executable-document validation
> rules. Subscription execution is unsupported. Type-system validation is
> partial and must not be described as fully specification-conforming until
> the gaps below are closed.

The project must not claim complete September 2025 conformance for 0.01 while
Section 3 validation and Section 6 subscription execution remain incomplete.

## Summary

| Specification area | Status | Primary evidence | Remaining work |
| --- | --- | --- | --- |
| Section 2: Language | Partial | `t/45_parser_conformance.t`, parser adversarial/fuzz suites | Executable descriptions; schema-coordinate parser API |
| Section 3: Type System | Partial | `t/30_schema_build_validation.t`, `t/31_build_schema.t`, `t/32_print_schema.t`, `t/33_oneof_input_objects.t` | Complete normative schema validation listed below |
| Section 4: Introspection | Implemented | `t/26_deprecated_locations.t`, `t/27_directive_runtime.t`, `t/28_modern_introspection.t`, `t/46_introspection_meta_types.t` | Keep canonical introspection query in compatibility CI |
| Section 5: Validation | Implemented | `docs/validation-conformance.md`, `t/08_validation.t` | No known stable-rule gap |
| Section 6: Execution | Partial | `t/23_mutation_serial.t`, `t/44_lane_parity.t`, `t/47_request_validation.t`, `t/49_result_coercion.t`, `t/50_nonnull_propagation.t` | Subscription source/response streams and unsubscribe |
| Section 7: Response | Partial | `t/35_execute_to_json.t`, `t/48_request_error_envelope.t`, `t/49_result_coercion.t` | Response streams; ordered serialization is guaranteed only by `execute_to_json` |

## Section 2: Language

| Requirement group | Status | Notes and evidence |
| --- | --- | --- |
| Source text, ignored tokens, punctuators, names | Implemented | XS lexer/parser; Unicode escape and adversarial coverage in `t/45_parser_conformance.t` and `t/53_parser_adversarial.t` |
| Operations, selection sets, fields, aliases, arguments | Implemented | Parser and execution suites, including aliases and variables |
| Fragments and inline fragments | Implemented | Parser, validation, and canonical application suites |
| Input values and type references | Implemented | Literal validation, coercion, list/non-null, enum, input object, and OneOf coverage |
| Executable directives, including variable definitions | Implemented | `t/08_validation.t`, `t/27_directive_runtime.t` |
| Type-system definitions | Implemented | `build_schema` and `print_schema` coverage |
| Type-system extensions | Implemented in PR #60 | Object, interface, union, enum, input object, scalar, and schema extensions; empty extensions rejected in XS |
| Descriptions on type-system definitions | Implemented | SDL builder/printer and introspection preserve descriptions |
| Descriptions on executable definitions | **Unsupported** | September 2025 permits descriptions on operations, fragments, and variable definitions. The parser currently routes a leading string to the type-system parser. |
| Schema-coordinate syntax | Not applicable to execution; unsupported as tooling API | Houtou does not expose a `parse_schema_coordinate` utility. This does not affect request execution, but prevents claiming the complete language/tooling surface. |

## Section 3: Type System

### Implemented surface

| Requirement group | Status | Notes and evidence |
| --- | --- | --- |
| Schema and root operation construction | Partial | Explicit and conventional root names work; root-type validation gaps remain below |
| Scalar, object, interface, union, enum, input object | Implemented | Construction, printing, introspection, and runtime compilation covered |
| List and Non-Null wrappers | Implemented | Input and result coercion suites |
| Interface implementation covariance | Implemented | `t/30_schema_build_validation.t` |
| Interface implementing interface | Implemented in PR #60 | Includes explicit inheritance validation and transitive possible types |
| OneOf input objects | Implemented | Schema and request validation in `t/33_oneof_input_objects.t` |
| `@skip`, `@include`, `@deprecated`, `@specifiedBy`, `@oneOf` | Implemented | Definition, introspection, and applicable runtime behavior covered |
| Repeatable directives | Implemented | Executable validation and extension merge checks |
| Type-system extensions | Implemented in PR #60 | Merged in O(n) at schema build time before runtime compilation |

### Known schema-validation gaps

The schema validator is not yet a complete implementation of the normative
validation rules distributed throughout Section 3. At minimum, the following
must be added and tested:

| Gap | Current risk |
| --- | --- |
| Root operation types must be Object types and must be distinct | Implemented on `schema-validation-conformance` |
| Reserved `__` names outside introspection | Implemented for types, fields, arguments, enum values, and directives on `schema-validation-conformance` |
| Duplicate SDL fields, arguments, enum values, and input fields within one definition | Implemented with XS parser diagnostics on `schema-validation-conformance` |
| Input-object circular references through an unbroken chain of singular Non-Null fields | Implemented on `schema-validation-conformance` with an O(V+E) schema-build DFS |
| Schema default values must be valid for their declared input types | Invalid argument/input-field defaults are not comprehensively checked at schema build time |
| Type-system directives must be defined, valid at their location, and unique when non-repeatable | Executable directives are fully validated; applied SDL directives are not yet covered at the same level |
| Required arguments and input fields must not be deprecated | Not comprehensively enforced by schema validation |
| Complete uniqueness and non-empty rules for all programmatically constructed types | Some rules exist for unions, enums, and OneOf, but Section 3 is not exhaustively mapped |

These are release-conformance work, even if applications normally construct a
trusted schema at process startup. A malformed schema is an operator error, but
it can still cause inconsistent introspection or runtime behavior.

## Section 4: Introspection

| Requirement group | Status | Notes and evidence |
| --- | --- | --- |
| `__typename`, `__schema`, `__type` | Implemented | Public and native runtime tests |
| `__Schema`, `__Type`, `__Field`, `__InputValue`, `__EnumValue`, `__Directive` | Implemented | Meta types no longer depend on upstream graphql-perl classes |
| `isRepeatable`, `specifiedByURL`, `isOneOf` | Implemented | `t/28_modern_introspection.t` |
| Deprecated arguments and input fields with `includeDeprecated` | Implemented | `t/26_deprecated_locations.t`, `t/28_modern_introspection.t` |
| Canonical introspection query | Implemented | Runs in both public and native runtime paths |

## Section 5: Executable-document validation

All stable rules are mapped individually in
`docs/validation-conformance.md`. Validation runs in XS and covers executable
definitions, operation rules, field selection and merging, fragments,
arguments, values, directives, and variables.

Subscription document validation is included: operation type existence,
single-root-field grouping, and the prohibition on introspection root fields
are enforced even though subscription execution is unsupported.

## Section 6: Execution

| Requirement group | Status | Notes and evidence |
| --- | --- | --- |
| Request validation before execution | Implemented | Request errors do not execute resolvers |
| Variable coercion | Implemented | Request-error behavior in `t/48_request_error_envelope.t` |
| Query execution | Implemented | Sync, async, native program, bundle, and JSON lanes |
| Mutation serial execution | Implemented | Sync and promise ordering in `t/23_mutation_serial.t` |
| Field collection and directive inclusion | Implemented | Fragment, alias, `@skip`, and `@include` suites |
| Argument coercion and value resolution | Implemented | Input and resolver suites |
| Value completion and Non-Null propagation | Implemented | `t/49_result_coercion.t`, `t/50_nonnull_propagation.t` |
| Execution errors | Implemented | Paths, partial data, resolver exceptions, and request/execution taxonomy |
| Subscription source event stream | **Unsupported** | No subscribe resolver or async event-stream abstraction |
| Subscription response stream | **Unsupported** | No event-by-event execution API |
| Unsubscribe | **Unsupported** | No cancellation lifecycle |

### Subscription decision for 0.01

Subscription execution should remain unsupported in 0.01.

The GraphQL core subscription algorithms are transport-independent, but a
useful production implementation also needs an asynchronous event source,
cancellation, bounded buffering, backpressure, and a WebSocket or SSE adapter.
Traditional prefork PSGI is a poor default host for this workload:

- each long-lived connection occupies worker capacity unless the server has a
  compatible evented streaming implementation;
- `psgi.streaming` support and disconnect behavior vary by PSGI server;
- database and pub/sub connections need lifetimes different from ordinary
  request-scoped resources;
- an unbounded slow-consumer queue is a direct RSS exhaustion risk;
- graceful worker restart must cancel and drain active subscriptions.

Shipping a nominal subscription implementation through the ordinary PSGI
adapter would therefore conflict with the stated high-traffic production
target. The 0.01 behavior should be fail-closed:

1. Keep subscription syntax, schema roots, introspection, and validation.
2. Reject attempts to execute a subscription through `execute` or PSGI with a
   clear unsupported-operation request error.
3. Document query and mutation as the supported execution profile.
4. Design a later transport-independent `subscribe_document` API returning a
   cancellable async iterator.
5. Add an event-loop-specific WebSocket/SSE adapter separately; do not make
   prefork PSGI workers the implicit subscription runtime.

## Section 7: Response

| Requirement group | Status | Notes and evidence |
| --- | --- | --- |
| Execution result `data` and `errors` | Implemented | Public, native, and JSON lanes |
| Request error result without `data` | Implemented | `t/47_request_validation.t`, `t/48_request_error_envelope.t` |
| Error message, locations, path, extensions | Implemented | Error-object and serialization tests |
| Additional response entries | Implemented as an extensible envelope | Standard keys are preserved; arbitrary transport policy remains application-owned |
| JSON scalar and container serialization | Implemented | `t/35_execute_to_json.t`, `t/49_result_coercion.t` |
| Serialized map ordering | Partial | Direct `execute_to_json` preserves query field order. A Perl hash returned by `execute` cannot itself guarantee a later encoder's key order. |
| Response stream | **Unsupported** | Depends on subscription execution |

## Features outside the stable core baseline

The following are intentionally excluded from this conformance claim:

- `@defer` and `@stream` incremental delivery;
- GraphQL over HTTP details such as GET execution and strict media negotiation;
- WebSocket and SSE subscription protocols;
- Apollo Federation and APQ;
- Relay Connection conventions;
- multipart file upload.

These may matter for ecosystem compatibility, but they are not evidence for or
against the query/mutation core profile stated above.

## Recommended conformance order

1. Merge PR #60 and retain its type-system extension tests.
2. Complete Section 3 schema validation, starting with duplicate preservation,
   root types, reserved names, input cycles, defaults, and SDL directives.
3. Add September 2025 executable descriptions to the XS parser.
4. Make subscription execution fail closed and document the 0.01 execution
   profile.
5. Add a cross-implementation corpus against graphql-js for parser, schema
   validation, coercion, execution, and introspection.
6. Re-audit this matrix before claiming full query/mutation conformance.
