<p align="center">
  <img src="assets/logo.png" alt="dart_acp_codex logo" width="160" height="160">
</p>

<h1 align="center">dart_acp_codex</h1>

<p align="center">
  A strongly typed Dart ACP adapter for local Codex processes.
</p>

`dart_acp_codex` connects Agent Client Protocol clients to a Codex
`app-server`. It can run as a stdio executable or be embedded as a typed
`AcpAgentApp` in another Dart program.

## Install

```sh
dart pub add dart_acp_codex
```

The default executable also needs `codex` on `PATH`, or an explicit
`CODEX_EXECUTABLE`.

## Run over stdio

```sh
dart run dart_acp_codex
```

Other executable modes are:

```sh
dart run dart_acp_codex --version
dart run dart_acp_codex login
dart run dart_acp_codex cli --help
```

With no arguments, stdin and stdout are reserved for ACP NDJSON. Diagnostics
are written through the configured diagnostic callback or stderr, never the
protocol stream.

## Connect as a client

```dart
import 'package:dart_acp_codex/dart_acp_codex.dart';

Future<void> main() async {
  final client = await CodexAcpClient.start(
    options: CodexAcpClientOptions(
      executable: '/opt/codex',
      modelProvider: 'openai',
      onDiagnostic: (event) {
        // Forward event.message to your application logger.
      },
    ),
  );

  try {
    final session = await client.agent.createSession(
      NewSessionRequest(cwd: '/workspace', mcpServers: const []),
    );
    print(session.sessionId.value);
  } finally {
    await client.close();
  }
}
```

`CodexAcpClient` owns the local runtime, waits for both ACP and app-server
initialization, and closes both sides idempotently. Applications that need
their own ACP transport can instead create a `CodexRuntime`, call
`createAgent()`, and connect the resulting `agent.app`.

Applications with an existing service boundary can implement `CodexBackend`
and inject it into either API. The public backend contract uses immutable,
validated `CodexJsonObject` values and typed notification/request variants.

## Authentication

The agent supports:

- API-key login, using request metadata first and then `CODEX_API_KEY` or
  `OPENAI_API_KEY`.
- ChatGPT login when browser authentication is available. Set `NO_BROWSER` to
  omit this method.
- A custom OpenAI-compatible gateway supplied by ACP authentication metadata
  or the provider API.

Gateway headers are kept in process configuration and are never returned by
provider discovery or included in diagnostics.

## Configuration

`CodexAcpClientOptions` aliases `CodexAdapterOptions`; it controls the
executable, base app-server configuration, model provider, environment,
shutdown grace period, stderr bound, app-server message size bound, and
diagnostic sink. The executable additionally recognizes:

| Environment variable | Meaning |
| --- | --- |
| `CODEX_EXECUTABLE` | Executable path or command; defaults to `codex` |
| `CODEX_ACP_MODEL_PROVIDER` | Preferred Codex model-provider id |
| `CODEX_ACP_SHUTDOWN_TIMEOUT_MS` | Positive shutdown grace period in milliseconds |
| `CODEX_ACP_MAX_STDERR_CHARS` | Positive maximum retained stderr tail |
| `CODEX_ACP_MAX_LINE_BYTES` | Positive maximum bytes in one app-server message; defaults to 256 MiB |
| `CODEX_API_KEY` / `OPENAI_API_KEY` | API-key fallback |
| `NO_BROWSER` | Disable browser-backed ChatGPT authentication |

Sessions publish typed options for sandbox/approval mode, model, reasoning
effort, and the fast service tier when the selected model supports it.
Standard and plan collaboration modes are available through ACP session mode
methods and `/plan`.

`session/resume` does not replay history, but by default Codex still answers
its `thread/resume` with the thread's whole turn history as one message. A
client can ask for thread metadata only:

```dart
CodexAdapterOptions(excludeTurnsOnResume: true);
```

That sends `excludeTurns: true`, which shrinks the response from the size of
the history to a few KB. The thread keeps its model context. Some Codex
versions then also skip replaying the thread's restored token usage, so the
first `usage_update` may only arrive with the next turn. `session/load` still
requests and replays the history. codex-cli releases before 0.125 ignore the
flag.

Embedded clients can select Codex's native automatic approval reviewer for
standard workspace-write turns:

```dart
CodexAdapterOptions(
  workspaceWriteApprovalsReviewer: CodexApprovalsReviewer.autoReview,
);
```

Read-only and plan turns remain human-reviewed, and full-access turns retain
their `never` approval policy.

The workspace-write sandbox denies network access by default. Clients whose
agents run networked tooling (package managers, API clients) can allow it:

```dart
CodexAdapterOptions(workspaceWriteNetworkAccess: true);
```

The value goes into every workspace-write `turn/start` sandbox policy and into
the thread's `sandbox_workspace_write.network_access` config, so the thread and
its turns agree. Read-only turns keep the network off.

## MCP server status

Codex starts the MCP servers a session declares when the thread starts, and
reports each one through `mcpServer/startupStatus/updated`. A server whose
startup fails (it did not spawn, or did not answer `initialize` and
`tools/list` within its startup timeout) reaches the client as an agent message
carrying Codex's error text, with the status in
`_meta.codex.mcpServerStartup`. `/mcp` lists the thread's servers with their
runtime status, tool count, tool-listing error and startup error.

Hosts can log every status and the app server's stderr, and give the session's
servers more time to start than Codex's 30-second default:

```dart
CodexAdapterOptions(
  mcpServerStartupTimeout: const Duration(seconds: 120),
  onMcpServerStartupStatus: (status) {
    // status.name, status.state, status.error (Codex's text, unredacted).
  },
  onAppServerStderr: (line) {
    // Unredacted; redact before persisting.
  },
);
```

The timeout is sent as `startup_timeout_sec` on each declared server. A thread's
value takes precedence over a config.toml `startup_timeout_sec` for a server of
the same name.

## Providers and extensions

The experimental ACP provider surface advertises one optional provider:
`custom-gateway`. It accepts the `openai` protocol, returns only non-secret
current routing data, rejects malformed configurations, and can be disabled
idempotently.

Two typed underscore extensions are exported:

- `_session/steering` queues additional text or image input. It reports whether
  input joined the active turn, started a new turn, or failed.
- `_session/goal_control` creates or edits, pauses, resumes, or clears the
  current goal. Goal-control support is advertised through
  `agentCapabilities._meta.goalControl`, and sessions publish the current goal
  through the shared `session_info_update._meta.goal` snapshot.

No non-underscore compatibility extensions are registered.

## Sessions, tools, and commands

The adapter supports session new/load/resume/list/close/delete, ordered
streaming updates, cancellation, history replay, additional workspace roots,
stdio and HTTP MCP servers, permission requests, form/URL elicitations, and
user-input questions.

Mapped updates include agent messages, reasoning, plans, usage, titles,
warnings, errors, commands, file changes, MCP/dynamic tools, web actions,
images, collaboration activity, and context compaction. Unknown events are
ignored without affecting other sessions.

Published commands include `/status`, `/mcp`, `/skills`, `/review`,
`/review-branch`, `/review-commit`, `/compact`, `/plan`, `/goal`, and
`/logout`.

## Security and lifecycle

- Protocol values are defensively copied and validated at the boundary.
- Secret headers and API keys are excluded from display strings and
  diagnostics.
- Stderr retention, NDJSON frames, pending JSON-RPC work, and history recovery
  are bounded.
- Session notifications are serialized and fenced by generation so closed
  sessions cannot receive stale updates.
- Child shutdown is idempotent and escalates to termination after the
  configured grace period.

## Example and benchmarks

The [deterministic example](example/main.dart) demonstrates initialization,
session configuration, a streamed turn, permission handling, and shutdown
without credentials or a local executable:

```sh
dart run example/main.dart
```

The [benchmark suite](benchmark/README.md) covers message and terminal deltas,
mixed event mapping, history replay, steering serialization, and multi-session
routing:

```sh
dart run benchmark/adapter_benchmark.dart
dart run benchmark/adapter_benchmark.dart --smoke
```

## Contributing

See the repository
[contribution guide](https://github.com/Salakar/dart_acp/blob/main/CONTRIBUTING.md).
Run formatting, analysis, tests, the example smoke test, and the benchmark
smoke mode before opening a change.

## License

Licensed under the [Apache License 2.0](LICENSE).
