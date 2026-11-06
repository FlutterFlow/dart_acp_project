# Changelog

## 0.1.3

- Advertise and accept the `bypassPermissions` session mode when the embedding
  client opts in with `allowDangerouslySkipPermissions`, so the ACP mode list
  matches what the Claude Code process will allow.

## 0.1.2

- Implement the shared ACP goal contract for Claude Code `/goal`, including
  update/clear controls and live `active_goal` session snapshots.

## 0.1.1

- Require `claude_agent_sdk` 0.1.1 so scalar tool-result sidecars cannot
  terminate a live ACP session and shutdown interruption markers are not
  replayed as user prompts.

## 0.1.0

- Add the ready-to-use `ClaudeAcpClient`, typed `ClaudeAcpAgent`, reusable
  application builder, and stdio executable.
- Add create, resume, load, replay, fork, list, close, and delete session
  lifecycle with safe client reuse and parameter-sensitive recreation.
- Add FIFO prompt queueing, cancellation, active-turn steering, long-lived
  stream consumption, and isolated background-task completion.
- Add text, thought, image, tool, terminal, diff, plan, command, usage, and
  cost projection with consolidated-stream and subagent deduplication.
- Add permission cards, AskUserQuestion handling, form and URL elicitations,
  and refusal and cancellation fallbacks.
- Add model, effort, agent, fast-mode, permission-mode, MCP server, and local
  command configuration.
- Add capability-sensitive terminal and gateway authentication plus
  Anthropic, Bedrock, and Vertex provider discovery with secret redaction.
- Add settings resolution, session title updates, stable and unstable ACP
  handlers, raw message access, typed errors, and resource validation.
- Add a deterministic in-process example, adapter benchmarks, coverage gates,
  and release-readiness documentation.
- Add programmatic and main-thread agent configuration, full nested subagent
  transcript forwarding by default, and generated subagent progress-summary
  support through `claude_agent_sdk`.
- Preserve parent tool, subagent type, and task description metadata on
  projected nested text, thought, image, plan, and tool updates.
- Add per-session `_meta.claudeCode.options` support for every serializable SDK
  option that is not owned by the ACP lifecycle, including programmatic agents,
  tools, MCP, settings, sandbox, plugins, skills, and runtime limits.
- Align model allowlists, overrides, aliases, resumed live-model/context
  restoration, effort and Fast-mode capability gating, and runtime
  model/permission-mode reconciliation with the current adapter behavior.
- Add TaskCreated/TaskCompleted hook plans, streamed Task/Todo plan handling,
  EnterPlanMode reconciliation, strict-client permission cards for plan tools,
  and typed denial/interruption metadata on tool results.
- Add capability-sensitive boolean Fast mode, synthetic login detection,
  authentication-required mapping, structured Read/Bash/Agent/WebSearch
  results, and current usage/refusal/compaction projection.
