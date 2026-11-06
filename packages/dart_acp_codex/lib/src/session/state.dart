import 'dart:async';

import 'package:dart_acp_sdk/dart_acp_sdk.dart';

import '../app_server/backend.dart';
import '../app_server/json_values.dart';
import '../bridge/commands.dart';
import '../config/models.dart';
import '../config/modes.dart';
import 'mcp_startup.dart';

/// Mutable state owned by one ACP session.
final class CodexSessionState {
  /// Creates state for a started or resumed thread.
  CodexSessionState({
    required this.sessionId,
    required this.cwd,
    required Iterable<String> additionalDirectories,
    required this.agentMode,
    required this.collaborationMode,
    required this.model,
    required this.effort,
    this.autoNameOnPrompt = false,
    this.contextWindow,
  }) : additionalDirectories = List<String>.unmodifiable(additionalDirectories);

  /// ACP and app-server thread identity.
  final SessionId sessionId;

  /// Primary working directory.
  final String cwd;

  /// Additional workspace roots.
  final List<String> additionalDirectories;

  /// Approval and sandbox preset.
  /// Completes when the session-start skill discovery has run (successfully
  /// or not), so a slash prompt sent immediately after the session starts —
  /// the panel's cached picker makes that a normal path — can wait for
  /// [skills] instead of silently skipping the invocation rewrite.
  Future<void>? skillsDiscovery;

  /// The skills the app server last reported for this session's directories,
  /// so a `/skill-name` prompt can be recognized and rewritten to the
  /// `\$skill-name` mention Codex actually resolves.
  List<CodexSkill> skills = const <CodexSkill>[];

  /// Sandbox and approval preset in effect.
  CodexAgentMode agentMode;

  /// Collaboration behavior.
  CodexCollaborationMode collaborationMode;

  /// Selected model id.
  String model;

  /// Selected reasoning effort.
  CodexReasoningEffort effort;

  /// Whether the next substantive prompt should name a newly created thread.
  bool autoNameOnPrompt;

  /// Selected model context window.
  int? contextWindow;

  /// Latest total token usage reported for the thread.
  int? usedTokens;

  /// Latest account rate-limit snapshot.
  CodexJsonObject? rateLimits;

  /// Current goal objective, when one is active.
  String? goalObjective;

  /// Current goal status.
  String? goalStatus;

  /// Whether the fast service tier is enabled.
  bool fastMode = false;

  /// The latest startup status Codex reported for each of this thread's MCP
  /// servers, by server name, so `/mcp` can say why a server failed.
  final Map<String, CodexMcpServerStartupStatus> mcpServerStartup =
      <String, CodexMcpServerStartupStatus>{};

  /// Currently active turn.
  CodexTurnId? activeTurn;

  /// Completes when the current turn finishes.
  Completer<StopReason>? turnCompletion;

  /// Whether this session no longer accepts operations.
  bool isClosed = false;

  /// Serializes client notification delivery for this session.
  Future<void> notificationTail = Future<void>.value();

  /// Current generation used to fence stale asynchronous work.
  int generation = 0;

  /// Installs a fresh [turnCompletion] whose failure cannot escape to the
  /// zone, and returns it.
  ///
  /// A turn can be failed — a dead app server, a stream error — before
  /// anything awaits it, and a steering turn is never awaited at all: the
  /// completer erred with no listener reports an unhandled error and, in a
  /// host app, that surfaces as a turn that never settles. Marking the future
  /// ignorable at creation absorbs exactly that case; a real `await` still
  /// receives the error.
  Completer<StopReason> beginTurn() {
    final completer = Completer<StopReason>();
    completer.future.ignore();
    turnCompletion = completer;
    return completer;
  }

  /// Queues one notification operation in event order.
  void enqueueNotification(Future<void> Function() operation) {
    notificationTail = notificationTail.then(
      (_) => operation(),
      onError: (_) {
        return operation();
      },
    );
  }
}

/// In-memory registry for active ACP sessions.
final class CodexSessionRegistry {
  final Map<String, CodexSessionState> _sessions =
      <String, CodexSessionState>{};

  /// All active session states.
  Iterable<CodexSessionState> get values => _sessions.values;

  /// Looks up a session.
  CodexSessionState? operator [](SessionId id) => _sessions[id.value];

  /// Looks up a session by app-server thread id.
  CodexSessionState? byThread(CodexThreadId id) => _sessions[id.value];

  /// Installs state and rejects duplicate active identities.
  void add(CodexSessionState state) {
    final previous = _sessions[state.sessionId.value];
    if (previous != null && !previous.isClosed) {
      throw StateError('Session ${state.sessionId.value} is already active.');
    }
    _sessions[state.sessionId.value] = state;
  }

  /// Removes and closes a session.
  CodexSessionState? remove(SessionId id) {
    final state = _sessions.remove(id.value);
    if (state != null) {
      state
        ..isClosed = true
        ..generation += 1;
    }
    return state;
  }
}
