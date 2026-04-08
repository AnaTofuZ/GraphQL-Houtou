## Compiled IR VM Runtime Plan

This document defines the next execution project for `compiled_ir`.

The goal is not to incrementally optimize the current mixed executor forever.
The goal is to introduce a separate execution-lowered runtime that keeps
public API compatibility while dropping internal compatibility with legacy AST
and Perl object execution shapes.

## Scope

Keep compatible:

- schema / type objects that users already construct
- promise adapter behavior at the public API boundary
- `execute*` entry points and their observable result semantics
- error semantics and response shape

Do not preserve internally:

- legacy AST node shape
- graphql-perl-compatible internal selection / field bucket structures
- shared executor helpers when they force Perl object bridges
- current `compiled_ir` internal plan layout, if a better lowered form exists

The feature-gap inventory in `docs/ecosystem-feature-gap.md` is an explicit
design input for this runtime project. The VM/runtime may ignore internal
legacy shapes, but it should still preserve clean extension points for
high-priority missing features such as mutation serial execution, modern
introspection support, execution hooks / extensions, and future async
transport or incremental-delivery work.

## Why A New Runtime

Recent experiments showed:

- omitting `resolve_type` info in `compiled_ir` is useful as an opt-in
  compatibility shortcut, but it is not the main throughput lever
- `sv_does`, `sv_derived_from`, and possible-type micro-optimizations do not
  produce a stable large win by themselves
- the remaining cost is dominated less by one lookup and more by the fact that
  execution still returns to generic completion / Perl-owned intermediate
  shapes after important runtime decisions have already been made

So the next profitable step is to make `compiled_ir` execution mostly a new
runtime, not a longer chain of local fast paths.

## Target Architecture

Planned stages:

1. normalized IR
2. typed / specialized IR
3. execution-lowered IR
4. fused lowered IR
5. threaded-op / VM program

Only stages 3-5 are runtime-facing.

### Execution-Lowered IR

The new lowered IR should own:

- field ops
- resolver dispatch operands
- completion dispatch operands
- abstract child dispatch tables
- native result writer metadata
- native promise merge metadata

It should not own:

- legacy field buckets
- legacy compiled field hashes
- AST-compatible selection trees
- eager resolve-info/path Perl objects

### VM Runtime

The VM should execute against:

- a native execution environment
- a native per-field frame
- a native accumulator / result writer
- delayed Perl materialization only at response / error / promise boundaries

Expected op families:

- `RESOLVE_FIXED_EMPTY_ARGS`
- `RESOLVE_FIXED_BUILD_ARGS`
- `RESOLVE_CONTEXT_EMPTY_ARGS`
- `RESOLVE_CONTEXT_BUILD_ARGS`
- `DISPATCH_ABSTRACT_CHILD`
- `EXECUTE_CHILD_PLAN`
- `COMPLETE_TRIVIAL`
- `COMPLETE_OBJECT`
- `COMPLETE_LIST`
- `COMPLETE_ABSTRACT`
- `CONSUME_DIRECT_VALUE`
- `CONSUME_ERROR`
- `QUEUE_PROMISE`

This is intentionally more specialized than the current generic executor.

## Short-Term Implementation Order

1. Introduce an explicit execution-lowered plan object for `compiled_ir`
   sync/object/abstract execution, separate from legacy-compatible plan data.
2. Introduce a native result writer and make abstract child execution write
   into it directly.
3. Replace `completed { data, errors }` as the internal success-path currency
   with native outcome structs.
4. Add a minimal threaded-op runner for sync root/object/abstract execution.
5. Extend the same runtime to promise-aware execution after sync semantics are
   stable.

## First Concrete Slice

The first implementation slice should stay intentionally narrow:

1. define a new lowered sync plan that only targets root/object/abstract
   execution
2. let that lowered plan own native field-op records directly, instead of
   borrowing node-attached legacy metadata
3. introduce a native result writer that can accept:
   - scalar/null direct values
   - object child-plan results
   - error payloads
   without immediately materializing `{ data, errors }`
4. keep promise handling outside this first slice; a miss may fall back to the
   existing compiled-IR executor

That gives a minimal correctness boundary for a new runtime while preserving a
safe fallback path.

Current status:

- the first ownership split has landed in code as a narrow, behavior-preserving
  step: lowered compiled-IR execution now routes through an owned
  `program -> root_block -> field_plan` boundary
- this is still backed by the existing native field-plan executor, but it
  establishes the control-flow owner that later VM blocks and op arrays should
  hang from
- a second narrow split is now in progress: stable field metadata is being
  hoisted into an immutable metadata record that the runtime field frame can
  point at, while mutable resolver/result/outcome state remains in the frame

## Early Design Constraints

The first lowered runtime should deliberately leave room for:

- serial mutation execution by keeping field-loop ordering explicit
- execution hooks / `extensions` by keeping a boundary around final response
  materialization
- future modern introspection additions by not baking old introspection layout
  assumptions into the lowered plan
- future async transport / incremental delivery by not assuming that the only
  terminal output is one eagerly completed Perl response hash

## Concrete First Runtime Boundary

The current lowered runtime still uses these legacy-leaning structures as its
main currency:

- `gql_ir_compiled_root_field_plan_t`
- `gql_ir_compiled_root_field_plan_entry_t`
- `gql_ir_native_exec_env_t`
- `gql_ir_native_exec_accum_t`
- `gql_ir_native_field_frame_t`

That is good enough for shaping experiments, but not yet a clean VM runtime
boundary. The next design step should split these roles more explicitly.

### 1. Lowered Program

Introduce a new owned lowered program type for `compiled_ir`, separate from
legacy-compatible root field plans:

- `gql_ir_vm_program_t`
- `gql_ir_vm_block_t`
- `gql_ir_vm_op_t`

Initial scope:

- one root block
- child blocks for object selections
- child blocks for abstract dispatch targets

The important part is that the lowered program owns execution order and child
edges directly, instead of reconstructing them from node-attached or
legacy-compatible metadata.

### 2. Static Field Metadata

Move per-field stable operands into a dedicated immutable record, for example:

- result key
- field name
- field def
- return type
- parent type
- resolver dispatch kind
- args dispatch kind
- completion kind
- abstract child dispatch table pointer

This record should be owned by the lowered program, not lazily rediscovered
from legacy `SV` containers during the hot loop.

### 3. Runtime Frame

Keep runtime-only mutable state in a separate frame struct:

- resolver result
- native outcome kind
- native outcome payload
- promise marker
- lazy info/path handles if still needed

The runtime frame should never own plan metadata. That separation makes later
threaded execution or register-style execution much simpler.

### 4. Result Writer

The first real new runtime component should be a writer that owns:

- object field writes
- null writes
- child object attachment
- error accumulation
- pending promise slots

The writer should become the only place that knows how to materialize Perl
response hashes or arrays. Field execution itself should only produce native
outcomes for the writer to consume.

This boundary is now partially landed in the current branch: the execution
accumulator no longer directly owns result slots as its primary interface.
Instead, it owns a dedicated native result-writer struct, and field execution
talks to writer helpers first. The next step is to let the writer become the
primary runtime sink for native outcomes and make the accumulator mostly about
execution-level state such as promise presence / finalization policy.

That next step is now in progress as well: the field executor is being moved
off `exec_accum` and toward explicit `(writer, promise_state)` inputs, so the
hot path stops treating the accumulator as its mutable write surface.

As a follow-up, sync trivial completion paths are now being normalized into
direct native outcomes before the consume phase. This is important because it
shrinks the remaining places where the runtime still has to treat Perl
`{ data, errors }` envelopes as an internal execution currency.

### 5. Fallback Boundary

The first VM/runtime slice should still allow explicit fallback to the current
compiled-IR executor when a field or completion shape is not yet lowered.

That fallback boundary should be:

- visible in the lowered program
- counted / measurable in benchmarks
- narrow enough that it can be retired block by block

This avoids another mixed executor with hidden bridge paths.

## Constraints

- memory ownership must stay explicit; lowered plans own lowered data
- no new hidden reliance on node-attached legacy metadata
- if a compatibility shortcut is introduced, it must be opt-in and documented
- async/promise support is required, but after the sync VM core is stable
- optimizations must not paint the runtime into a corner for the
  high-priority gaps tracked in `docs/ecosystem-feature-gap.md`

## Success Criteria

The new runtime is worth keeping if it can do both:

- materially improve `abstract_with_fragment`
- not regress broader sync cases like `nested_variable_object`

If it only improves one micro-benchmark by layering more mixed-mode branches
onto the old executor, that is not success.
