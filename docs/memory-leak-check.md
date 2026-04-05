# Memory Leak Check

This document describes the repeatable memory leak check workflow for
`GraphQL::Houtou`'s XS-heavy code paths.

## Harness

The repository now includes:

```sh
perl util/leak-check.pl
```

The harness stages a temporary copy of the repository, builds it, and runs a
set of representative XS workloads under a platform-appropriate leak checker.

## Backends

### macOS

On macOS the default backend is `leaks(1)`:

```sh
perl util/leak-check.pl --backend leaks
```

This is the preferred mode here because the system clang in this environment
does not support LeakSanitizer.

### non-macOS

On other platforms the default backend is `asan`:

```sh
perl util/leak-check.pl --backend asan
```

## Covered Cases

- `parser_graphqljs`
  - Runs `t/03_parser_graphqljs.t`
- `xs_smoke`
  - Runs `t/04_xs_smoke.t`
- `execution`
  - Runs `t/11_execution.t`
- `promise`
  - Runs `t/12_promise.t`

These cases cover the main graphql-js parser path, XS parser helpers,
execution, abstract completion, and promise-aware execution.

## Current Result

On 2026-04-05, the macOS `leaks` backend was run across all four cases:

```sh
perl util/leak-check.pl --backend leaks --keep-build-dir
```

Observed result:

- `parser_graphqljs`: `0 leaks for 0 total leaked bytes`
- `xs_smoke`: `0 leaks for 0 total leaked bytes`
- `execution`: `0 leaks for 0 total leaked bytes`
- `promise`: `0 leaks for 0 total leaked bytes`

This is not a formal proof that no leaks exist, but it provides a repeatable
baseline for the main parser, execution, and promise-heavy XS paths.

## Notes

- In restricted environments, `leaks(1)` may require elevated permissions
  because it needs task-port access to the child process.
- The leak-check harness is aimed at process-exit leaks. It does not replace
  direct ownership review of temporary `SV` / `AV` / `RV` lifetimes inside XS.
- If a new memory bug is fixed, add or extend a workload case that exercises
  that path so the harness keeps covering it.
