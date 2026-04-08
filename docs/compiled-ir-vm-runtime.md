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

## Early Design Constraints

The first lowered runtime should deliberately leave room for:

- serial mutation execution by keeping field-loop ordering explicit
- execution hooks / `extensions` by keeping a boundary around final response
  materialization
- future modern introspection additions by not baking old introspection layout
  assumptions into the lowered plan
- future async transport / incremental delivery by not assuming that the only
  terminal output is one eagerly completed Perl response hash

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
