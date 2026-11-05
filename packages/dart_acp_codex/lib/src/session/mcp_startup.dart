import '../app_server/json_values.dart';

/// The app-server method that reports an MCP server's startup progress.
const String codexMcpServerStartupStatusMethod =
    'mcpServer/startupStatus/updated';

/// Where an MCP server's startup stands, as Codex reports it.
enum CodexMcpServerStartupState {
  /// Codex has spawned or is connecting to the server.
  starting('starting'),

  /// The server initialized and its tools are available.
  ready('ready'),

  /// Startup failed: the server did not spawn, crashed, or did not answer
  /// `initialize` and `tools/list` within its startup timeout.
  failed('failed'),

  /// Startup was cancelled, for example because the thread closed.
  cancelled('cancelled'),

  /// A state this adapter does not know yet. [CodexMcpServerStartupStatus.rawState]
  /// holds the wire value.
  unknown('unknown');

  const CodexMcpServerStartupState(this.appServerValue);

  /// Wire value sent by Codex app-server.
  final String appServerValue;

  /// Parses a wire value, or returns [unknown].
  static CodexMcpServerStartupState parse(String? value) {
    for (final state in values) {
      if (state != unknown && state.appServerValue == value) {
        return state;
      }
    }
    return unknown;
  }
}

/// One `mcpServer/startupStatus/updated` notification from Codex app-server.
///
/// Codex sends one per server and transition (`starting`, then `ready` or
/// `failed`) whenever a thread starts its MCP servers: at `thread/start`,
/// `thread/resume`, and after `config/mcpServer/reload`.
///
/// [error] is Codex's own text, unchanged. It can name commands, paths and
/// configuration, so hosts that persist it should redact it first.
final class CodexMcpServerStartupStatus {
  /// Creates a startup status.
  const CodexMcpServerStartupStatus({
    required this.name,
    required this.state,
    required this.rawState,
    this.threadId,
    this.error,
    this.failureReason,
  });

  /// Reads a notification's params. Returns null when the server name is
  /// missing, since nothing else in the notification is attributable then.
  /// Fields of the wrong type read as absent rather than throwing: a
  /// malformed status must not break the notification stream it rides on.
  static CodexMcpServerStartupStatus? fromParams(CodexJsonObject params) {
    String? text(String key) => switch (params[key]) {
      final String value => value,
      _ => null,
    };
    final name = text('name');
    if (name == null || name.isEmpty) {
      return null;
    }
    final rawState = text('status') ?? '';
    return CodexMcpServerStartupStatus(
      name: name,
      state: CodexMcpServerStartupState.parse(rawState),
      rawState: rawState,
      threadId: text('threadId'),
      error: text('error'),
      failureReason: text('failureReason'),
    );
  }

  /// The thread whose servers are starting. Null for servers Codex starts
  /// outside any thread.
  final String? threadId;

  /// The server's name, the key in `mcp_servers`.
  final String name;

  /// Parsed startup state.
  final CodexMcpServerStartupState state;

  /// The `status` value exactly as Codex sent it.
  final String rawState;

  /// Codex's error text for a failed startup, verbatim.
  final String? error;

  /// Codex's machine-readable failure reason, such as
  /// `reauthenticationRequired`, when it gives one.
  final String? failureReason;

  /// JSON shape used in the session notice's `_meta`.
  Map<String, Object?> toJson() => <String, Object?>{
    'threadId': threadId,
    'name': name,
    'status': rawState,
    'error': error,
    'failureReason': failureReason,
  };
}
