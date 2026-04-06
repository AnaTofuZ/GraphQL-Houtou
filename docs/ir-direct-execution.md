# IR Direct Execution

`GraphQL::Houtou` currently parses executable documents into an arena-backed C
IR and then materializes a graphql-perl compatible AST before execution.

That keeps parser compatibility high, but it means string-based execution still
pays for:

- IR parse
- Perl AST materialization
- execution context build from that AST

When the caller does not need to inspect or mutate the AST, the AST
materialization step is pure overhead.

## Design Goal

Add an internal execution path that can walk executable IR directly without
duplicating the whole execution engine or changing the public AST contract.

Principles:

- keep the public parser and AST APIs unchanged
- keep the existing XS execution hot paths reusable
- do not fork business logic into a second completely independent executor
- introduce IR-direct execution in small internal stages

## Current Groundwork

The codebase now has a minimal prepared executable IR handle:

- `GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs($source)`
- `GraphQL::Houtou::XS::Execution::_prepared_executable_ir_stats_xs($handle)`

This handle owns:

- the parsed `gql_ir_document_t`
- a retained copy of the source `SV`

It is intentionally internal for now. The purpose is to establish safe
ownership and lifecycle before adding execution logic on top.

## Reuse Strategy

Avoid a second full executor.

Instead, the long-term direction is:

1. parse executable source into IR
2. build a prepared execution context directly from IR
3. feed the existing XS field execution / completion machinery with
   IR-derived structures

This keeps reuse focused on:

- argument coercion
- resolver invocation
- completion
- promise handling
- response shaping

The new work should be limited to the front-end pieces that currently assume a
graphql-perl AST:

- operation selection
- fragment indexing
- variable definition extraction
- field / directive / selection traversal

## Planned Stages

### Stage 1

Internal handle and ownership only.

Status: landed.

### Stage 2

Build an IR-side prepared context for executable documents:

- operation list
- fragment map
- variable definitions
- top-level selection set

The output should be the smallest structure needed by the current XS execution
engine, not a second public AST.

### Stage 3

Add an internal string-query fast path:

- if the input is a source string
- and the request does not need AST exposure
- execute from IR directly

AST input continues to use the current path.

### Stage 4

Optionally expose a prepared-query API, for example:

- `prepare($query)`
- `execute_prepared($schema, $prepared, ...)`

Only after the internal path has stabilized.

## Complexity Guardrails

To keep this maintainable:

- do not add a second copy of resolver/completion logic
- do not add a second public AST shape
- prefer shared helper functions over AST-specific and IR-specific versions
- keep IR-direct logic isolated to the execution front-end boundary
