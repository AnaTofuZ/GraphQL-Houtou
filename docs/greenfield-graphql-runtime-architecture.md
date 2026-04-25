# Greenfield GraphQL Runtime Architecture

This document describes the architecture that would be preferable if we were
designing a new high-performance Perl GraphQL library from scratch today,
using the lessons learned from:

- the current `compiled_ir` / VM-runtime work
- repeated benchmark checkpoints on real execution paths
- experiments that failed because they only widened helper corridors without
  reducing the hot-path payload cost
- the tokenizer design lesson that the fast path should separate kind/shape
  from payload materialization and avoid allocating values that later stages do
  not actually need

The goal is not "make the current mixed executor slightly faster".
The goal is:

- keep Perl-facing API compatibility where users interact with the library
- move the hot runtime to a native execution engine
- delay Perl object materialization until an API boundary truly requires it
- keep the runtime's internal currency native, small, and specialized
- not design around a Pure Perl fallback for the hot runtime

## Design Principles

### 1. Cache execution plans, not resolver results

Resolver return values are request-local and object-local. They are rarely good
cache targets.

The valuable cache targets are:

- schema metadata
- field metadata
- abstract-dispatch metadata
- resolver-call shape
- completion family
- lowered execution program

In other words, the runtime should cache *how to execute*, not *what a field
returned last time*.

### 2. Kind first, payload later

The runtime should first decide:

- which family it is in
- which dispatch shape applies
- whether the result is direct, object, list, promise, or fallback

Only after that should it materialize payload into Perl-facing objects.

This is the same general lesson that appears in high-performance tokenizer
work: token kind and token value should not be eagerly bundled together if the
hot path often needs only the kind.

In execution terms:

- completion family is the "kind"
- scalar/object/list/abstract payload is the "value"
- the runtime should not eagerly bundle them into a Perl envelope if the next
  stage only needs the family discriminator
- promise presence should also be treated as a first-class kind transition,
  not as a reason to immediately rebuild Perl response envelopes

The same rule applies to resolver metadata:

- callbacks should receive an `info` surface that is compatible enough for
  user code
- but `path`, `parent_type`, `return_type`, `schema`, and similar data should
  be materialized lazily behind that surface
- hot execution should treat `info` as a cold boundary object, not as part of
  the internal currency
- even the lazy `info` wrapper should only be created when a resolver or
  abstract callback actually needs it

### 3. Keep Perl objects out of the hot path

The hot path should not use Perl envelopes like:

- `{ data => ..., errors => ... }`
- ad hoc `SV* / HV* / AV*` triples
- AST-compatible node trees

Instead it should use native structs and only cross into Perl object space at:

- response boundary
- error boundary
- promise adapter boundary
- user callback boundary

In this document, **internal currency** means the primary data representation
that hot-path helpers pass to one another. Good internal currency is not:

- `{ data => ..., errors => ... }`
- arbitrary `SV/HV/AV` tuples
- AST-compatible node trees

It is instead a small set of runtime-native structs such as:

- execution state
- cursor / slot
- field frame
- child outcome
- sync outcome
- result writer

The design target is:

- decide kind/shape first
- keep payload native as long as possible
- only materialize Perl-facing containers at a real boundary

This also implies that promise-aware execution should not fork into a fully
separate runtime shape. The same lowered program, family contracts, and
outcome structs should be reused; only the payload transport changes from
direct values to adapter-managed promises at the block / instruction boundary.

### 3.5. Do not let PP fallback shape the runtime

For a greenfield runtime, PP should not be a design constraint.

- boot-time schema compilation may still be written in Perl initially
- public API glue may still be written in Perl initially
- but the hot execution runtime should be designed as XS-first

That means:

- no duplicated "fast path" and "PP path" ownership in core runtime structs
- no generic helper layering chosen only because PP also needs it
- no requirement that internal runtime currency be representable as legacy Perl
  envelopes

If a compatibility-only PP path ever exists, it should wrap the architecture,
not determine it.

### 4. Family-owned execution beats generic helper layering

Repeated experiments showed that adding more small helper layers often makes
the code structurally cleaner but does not reliably reduce instruction count.

The preferred architecture is therefore:

- `OBJECT`
- `LIST`
- `ABSTRACT`

as first-class completion families with owned contracts, owned narrow paths,
and cold fallback escape hatches.

### 5. `is_type_of` should be a slow fallback

From a runtime perspective:

- `resolve_type` is better than `possible_types + is_type_of`
- tag-based dispatch is better than general `resolve_type`

So:

- `is_type_of` should remain for compatibility
- but the optimized runtime should treat it as a slow fallback

## High-Level Architecture

The preferred design is a five-layer system.

### 1. Public API Layer

This layer keeps the surface Perl API pleasant and stable.

It owns:

- schema/type construction
- execute/execute_sync/execute_promise style entrypoints
- promise adapter configuration
- response/error compatibility

It should not own hot-path execution logic.

### 2. Schema Compilation Layer

At application boot, schema objects should be compiled into an immutable native
schema graph.

This layer should produce:

- type graph
- field metadata
- resolver-call shape metadata
- abstract dispatch metadata
- scalar fast-path metadata
- tag-dispatch maps

This must be boot-time cacheable.

Preferred API shape:

```perl
my $schema = MyApp::Schema->build;
my $runtime_schema = $schema->compile_runtime;
```

Optional future direction:

```perl
$schema->dump_runtime_cache("var/schema.cache");
my $runtime_schema = GraphQL::Houtou::Schema->load_runtime_cache("var/schema.cache");
```

At the very least, the runtime should expose a structural artifact boundary:

```perl
my $runtime = $schema->compile_runtime;
my $descriptor = $runtime->to_struct;
my $inflated = $schema->inflate_runtime($descriptor);
```

This does not need to serialize user callbacks immediately. It is still useful
to make the immutable runtime graph exportable and reloadable as a first-class
artifact boundary.

The purpose is not to cache resolver results. The purpose is to cache the
static execution graph.

The important distinction is:

- resolver return values are request-local and generally not worth caching
- resolver *shape* and *call metadata* are boot-time assets and should be
  compiled once

The same applies to operations. The control-plane API should expose:

```perl
my $program = $runtime->compile_operation($document);
my $descriptor = $program->to_struct;
my $inflated = $runtime->inflate_operation($descriptor);
```

And the next lowering stage should also be explicit:

```perl
my $vm_program = $runtime->lower_vm_program($program);
```

That boundary is useful even before introducing a binary serializer because it
makes "compile once at boot, reuse many times during requests" a first-class
part of the runtime design.

In practical terms, the compiled operation should also be rebound to
schema-owned slot metadata before execution. The hot loop should not reconstruct
resolver and return-type metadata through hash lookups per field when an
immutable schema slot can be pointed to directly by the lowered instruction.
The same applies to abstract dispatch metadata: lowered instructions should
carry a bound dispatch descriptor so `tag_resolver`, `tag_map`,
`resolve_type`, and `possible_types` do not have to be rediscovered through
runtime-cache hash lookups per field.
Likewise, child blocks should be rebound directly onto lowered instructions so
object/list/abstract execution does not linearly search blocks by name during
the hot loop.

This leads naturally to a second artifact boundary:

- execution-lowered program
- then VM-lowered program

The first keeps source-level structure convenient for correctness work. The
second should collapse that structure into compact opcodes and immutable block
metadata that an XS-first runtime can execute directly.

### 3. Query Lowering Pipeline

The parser output should not remain the runtime's internal shape.

A preferable pipeline is:

1. parsed AST
2. normalized IR
3. typed / specialized IR
4. execution-lowered IR
5. fused VM program

Responsibilities:

- parsed AST:
  keep source fidelity only long enough for validation and diagnostics
- normalized IR:
  remove parser-specific and AST-specific baggage
- typed / specialized IR:
  resolve field types, resolver shape, abstract family, trivial completion
  flags, static argument/directive facts
- execution-lowered IR:
  build blocks, child edges, family-owned dispatch metadata, writer metadata
- fused VM program:
  compact hot-path instructions and operands for the runtime

The runtime should never rediscover information that the lowering pipeline
already knew.

Arguments should follow the same split:

- static literal arguments should be fully lowered at compile time
- dynamic arguments should remain a compact payload template
- variable-dependent payload should only be materialized at the field
  execution boundary

The execution artifact should also carry enough type metadata to coerce inputs
without rediscovering schema facts at execution time:

- variable definitions should lower to compact type descriptors
- field argument definitions should lower to compact type/default descriptors
- execution should coerce variables and arguments from those lowered
  descriptors, rather than falling back to legacy argument walkers

Operation variables should also be part of the execution artifact:

- variable definitions should be lowered onto the immutable execution program
- provided runtime variables should be merged with lowered defaults when
  execution state is created
- variable coercion should happen from those lowered descriptors when execution
  state is created

Directive handling should follow the same model:

- static `@include` / `@skip` decisions should prune selections during lowering
- dynamic `@include` / `@skip` should be preserved as compact instruction guards
- the hot runtime should evaluate only the compact guard payload, not generic
  directive nodes

For a practical web application deployment, the expected flow should be:

1. construct schema objects at boot
2. compile schema runtime graph once
3. optionally precompile common operations to lowered programs
4. execute requests against immutable schema/program artifacts

An initial public scaffold for this should look like:

```perl
my $runtime = $schema->compile_runtime;
my $program = $runtime->program;
my $root = $runtime->root_block('query');
```

The next required scaffold is operation lowering:

```perl
my $runtime = $schema->compile_runtime;
my $exec = $runtime->compile_operation('{ viewer { id name } }');
my $root_block = $exec->root_block;
```

That operation-lowered artifact should already be immutable and should not
depend on legacy AST nodes after compilation.

The first executable checkpoint after that should be a deliberately narrow
sync runtime:

```perl
my $runtime = $schema->compile_runtime;
my $program = $runtime->compile_operation('{ viewer { id } }');
my $result = $runtime->execute_operation($program);
```

Even this first executor should already use native internal currency
(`state/cursor/outcome/writer`) instead of Perl completed envelopes.

That narrow first executor should still support the core GraphQL shape families:

- object child execution
- list child execution
- abstract dispatch

For abstract dispatch, the preferred order remains:

1. `tag_resolver` / `tag_map`
2. `resolve_type`
3. `possible_types + is_type_of` as slow fallback

Internally, a greenfield runtime should own distinct structures for:

- schema graph
- lowered program
- block
- slot
- execution program
- execution block
- instruction
- execution state
- cursor
- outcome
- writer

### 4. VM Runtime Layer

The execution engine should be a VM in the practical sense:

- owned immutable program
- mutable execution state
- direct-threaded or context-threaded dispatch
- register/slot/cursor-oriented hot state

The runtime core should look more like SQLite VDBE / Lua / Xslate than a
typical Perl callback dispatcher.

#### Immutable Program

Own:

- program
- blocks
- field slots
- child block edges
- abstract dispatch tables
- specialized op families
- inline caches

Do not own:

- AST-compatible nodes
- legacy field bucket hashes
- eager resolve-info/path Perl objects

#### Mutable Runtime State

Own:

- execution state
- cursor
- current field frame
- native result writer
- promise-pending state

The hot state should be small and cache-friendly.

## Internal Currency

"Internal currency" means the primary data shape that hot helpers exchange with
each other.

In the preferred design, internal currency should be native structs such as:

- `runtime_exec_state`
- `runtime_cursor`
- `field_frame`
- `child_outcome`
- `sync_outcome`
- `result_writer`

It should **not** normally be:

- completed Perl envelopes
- generic `HV/AV/SV` bundles
- legacy field-bucket objects

### Preferred Outcome Design

The current experiments suggest that a good outcome shape should separate:

- kind
- payload
- errors

For example:

```c
enum outcome_kind {
  OUTCOME_NONE,
  OUTCOME_DIRECT_SCALAR,
  OUTCOME_DIRECT_OBJECT,
  OUTCOME_DIRECT_LIST,
  OUTCOME_PROMISE,
  OUTCOME_FALLBACK_COMPLETED
};
```

With payload owned separately:

- `SV *scalar_sv`
- `HV *object_hv`
- `AV *list_av`
- `SV *completed_sv` only for cold fallback
- `AV *errors_av`

The important part is that `completed_sv` is cold-path state, not the default
transport shape.

## Completion Families

The runtime should have explicit completion families:

- `COMPLETE_OBJECT`
- `COMPLETE_LIST`
- `COMPLETE_ABSTRACT_TAG`
- `COMPLETE_ABSTRACT_RESOLVE_TYPE`
- `COMPLETE_ABSTRACT_POSSIBLE_TYPES`
- `COMPLETE_GENERIC`

These are not just enum labels. Each family should own:

- its narrow sync happy path
- its child-plan execution strategy
- its native outcome production
- its cold fallback escape hatch

The generic family should be the exception, not the main path.

## Abstract Dispatch

The best abstract-dispatch ladder is:

1. direct tag dispatch
2. `resolve_type`
3. `possible_types + is_type_of`

### Recommended Public API

Object side:

- `runtime_tag`

Abstract side:

- `tag_resolver`
- `tag_map`

This is preferable to pushing users toward `is_type_of`.

### Why tags are better

- no total `possible_types` scan
- no repeated object callback probing
- better fit for compile-time lowering
- easier to lower into a dedicated VM op such as
  `DISPATCH_ABSTRACT_BY_TAG`

### `resolve_type`

`resolve_type` remains important, but it should be treated as:

- a callback-shaped abstract dispatch
- not the only optimized path

Its post-resolution corridor must still stay native:

`resolve_type -> concrete type -> object family -> child block`

### `is_type_of`

`is_type_of` remains for compatibility, but should be documented and treated
as a slow fallback.

## VM Program Shape

The VM should execute `program -> block -> slot -> op`.

A practical op-family starting point:

- `OP_META_TYPENAME`
- `OP_RESOLVE_FIXED_EMPTY_ARGS`
- `OP_RESOLVE_FIXED_BUILD_ARGS`
- `OP_RESOLVE_CONTEXT_EMPTY_ARGS`
- `OP_RESOLVE_CONTEXT_BUILD_ARGS`
- `OP_COMPLETE_TRIVIAL`
- `OP_COMPLETE_OBJECT`
- `OP_COMPLETE_LIST`
- `OP_COMPLETE_ABSTRACT_TAG`
- `OP_COMPLETE_ABSTRACT_RESOLVE_TYPE`
- `OP_COMPLETE_ABSTRACT_POSSIBLE_TYPES`
- `OP_COMPLETE_GENERIC`
- `OP_CONSUME`
- `OP_QUEUE_PROMISE`

The op stream should already encode family/shape decisions made by lowering.

The dispatcher should use direct threading / computed goto where supported, and
a switch fallback where not supported.

## Memory and Cache Locality

For web applications and XS/C implementations, the biggest wins are usually:

- fewer heap allocations
- fewer pointer chases
- better cache locality
- fewer generic helper rebounds

This means:

- keep hot and cold metadata separate
- keep block-local immutable slot operands contiguous
- avoid wide structs that mix debug/fallback data into hot loops
- avoid temporary Perl envelopes inside the hot path

This is more important than syscall reduction for the execution engine.

Syscalls matter for I/O-heavy subsystems. GraphQL execution is mostly CPU,
allocation, and dispatch.

## Promise and Async Boundaries

Promise support should remain externally compatible, but internally:

- sync results should stay entirely native until finalization
- pending promises should be captured in native pending-entry arrays
- promise merge should be delayed and isolated at the boundary

The runtime should not force sync paths to carry promise-shaped payloads.

## ResolveInfo, Path, and Errors

These should all be boundary-oriented and lazy.

### ResolveInfo

- build only when resolver code actually needs it
- share a base where possible
- never make it the hot-path internal currency

### Path

- native chain / segment stack internally
- Perl array materialization only on error or explicit `info.path` need

### Errors

- keep native error sink / aggregation as long as possible
- Perl error object creation only at the reporting boundary
- resolver and abstract-dispatch exceptions should first become lightweight
  native error records carrying a path chain, not immediate Perl hashes

## Web Application Model

The preferred deployment model is:

- schema compiled at boot
- query compiled at boot or lazy-compiled and cached
- request holds only execution-local mutable state

This works especially well with prefork servers, because immutable schema
graphs and lowered programs become natural shared memory candidates after fork.

## Module Split

If designed from scratch, the codebase should likely split along these lines:

- `Schema::Frontend`
  - user-facing schema/type API
- `Schema::Compiler`
  - boot-time schema graph lowering
- `Query::Parser`
  - parser only
- `Query::Validator`
  - validator only
- `IR::Lowering`
  - normalized/typed/execution lowering pipeline
- `Runtime::Program`
  - immutable program/block/slot/op ownership
- `Runtime::VM`
  - dispatch loop and state machine
- `Runtime::Families`
  - object/list/abstract family logic
- `Runtime::Writer`
  - native result writer and finalization
- `Runtime::Bridge`
  - lazy ResolveInfo/path/error/promise/response materialization

This is preferable to a design where parser, validator, lowering, executor,
and Perl compatibility helpers all share the same internal objects.

## What The Current Work Suggests Most Strongly

From the existing experiments, the strongest takeaways are:

1. ownership cleanup is useful, but helper layering alone does not buy enough
2. generic completion fallback frequency matters more than small lookup wins
3. list item-level special cases are often weaker than family-level rewrites
4. `resolve_type` micro-optimization is not the main lever
5. keeping the internal currency native is the core rule

That means a clean-slate implementation should optimize for:

- specialized family ownership
- lowered execution programs
- native internal currency
- delayed Perl materialization
- boot-time schema/runtime compilation

and should explicitly *not* optimize around preserving legacy internal shapes.

## Practical Recommendation

If the project were restarted from zero, the best architecture would be:

- Perl-facing schema and execution API
- boot-time native schema graph compilation
- multi-stage IR lowering
- VM-style runtime with direct-threaded dispatch
- family-owned completion contracts
- native internal currency
- delayed materialization at the public boundary
- `runtime_tag` / `tag_resolver` / `tag_map` as the preferred abstract
  discriminator path
- `is_type_of` retained only as a slow compatibility fallback

This is the architecture most likely to produce a fast Perl GraphQL library,
not just a slightly optimized Perl GraphQL executor.
