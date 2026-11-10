# Changelog

## Unreleased

- `/mcp` lists the session's own MCP servers: `mcpServerStatus/list` now names
  the thread, so servers declared through ACP `mcpServers` show up, and each
  line shows the runtime status, tool count, `toolsError` and, after a failed
  startup, Codex's error. It used to send no thread, which lists only the
  global configuration, and read a `status` field Codex no longer sends.
- A failed `mcpServer/startupStatus/updated` reaches the client as an agent
  message with Codex's error text verbatim and the status in
  `_meta.codex.mcpServerStartup`, including a failure that lands before
  `thread/start` returns.
- Added `CodexAdapterOptions.onMcpServerStartupStatus` and
  `onAppServerStderr` so hosts can log every startup status and each
  app-server stderr line. Stderr now decodes malformed UTF-8 instead of
  raising an unhandled error.
- Added the opt-in `CodexAdapterOptions.mcpServerStartupTimeout`, sent as
  `startup_timeout_sec` on every server the session declares.
- `/mcp` keeps every line of a multiline error on its own line when the text
  is rendered as Markdown. The indented later lines used to be joined into one
  paragraph, so Codex's startup-timeout hint ran together; each line but the
  last now ends in a Markdown hard break.
- `/mcp` no longer waits out a hung MCP server. Codex answers
  `mcpServerStatus/list` for a thread only after the server's whole startup
  window, so `/mcp` now gives the live list (all pages together)
  `CodexAdapterOptions.mcpStatusTimeout` (default 8 seconds). Past that, or if
  the call fails, it answers from the startup statuses already tracked and
  adds a line saying the live status did not answer. Pages read in time are
  kept.
- `/mcp` output is easier to read: one bullet per server, with the tools
  error and startup error as indented sub-bullets, and durations in Codex's
  text rounded (`119.999999833s` shows as `120s`, `0.25s` as `250ms`).

## 0.1.5

- Added the namespaced `codexThreadTitlePromptMetaKey` hint so ACP clients that
  prepend hidden context can still name native Codex threads from only the
  user-visible prompt.

## 0.1.4

- Name new native Codex threads from their first substantive ACP prompt so
  clients receive the existing `session_info_update` title notification. Names
  are whitespace-normalized and limited to 80 Unicode code points.

## 0.1.3

- Added `CodexApprovalsReviewer` and
  `CodexAdapterOptions.workspaceWriteApprovalsReviewer` so embedded clients can
  opt standard workspace-write turns into Codex's native automatic approval
  review while read-only and plan turns remain human-reviewed.

## 0.1.2

- Implement the shared ACP goal-control extension, including objective updates,
  pause, resume, and clear, and publish goal snapshots when sessions open or
  change.

## 0.1.1

- Fixed Codex app-server thread creation to classify sessions with
  `threadSource` instead of sending the invalid `sessionStartSource` variant.

## 0.1.0

- Added the typed `CodexAcpClient`, `CodexAgent`, `CodexRuntime`, and
  injectable `CodexBackend` APIs.
- Added stdio executable, version output, login passthrough, and Codex CLI
  passthrough.
- Added API-key, ChatGPT, and custom-gateway authentication with secret-safe
  provider discovery and configuration.
- Added session lifecycle, model/reasoning/mode configuration, prompt
  streaming, cancellation, steering, goals, and slash commands.
- Added typed event, tool, history, approval, MCP, and elicitation bridges.
- Added bounded app-server JSON-RPC/process transport, deterministic example,
  regression tests, and representative benchmarks.
