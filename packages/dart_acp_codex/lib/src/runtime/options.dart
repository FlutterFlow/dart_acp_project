import 'dart:collection';
import 'dart:io';

import '../app_server/json_values.dart';
import '../config/authentication.dart';
import '../config/modes.dart';
import '../session/mcp_startup.dart';
import 'diagnostics.dart';

/// The Codex app-server reviewer for eligible approval requests.
enum CodexApprovalsReviewer {
  /// Route approval requests to the ACP client for human review.
  user('user'),

  /// Let Codex's native automatic reviewer decide eligible requests.
  autoReview('auto_review');

  const CodexApprovalsReviewer(this.appServerValue);

  /// Wire value sent to Codex app-server.
  final String appServerValue;
}

/// Runtime configuration for a local adapter.
final class CodexAdapterOptions {
  /// Creates validated runtime options.
  CodexAdapterOptions({
    this.executable,
    CodexJsonObject? configuration,
    this.modelProvider,
    this.defaultAuthentication,
    Map<String, String>? environment,
    this.workspaceWriteApprovalsReviewer = CodexApprovalsReviewer.user,
    this.workspaceWriteNetworkAccess = false,
    this.shutdownTimeout = const Duration(seconds: 2),
    this.maximumStderrTailCharacters = 2048,
    this.maximumAppServerLineBytes = defaultMaximumAppServerLineBytes,
    this.excludeTurnsOnResume = false,
    this.mcpRevivePollInterval = const Duration(milliseconds: 300),
    this.mcpRevivePollAttempts = 30,
    this.mcpServerStartupTimeout,
    this.onDiagnostic,
    this.onMcpServerStartupStatus,
    this.onAppServerStderr,
  }) : configuration = configuration ?? CodexJsonObject.empty,
       environment = UnmodifiableMapView<String, String>(
         Map<String, String>.of(environment ?? Platform.environment),
       ) {
    if (executable case final String path when path.trim().isEmpty) {
      throw const CodexConfigurationException(
        'Executable path must not be empty.',
      );
    }
    if (shutdownTimeout <= Duration.zero) {
      throw const CodexConfigurationException(
        'Shutdown timeout must be positive.',
      );
    }
    if (maximumStderrTailCharacters <= 0) {
      throw const CodexConfigurationException(
        'Maximum stderr tail characters must be positive.',
      );
    }
    if (maximumAppServerLineBytes <= 0) {
      throw const CodexConfigurationException(
        'Maximum app-server line bytes must be positive.',
      );
    }
    if (mcpRevivePollInterval <= Duration.zero) {
      throw const CodexConfigurationException(
        'MCP revive poll interval must be positive.',
      );
    }
    if (mcpRevivePollAttempts < 0) {
      throw const CodexConfigurationException(
        'MCP revive poll attempts must not be negative.',
      );
    }
    if (mcpServerStartupTimeout case final timeout?
        when timeout <= Duration.zero) {
      throw const CodexConfigurationException(
        'MCP server startup timeout must be positive.',
      );
    }
  }

  /// Explicit executable path or command.
  final String? executable;

  /// Base app-server configuration.
  final CodexJsonObject configuration;

  /// Optional model-provider id.
  final String? modelProvider;

  /// Authentication attempted when a session requires it.
  final CodexAuthentication? defaultAuthentication;

  /// Child environment.
  final Map<String, String> environment;

  /// Reviewer used for standard workspace-write turns.
  ///
  /// Read-only and plan turns always remain human-reviewed. Full-access turns
  /// keep their `never` approval policy, so this setting does not widen their
  /// permissions.
  final CodexApprovalsReviewer workspaceWriteApprovalsReviewer;

  /// Resolves the app-server reviewer for a turn.
  ///
  /// Automatic review is deliberately limited to the standard collaboration
  /// mode in a workspace-write sandbox. This keeps read-only and plan turns on
  /// explicit human review even when an embedded client opts workspace work
  /// into automatic review.
  CodexApprovalsReviewer resolveApprovalsReviewer({
    required CodexAgentMode agentMode,
    required CodexCollaborationMode collaborationMode,
  }) =>
      agentMode == CodexAgentMode.workspaceWrite &&
          collaborationMode == CodexCollaborationMode.standard
      ? workspaceWriteApprovalsReviewer
      : CodexApprovalsReviewer.user;

  /// Whether commands in the workspace-write sandbox may reach the network.
  ///
  /// Sent as `networkAccess` in every workspace-write `turn/start` sandbox
  /// policy, and as `sandbox_workspace_write.network_access` in the
  /// `thread/start` and `thread/resume` config, so the thread and its turns
  /// agree, overriding any `network_access` in [configuration]. Read-only and
  /// full-access turns ignore it. Off by default, which leaves networked
  /// commands (package managers, API calls) to fail inside the sandbox unless
  /// an approval reruns them unsandboxed.
  final bool workspaceWriteNetworkAccess;

  /// Graceful child shutdown timeout.
  final Duration shutdownTimeout;

  /// Maximum stderr characters retained for process-failure context.
  final int maximumStderrTailCharacters;

  /// Largest single app-server message accepted, in bytes excluding its
  /// newline. A longer message fails the connection.
  ///
  /// The cap exists to stop a runaway peer, not to bound legitimate output.
  /// `thread/resume` answers with the thread's ENTIRE turn history as one
  /// message, every command's aggregated output included, so a long-lived
  /// thread outgrows any modest cap and then fails on every reopen. The
  /// previous implicit 16 MiB (the SDK's NDJSON default) did exactly that.
  final int maximumAppServerLineBytes;

  /// 256 MiB.
  ///
  /// A month-long, 122-turn thread already resumes as a single 14.9 MiB
  /// message, and the resume grows with every command the thread runs. This
  /// leaves more than an order of magnitude of headroom while still stopping
  /// a peer that never ends its line before it exhausts memory.
  static const int defaultMaximumAppServerLineBytes = 256 * 1024 * 1024;

  /// Whether `session/resume` asks Codex to leave the turn history out of its
  /// `thread/resume` response (`excludeTurns: true`).
  ///
  /// `session/resume` never replays history, but `thread/resume` still sends
  /// the whole thread as one message by default, every command's output
  /// included. For a long-lived thread that is tens of MiB, decoded only to be
  /// dropped. With this on, the response is a few KB of thread metadata. The
  /// thread's model context does not come from this response, so it is kept
  /// either way. `session/load` replays the history, so it still asks for it.
  ///
  /// Some Codex versions then also skip replaying the thread's restored token
  /// usage after the response (0.131 skips it, 0.159 still sends it), so a
  /// resumed session may report no `usage_update` until its next turn does.
  ///
  /// codex-cli 0.125 through 0.128, and 0.151 onward, accept the flag. 0.129
  /// through 0.150 accept it under the `experimentalApi` capability, which
  /// this adapter declares. Older app servers ignore it and send the full
  /// history, as they do when this is off.
  final bool excludeTurnsOnResume;

  /// How often the pre-turn MCP revive re-checks server health while waiting
  /// for a reloaded server to come back up.
  final Duration mcpRevivePollInterval;

  /// How many health re-checks the pre-turn MCP revive makes before giving
  /// up on the reload and letting the turn run (and suppressing further
  /// revive attempts for a while).
  final int mcpRevivePollAttempts;

  /// How long Codex waits for each MCP server the client declares for a
  /// session (ACP `mcpServers`) to finish `initialize` and list its tools.
  ///
  /// Sent as `startup_timeout_sec` on every such server in the `thread/start`
  /// and `thread/resume` config. Codex merges a thread's `mcp_servers` entries
  /// key by key with config.toml, and the thread's key wins: on codex-cli
  /// 0.160 a thread value of 5 seconds beat a config.toml value of 2, and 2
  /// beat 5. So this replaces any `startup_timeout_sec` config.toml sets for a
  /// server of the same name, higher or lower, while servers that only
  /// config.toml declares keep their own. Null (the default) sends nothing,
  /// which leaves config.toml's value or Codex's own default (30 seconds)
  /// in charge.
  final Duration? mcpServerStartupTimeout;

  /// Receives redacted diagnostics.
  final void Function(CodexDiagnostic diagnostic)? onDiagnostic;

  /// Receives every `mcpServer/startupStatus/updated` notification the app
  /// server sends, for any thread, including ones that arrive before the
  /// session that owns the thread is installed.
  ///
  /// The status carries Codex's error text unredacted. A failed startup also
  /// reaches the session's client as a visible notice, whether or not this is
  /// set. Exceptions thrown by the callback are caught and dropped.
  final void Function(CodexMcpServerStartupStatus status)?
  onMcpServerStartupStatus;

  /// Receives each non-empty line the owned app-server process writes to
  /// stderr, without its `\n` or `\r\n`. A line longer than
  /// [maximumStderrTailCharacters] arrives in pieces of at most that length.
  /// Bytes that are not UTF-8 arrive as U+FFFD.
  ///
  /// Lines are passed through unredacted and may include ANSI colour codes.
  /// Codex logs can name paths, MCP servers and request details, so redact
  /// them before persisting. Not called for an injected backend. Exceptions
  /// thrown by the callback are caught and dropped.
  final void Function(String line)? onAppServerStderr;
}
