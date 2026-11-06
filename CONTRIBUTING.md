# Contributing

Thanks for helping improve `dart_acp_sdk`.

## Local setup

The workspace supports Dart 3.11 and the current stable Dart SDK.

```bash
dart pub get
dart run melos bootstrap
```

Package generation, tests, examples, and builds must work from committed
inputs without network access. Optional interoperability evidence and local
review artifacts must never become build inputs or enter a published archive.

## Protocol and generated sources

Committed protocol models come from pinned official ACP schemas. Do not hand-edit
files under `lib/src/protocol/*/generated/`.

```bash
# Reproduce committed sources from the offline schema snapshots.
dart run melos run codegen
dart run melos run schema:check

# Deliberately inspect and adopt current upstream schema changes.
dart run melos run schema:sync
```

Schema updates must record the official ACP commit, source checksums, and a
structural drift report. When schema sources disagree, the current official
specification wins and the divergence must be documented and tested.

Implement behavior from public protocol contracts and independently written
tests. Do not copy third-party implementation text or retain external source
in a published artifact.

## Change requirements

- Add success, failure, malformed-input, lifecycle, and platform tests for
  behavior you change.
- Keep the stable v1 barrel web-safe. Experimental v1, v2, router, HTTP, and
  WebSocket APIs belong in their explicit entrypoints.
- Isolate `dart:io` and browser-only libraries behind conditional imports with
  typed unsupported-platform behavior.
- Add Dartdoc to every public declaration, including ownership, cancellation,
  close, capability, and error semantics where relevant.
- Preserve bounded frames, queues, pending calls, sessions, and subscribers.
- Keep handwritten production files near 750 lines, tests near 250 lines, and
  examples near 300 lines where a coherent split improves reviewability.
  Generated files are exempt, and line counts are guidance rather than a hard
  acceptance gate.
- Treat public API changes according to semantic versioning and update the
  changelog.

Runtime dependencies require a maintenance, license, security, size,
transitive-dependency, API-leakage, alternatives, and removal-path review.

## Required checks

Run the complete root-level gate before opening a pull request:

```bash
dart run melos run codegen
dart run melos run schema:check
dart run melos run spec:check
dart run melos run reference:check
dart format --output=none --set-exit-if-changed tool test
dart run melos run format
dart analyze --fatal-infos tool test
dart run melos run analyze
dart test test
dart run melos run test
dart run melos run verify:web-compile
dart run melos run test:web
dart run melos run verify:file-sizes
dart run melos run verify:release-hygiene
dart run melos run coverage
dart run melos run verify:coverage
dart run melos run examples:smoke
dart run melos run benchmarks:smoke
dart run melos run publish:dry-run
```

Generation must leave the working tree unchanged. Tests and code generation
must not contact upstream services.

Newer Dart releases format some code differently, so CI checks formatting on
its Dart 3.11.0 leg only. If a newer SDK reports format changes in files you
did not touch, run the two format commands with Dart 3.11.0.

## Security

Do not open a public issue for a suspected vulnerability. Follow
[SECURITY.md](SECURITY.md), remove secrets and private prompts from captures,
and provide the smallest redacted reproduction possible.
