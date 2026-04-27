# Runtime VM Architecture

This document describes the architecture that would be preferable if we were
designing a new high-performance Perl GraphQL library from scratch today,
using the lessons learned from:

- the current runtime / VM work
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
- tolerate temporary internal Perl compatibility modules only where legacy XS
  integration still depends on them, but do not treat them as public runtime
  surfaces

Public execution policy for this design:

- the public runtime API should prefer the native XS engine when the lowered
  program stays within the current native-safe subset
- programs outside that subset should fall back automatically to the Perl VM
- the Perl VM should remain available as an explicit validation / bring-up path
- child runtime modules should not `use` XS directly; the XS boundary should
  live at the top-level runtime/native API
- core schema/type objects should not own legacy execution behavior for the
  mainline runtime; execution belongs in the runtime/compiler/VM layers
- explicit field resolvers may opt into the native hot path with
  `resolver_mode => 'native'` when they do not require the lazy `info` ABI;
  this should be treated as a deliberate fast-path contract rather than the
  default behavior for all resolvers

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

For the lowered VM artifact this also means:

- structural opcode strings may still exist for descriptor/debug readability
- but the hot executor boundary should prefer numeric opcode/family codes
- a future XS executor should be able to inflate the descriptor directly into
  native enums and dispatch tables without reparsing string families
- child block references should also be exportable as block indexes rather than
  name lookups, so an XS executor can consume a compact native descriptor
  without rebuilding a hash-based block map first
- block-local slot tables should also be exportable, with per-op `slot_index`
  references, so repeated field metadata can be shared inside the native
  descriptor instead of duplicated across every opcode
- the schema runtime should also be exportable as a native slot catalog, so
  the VM program can reference immutable schema-level slot metadata by
  `schema_slot_index` instead of re-emitting that metadata in every block
- that native slot catalog should also carry numeric family/type codes, so a
  future XS executor can bind dispatch and completion families without
  reparsing string metadata
- in practice this means a future XS boundary should accept a bundle shaped
  like:
  - native runtime descriptor
  - native VM program descriptor
  where the runtime owns the immutable slot catalog and the VM program owns
  only per-operation block/slot/op state
- the same boundary should also support:
  - JSON dump/load of the runtime descriptor
  - JSON dump/load of the VM bundle descriptor
  - rebinding the VM bundle back to the runtime slot catalog without
    rebuilding block/slot metadata from names
  so the Perl prototype and future XS runtime share the same boot-time cache
  contract
- this boundary should also publish a stable numeric code contract for:
  - resolve families
  - completion families
  - dispatch families
  - return type kinds
  - operation types
  so XS can validate/inflate the descriptor without reparsing string family
  names in its hot path

For the VM layer this implies:

- the lowered op should carry bound dispatch family metadata
- runtime should avoid re-parsing opcode strings or rediscovering schema/block
  links in the hot loop
- runtime-only handler bindings are preferable to repeated generic branching
  when the artifact boundary can still serialize the structural opcode cleanly

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
- block frame
- child outcome
- sync outcome
- result writer

The design target is:

- decide kind/shape first
- keep payload native as long as possible
- only materialize Perl-facing containers at a real boundary

In the current runtime VM this already maps to:

- `ExecState` for process-local runtime state
- `Cursor` for current block/op/slot
- `BlockFrame` for block-local values and pending promise outcomes
- `FieldFrame` for field-local source/path/resolved value/outcome
- `Outcome` as the kind-first value carrier
- `Writer` as the final response/error sink

The next refinement after this split is also in place:

- `ExecState` provides current block/op/slot accessors
- the executor loop advances the cursor through state
- field dispatch helpers consume state-owned views instead of reaching into
  cursor internals directly
- VM ops can also carry a runtime-only `run_dispatch` binding, so the hot loop
  can jump directly to a field-family runner rather than re-deciding
  `resolve_handler` + `complete_handler` on every step
- block execution itself can be owned by `ExecState`, so child object/list/
  abstract completion reuses the same state-machine entrypoint instead of
  rebuilding a second block loop inside the executor
- field execution can also be owned by `ExecState`, so resolve/complete/error
  capture for the current field is state-driven rather than rebuilt by
  executor-local helper stacks
- child block lookup, abstract runtime-type resolution, and object-outcome
  wrapping can also be owned by `ExecState`, so object/list/abstract families
  share one state-owned corridor instead of each helper rediscovering blocks
  and abstract dispatch metadata
- resolver-adjacent cold boundaries can also be owned by `ExecState`, so
  return-type lookup, argument materialization, and lazy-info construction are
  state-owned services instead of executor-local helper work
- completion-family bodies can also be owned by `ExecState`, so scalar/object/
  list/abstract outcome construction becomes state-machine work instead of
  executor-local helper branching
- final response materialization can also be owned by `ExecState`, so
  promise-aware response envelopes and final error export are emitted from the
  same state machine that owns block and field execution
- once those boundaries move into `ExecState`, the dispatch binder itself can
  target state methods rather than executor-local family callbacks, leaving the
  executor as a thin top-level shell
- the same applies to program bootstrap:
  - a state-owned factory should build cursor/writer/promise/variable state for
    a lowered program

The same slot-first rule should also apply to immutable VM artifacts:

- `VMOp`
- `VMBlock`
- `VMProgram`

These should prefer:

- fixed slots
- opcode / family ids as primary runtime shape
- setter-based runtime binding

and treat:

- names
- debug strings
- descriptor-only payloads

as cold metadata. This keeps the Perl prototype aligned with the eventual XS
layout and avoids reintroducing hash-based artifact mutation in the hot path.

At the native boundary, these artifacts should also support a compact export:

- keep readable `to_struct` / `to_native_struct` for debug and round-trip tests
- add `to_native_compact_struct` for the actual XS entrypoint
- keep the top-level descriptor hash stable
- but encode block/op/slot payloads as arrays so XS can consume a denser
  layout with fewer hash lookups

This lets the Perl prototype preserve observability while the native boundary
already moves toward the final compact descriptor format.
  - a state-owned top-level runner should execute the root block and emit the
    final response boundary
  - the executor object can then remain as a façade/API shell rather than a
    second owner of runtime state

This also implies that promise-aware execution should not fork into a fully
separate runtime shape. The same lowered program, family contracts, and
outcome structs should be reused; only the payload transport changes from
direct values to adapter-managed promises at the block / instruction boundary.

### 3.5. Do not let PP fallback shape the runtime

For the runtime VM, PP should not be a design constraint.

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

The same lesson applies inside the VM itself:

- prefer block-owned and field-owned frames over ad hoc local hashes/arrays
- prefer state-machine ownership (`ExecState`, `Cursor`, `BlockFrame`,
  `FieldFrame`) over generic helper stacks
- keep pending promise aggregation in block-owned state, not in free
  local variables inside the executor loop

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
my $program = $runtime->compile_program($document);
my $descriptor = $program->to_struct;
my $inflated = $runtime->inflate_program($descriptor);
```

And the next lowering stage should also be explicit:

```perl
my $vm_program = $runtime->lower_vm_program($program);
```

And the next execution boundary should also be explicit:

```perl
my $result = $runtime->execute_program($vm_program, %opts);
```

The first VM checkpoint should therefore be a runnable pure-Perl
VM executor that proves the artifact boundary and family-owned block dispatch
work at all. Only after that should the hot VM loop be replaced with XS.

Even at that pure-Perl checkpoint, block-local result ownership should already
be explicit. A block executor should not rebuild ad hoc `%data`,
`@pending_names`, and `@pending_outcomes` locals per block. It should own a
dedicated block-frame object that carries:

- finalized field values
- pending promise labels
- pending outcomes

and exposes a narrow writer-facing consume boundary.

The same ownership rule should continue upward into execution state itself:

- `cursor` owns the current block/op/slot view
- `block frame` owns block-local values and pending outcomes
- `exec state` owns the current frame stack and block enter/leave lifecycle

That keeps the VM closer to a real state machine and prevents block execution
from drifting back into ad hoc local Perl aggregates.

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

In practice, the fused VM layer should already bind runtime-only hot metadata
after inflate/lowering:

- block-name lookup should become block pointer lookup
- field-name lookup should become slot pointer lookup
- opcode family dispatch should become table-driven handler dispatch

The serialized artifact still stores structural opcode data, but the in-memory
VM should not keep paying the cost of rediscovering those relationships.

The same applies to execution state:

- nested child execution should not pass block/op metadata as free arguments
- a cursor/state machine should own current block, current op, and current slot
- block entry/exit should snapshot and restore cursor state

This keeps root and child execution on the same VM-shaped control path instead
of rebuilding ad hoc helper call stacks.

At the pure-Perl VM checkpoint, the equivalent of direct-threaded dispatch is:

- structural opcodes remain serializable strings in the artifact
- but the inflated/lowered in-memory op binds runtime-only resolver and
  completion coderefs
- a dedicated `VMDispatch` phase owns those bindings rather than letting the
  executor rediscover them lazily
- execution then dispatches through those bound handlers and cursor-owned state

This keeps the artifact boundary stable while moving the hot loop closer to the
shape an XS VM will eventually use.

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
my $exec = $runtime->compile_program('{ viewer { id name } }');
my $root_block = $exec->root_block;
```

That operation-lowered artifact should already be immutable and should not
depend on legacy AST nodes after compilation.

The first executable checkpoint after that should be a deliberately narrow
sync runtime:

```perl
my $runtime = $schema->compile_runtime;
my $program = $runtime->compile_program('{ viewer { id } }');
my $result = $runtime->execute_program($program);
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

Internally, the runtime VM should own distinct structures for:

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

## Current Runtime Reboot Checkpoint

The rebooted implementation now has the first end-to-end XS execution path for
the runtime VM:

- Perl still owns schema compilation and VM lowering
- native bundle descriptors are inflated into C-owned structs
- XS now executes those native bundles directly for the first supported slice

The currently supported native execution slice is intentionally narrow:

- sync / no-promise execution
- default and explicit resolver calls
- static literal args for explicit resolvers marked `resolver_mode => 'native'`
- object child blocks
- list child blocks
- abstract dispatch through:
  - `tag_resolver`
  - `resolve_type`
  - `possible_types + is_type_of`

This checkpoint matters because it changes the architectural boundary:

- the project no longer only *describes* a VM in Perl
- it now has a real native runtime entrypoint that consumes the lowered
  program artifact directly

From here, the remaining work is no longer “how do we design a VM?” but
“how do we widen the native executor until the pure-Perl VM becomes
unnecessary for the hot path?”.

## Native Bridge Rule

The runtime/native VM should follow this boundary rule:

- child runtime modules do not import XS directly
- the top-level runtime bridge owns XS entrypoints
- serializable descriptors remain cold artifacts
- execution-only bindings are attached only at execution time

In practice this means:

- `SchemaGraph`, slots, blocks, and programs may describe native payloads
- but they should delegate native execution through the runtime bridge
- dump/load-friendly descriptor payloads must not be polluted with
  execution-only Perl objects or bindings

For static literal args, this boundary is:

- lowering stores a serializable static payload in the VM op descriptor
- native bundle inflation owns that payload in C
- each resolver call deep-clones the payload into a fresh Perl args value
- child runtime modules still do not call XS directly

This keeps the architecture coherent even after the pure-Perl VM is replaced
by the native runtime.

## Request-Time Specialization

Native execution should not require child modules to call XS directly, and it
should not force descriptor compilation to know request-local state.

The intended shape is:

- compile schema once
- lower operation to a VM program artifact
- at request time, specialize that VM program for:
  - provided variables
  - variable defaults
  - coerced args
  - dynamic include/skip guards
- only then cross the top-level native boundary

This is why request-time specialization now stays in `Runtime::NativeRuntime`
instead of trying to teach every child module to call XS:

- child modules stay language/runtime agnostic
- request-local mutation happens on a cloned VM program
- the top-level runtime bridge remains the only native execution boundary

In practice this means `Schema->execute_native(...)` should behave like
`Runtime->execute_program(engine => 'native')`, not like a raw static bundle
loader. Dynamic variables and directives are resolved before native execution,
but execution itself still happens on the native VM.

To make this usable in web applications, there should be a first-class startup
cache API:

- build a compiled runtime once at process boot
- optionally compile and cache VM programs once
- hold a loaded native runtime handle separately from request-local state
- specialize cached VM programs per request
- execute the specialized program only at the top-level native boundary

The current public wrappers for this are:

- `build_native_runtime($schema)`
- `Schema->build_native_runtime`
- `Schema->build_runtime`
- `Runtime::NativeRuntime->compile_program(...)`
- `Runtime::NativeRuntime->execute_program(...)`
- `Runtime::NativeRuntime->compile_bundle(...)`
- `Runtime::NativeRuntime->compile_bundle_descriptor(...)`
- `Runtime::NativeRuntime->load_bundle_descriptor(...)`

This keeps the control plane in Perl while ensuring child modules do not call
XS directly.

For the public hot path, the intended rule is:

- `compile_runtime(...)` remains an uncached compiler entrypoint
- `build_runtime(...)` and `build_native_runtime(...)` are boot-time cache APIs
- no-opt public execution should prefer the cached runtime graph / native wrapper
- native execution helpers such as `execute_native(...)` and
  `execute_native_bundle_descriptor(...)` should also route through the cached
  native runtime wrapper instead of rebuilding a runtime handle per request
- `clear_runtime_cache()` must invalidate:
  - schema metadata cache
  - compiled runtime graph
  - cached native runtime wrapper

This keeps the web-application mainline coherent:

- app boot: `build_runtime` / `build_native_runtime`
- request: compile or reuse VM program
- request: specialize if needed
- top-level bridge: execute on native runtime
## Public API direction

The runtime-facing public API should treat VM artifacts as the primary
execution unit.

- `compile_operation` / `compile_program`
- `inflate_operation` / `inflate_program`
- `execute_program`

These APIs should all return or consume VM programs by default.

The old lowered pre-VM artifact layer is no longer a separate runtime shape.
Callers should use only the VM-facing names:

- `compile_operation`
- `compile_program`
- `inflate_operation`
- `inflate_program`

This keeps callers off intermediate artifact shapes and makes the VM runtime
the single mainline execution model.

## Hot State And Slot-First Currency

The current hot path should prefer fixed-slot state objects over hash-shaped
Perl objects whenever the values are mutable but structurally fixed.

The first completed wave of this is:

- `Runtime::Outcome`
- `Runtime::BlockFrame`
- `Runtime::Cursor`
- `Runtime::FieldFrame`
- `Runtime::Writer`

These objects are now treated as the runtime's internal currency for the hot
path. This means:

- kind is decided first
- payload is carried separately
- writer materialization happens as late as possible
- helper boundaries should exchange slot-owned state, not ad hoc hashes

The next XS-ready wave should target immutable VM artifacts:

- `VMOp`
- `VMBlock`
- `VMProgram`

Those objects should move toward:

- fixed slot layout
- integer opcode / family ids as primary dispatch keys
- cold descriptor names retained only for serialization and debugging
