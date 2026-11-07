import 'dart:async';

import 'package:dart_acp_sdk/dart_acp_sdk.dart';

import '../app_server/backend.dart';
import '../app_server/json_values.dart';
import '../config/modes.dart';
import '../session/mcp_startup.dart';
import '../session/state.dart';

/// Result of attempting to execute an ACP slash command.
final class CodexCommandResult {
  /// Creates a result.
  const CodexCommandResult({
    required this.handled,
    this.updates = const <SessionUpdate>[],
  });

  /// Whether the prompt was consumed as a built-in command.
  final bool handled;

  /// Updates to publish before returning from the prompt.
  final List<SessionUpdate> updates;
}

/// A skill the app server reports as available, reduced to what the command
/// list needs.
final class CodexSkill {
  /// Creates a skill entry.
  const CodexSkill({required this.name, required this.description});

  /// The invocation name (`probe-skill`, `openai-templates:foo`).
  final String name;

  /// What the skill does, for the client's command picker.
  final String description;
}

/// Parses and executes adapter-level slash commands.
final class CodexCommands {
  /// Creates a command service.
  const CodexCommands(
    this.backend, {
    this.mcpStatusTimeout = defaultMcpStatusTimeout,
  });

  /// How long `/mcp` waits for the live server list by default.
  static const Duration defaultMcpStatusTimeout = Duration(seconds: 8);

  /// App-server boundary.
  final CodexBackend backend;

  /// Longest `/mcp` waits for the live `mcpServerStatus/list`, all pages
  /// together. Past it, `/mcp` answers from the tracked startup statuses.
  final Duration mcpStatusTimeout;

  /// Publishes the commands available without querying the app server.
  SessionUpdate availableCommands({
    Iterable<CodexSkill> skills = const <CodexSkill>[],
  }) {
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'available_commands_update',
      'availableCommands': <Object?>[
        for (final command in _builtIns) command,
        for (final skill in skills)
          <String, Object?>{
            'name': skill.name,
            'description': skill.description,
            'input': <String, Object?>{'hint': 'optional instructions'},
          },
      ],
    });
  }

  /// The skills the app server reports for [cwds]. Errors surface as an empty
  /// list: a failed lookup must not break the session that asked.
  Future<List<CodexSkill>> listSkills(
    Iterable<String> cwds, {
    bool forceReload = false,
  }) async {
    try {
      final response = await backend.request(
        'skills/list',
        params: CodexJsonObject.from(<String, Object?>{
          'cwds': <Object?>[...cwds],
          'forceReload': forceReload,
        }),
      );
      return parseSkills(response).toList();
    } on Object {
      return const <CodexSkill>[];
    }
  }

  /// Executes a recognized built-in command from [prompt].
  Future<CodexCommandResult> execute(
    List<ContentBlock> prompt,
    CodexSessionState session,
  ) async {
    final parsed = _parse(prompt);
    if (parsed == null) {
      return const CodexCommandResult(handled: false);
    }
    final (name, input) = parsed;
    switch (name) {
      case 'status':
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[_message(await _status(session))],
        );
      case 'mcp':
        final live = await _listMcpServersBounded(session);
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[
            _message(
              formatMcpServers(
                live.servers,
                startup: session.mcpServerStartup,
                liveStatusNote: live.note,
              ),
            ),
          ],
        );
      case 'skills':
        final skills = await listSkills(<String>[
          session.cwd,
          ...session.additionalDirectories,
        ], forceReload: true);
        session.skills = skills;
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[
            availableCommands(skills: skills),
            _message(_formatSkills(skills)),
          ],
        );
      case 'compact':
        await backend.request(
          'thread/compact/start',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': session.sessionId.value,
          }),
        );
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[_message('Context compaction started.')],
        );
      case 'plan':
        final enable = input != 'off';
        session.collaborationMode = enable
            ? CodexCollaborationMode.plan
            : CodexCollaborationMode.standard;
        await backend.request(
          'thread/settings/update',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': session.sessionId.value,
            'collaborationMode': <String, Object?>{
              'mode': session.collaborationMode.id,
              'settings': <String, Object?>{'model': session.model},
            },
          }),
        );
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[
            SessionUpdate.fromJson(<String, Object?>{
              'sessionUpdate': 'current_mode_update',
              'currentModeId': session.collaborationMode.id,
            }),
          ],
        );
      case 'review':
      case 'review-branch':
      case 'review-commit':
        await backend.request(
          'review/start',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': session.sessionId.value,
            'target': switch (name) {
              'review-branch' => <String, Object?>{
                'type': 'baseBranch',
                'branch': input.isEmpty ? null : input,
              },
              'review-commit' => <String, Object?>{
                'type': 'commit',
                'sha': input.isEmpty ? null : input,
              },
              _ => <String, Object?>{
                'type': 'uncommittedChanges',
                'instructions': input.isEmpty ? null : input,
              },
            },
          }),
        );
        return const CodexCommandResult(handled: true);
      case 'goal':
        return _goal(session, input);
      case 'logout':
        await backend.request('account/logout');
        return CodexCommandResult(
          handled: true,
          updates: <SessionUpdate>[_message('Logged out.')],
        );
      default:
        return const CodexCommandResult(handled: false);
    }
  }

  Future<CodexCommandResult> _goal(
    CodexSessionState session,
    String input,
  ) async {
    if (input == 'clear') {
      await backend.request(
        'thread/goal/clear',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': session.sessionId.value,
        }),
      );
      return CodexCommandResult(
        handled: true,
        updates: <SessionUpdate>[_message('Goal cleared.')],
      );
    }
    if (input == 'pause' || input == 'resume') {
      await backend.request(
        'thread/goal/set',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': session.sessionId.value,
          'status': input == 'pause' ? 'paused' : 'active',
        }),
      );
      return CodexCommandResult(
        handled: true,
        updates: <SessionUpdate>[
          _message(input == 'pause' ? 'Goal paused.' : 'Goal resumed.'),
        ],
      );
    }
    if (input.isNotEmpty) {
      await backend.request(
        'thread/goal/set',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': session.sessionId.value,
          'objective': input,
        }),
      );
      return CodexCommandResult(
        handled: true,
        updates: <SessionUpdate>[_message('Goal updated.')],
      );
    }
    final response = await backend.request(
      'thread/goal/get',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': session.sessionId.value,
      }),
    );
    return CodexCommandResult(
      handled: true,
      updates: <SessionUpdate>[_message(_formatGoal(response))],
    );
  }

  Future<String> _status(CodexSessionState session) async {
    final account = await backend.request(
      'account/read',
      params: CodexJsonObject.from(<String, Object?>{'refreshToken': false}),
    );
    final accountValue = account.optionalObject('account');
    final identity =
        accountValue?.optionalString('email') ??
        accountValue?.optionalString('type') ??
        'not authenticated';
    final lines = <String>[
      'Account: $identity',
      'Model: ${session.model}',
      'Reasoning: ${session.effort.id}',
      'Mode: ${session.agentMode.label}',
      'Fast mode: ${session.fastMode ? 'enabled' : 'disabled'}',
      'Working directory: ${session.cwd}',
      if (session.contextWindow case final size?)
        'Context: ${session.usedTokens ?? 0} / $size tokens',
      if (session.goalObjective case final objective?)
        'Goal: $objective (${session.goalStatus ?? 'active'})',
      ..._formatRateLimits(session.rateLimits),
    ];
    return lines.join('\n');
  }

  Iterable<String> _formatRateLimits(CodexJsonObject? snapshot) sync* {
    if (snapshot == null) {
      return;
    }
    final raw =
        snapshot['rateLimitsByLimitId'] ??
        snapshot['rateLimits'] ??
        snapshot['limits'];
    if (raw is! Map<Object?, Object?>) {
      return;
    }
    for (final entry in raw.entries) {
      if (entry.value is! Map<Object?, Object?>) {
        continue;
      }
      final limit = CodexJsonObject.from(entry.value! as Map<Object?, Object?>);
      for (final window in const <String>['primary', 'secondary']) {
        final used = limit
            .optionalObject(window)
            ?.optionalNumber('usedPercent');
        if (used != null) {
          yield 'Rate limit ${entry.key} $window: '
              '${(100 - used).clamp(0, 100).round()}% remaining';
        }
      }
    }
  }

  /// Most `mcpServerStatus/list` pages `/mcp` reads before it stops.
  static const int maximumMcpStatusPages = 20;

  /// [_listMcpServers] under [mcpStatusTimeout]. Codex answers
  /// `mcpServerStatus/list {threadId}` only after a hung server's whole
  /// startup window (120 s or more), so `/mcp` must not wait for it. Pages
  /// read before the deadline are kept; [_LiveMcpList.note] says why the list
  /// may be incomplete. Never throws.
  Future<_LiveMcpList> _listMcpServersBounded(CodexSessionState session) async {
    final servers = <Map<Object?, Object?>>[];
    try {
      await _listMcpServers(session, servers).timeout(mcpStatusTimeout);
      return _LiveMcpList(servers);
    } on TimeoutException {
      return _LiveMcpList(
        servers,
        note:
            'Codex did not report live MCP status within '
            '${_formatSeconds(mcpStatusTimeout)}, so this shows the startup '
            'status seen so far.',
      );
    } on Object catch (error) {
      return _LiveMcpList(
        servers,
        note:
            'Codex could not report live MCP status ($error), so this shows '
            'the startup status seen so far.',
      );
    }
  }

  static String _formatSeconds(Duration duration) =>
      duration < const Duration(seconds: 1)
      ? '${duration.inMilliseconds} ms'
      : '${(duration.inMilliseconds / 1000).round()} s';

  /// Appends every MCP server [session]'s thread can see to [servers], across
  /// result pages.
  ///
  /// The request names the thread. Without `threadId`, app-server answers
  /// from the global configuration alone: servers the session declared (ACP
  /// `mcpServers`, which reach Codex through the thread's config) are
  /// missing, and no entry carries a runtime status. On codex-cli 0.160 a
  /// thread with one declared server listed `[]` for `{}` and that server,
  /// `connected` with 88 tools, for `{threadId}`.
  Future<void> _listMcpServers(
    CodexSessionState session,
    List<Map<Object?, Object?>> servers,
  ) async {
    String? cursor;
    for (var page = 0; page < maximumMcpStatusPages; page++) {
      final response = await backend.request(
        'mcpServerStatus/list',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': session.sessionId.value,
          'cursor': ?cursor,
        }),
      );
      final data = response['data'] ?? response['servers'];
      if (data is List<Object?>) {
        servers.addAll(data.whereType<Map<Object?, Object?>>());
      }
      final next = response['nextCursor'];
      if (next is! String || next.isEmpty || next == cursor) {
        break;
      }
      cursor = next;
    }
  }

  /// Renders `mcpServerStatus/list` entries for `/mcp`: one bullet per
  /// server (runtime status, `runtimeStatus`, older app servers sent `status`,
  /// and tool count), with Codex's `toolsError` and, from [startup], the error
  /// of a failed startup as indented sub-bullets, verbatim apart from
  /// durations, which are rounded.
  ///
  /// [liveStatusNote], when set, says the live list is missing or partial;
  /// servers only [startup] knows about are then listed from it.
  static String formatMcpServers(
    List<Map<Object?, Object?>> servers, {
    Map<String, CodexMcpServerStartupStatus> startup =
        const <String, CodexMcpServerStartupStatus>{},
    String? liveStatusNote,
  }) {
    final lines = <String>[
      for (final server in servers) ..._formatMcpServer(server, startup),
    ];
    if (liveStatusNote != null) {
      final listed = <String>{
        for (final server in servers) _serverName(server),
      };
      for (final entry in startup.entries) {
        if (!listed.contains(entry.key)) {
          lines.addAll(_formatStartupOnly(entry.key, entry.value));
        }
      }
    }
    if (lines.isEmpty && liveStatusNote == null) {
      return 'No MCP servers are configured.';
    }
    return <String>[
      if (lines.isNotEmpty) 'MCP servers:',
      ...lines,
      if (liveStatusNote != null) ...<String>[
        if (lines.isNotEmpty) '',
        liveStatusNote,
      ],
    ].join('\n');
  }

  static String _serverName(Map<Object?, Object?> server) {
    final rawName = server['name'] ?? server['serverName'];
    return rawName is String && rawName.isNotEmpty ? rawName : 'server';
  }

  static Iterable<String> _formatMcpServer(
    Map<Object?, Object?> server,
    Map<String, CodexMcpServerStartupStatus> startup,
  ) sync* {
    final name = _serverName(server);
    final runtimeStatus = server.containsKey('runtimeStatus')
        ? server['runtimeStatus']
        : server['status'];
    final toolCount = switch (server['tools']) {
      final Map<Object?, Object?> map => map.length,
      final List<Object?> list => list.length,
      _ => null,
    };
    final tools = switch (toolCount) {
      null => '',
      1 => ', 1 tool',
      final count => ', $count tools',
    };
    yield '- $name: ${_describeMcpStatus(runtimeStatus)}$tools';
    if (server['toolsError'] case final String error when error.isNotEmpty) {
      yield* _errorLines('Tools error', error);
    }
    if (startup[name] case final started?
        when started.state == CodexMcpServerStartupState.failed) {
      yield* _startupErrorLines(started);
    }
  }

  /// A server only the startup notifications know about.
  static Iterable<String> _formatStartupOnly(
    String name,
    CodexMcpServerStartupStatus started,
  ) sync* {
    final state = started.state == CodexMcpServerStartupState.unknown
        ? started.rawState
        : started.state.appServerValue;
    yield '- $name: $state (startup status)';
    if (started.state == CodexMcpServerStartupState.failed) {
      yield* _startupErrorLines(started);
    }
  }

  static Iterable<String> _startupErrorLines(
    CodexMcpServerStartupStatus started,
  ) => _errorLines(
    'Startup error',
    started.error ?? started.failureReason ?? 'Codex gave no reason.',
  );

  /// `  - label: text` with later lines of [text] indented under it.
  static Iterable<String> _errorLines(String label, String text) {
    final lines = _roundDurations(text).split('\n');
    return <String>[
      '  - $label: ${lines.first}',
      for (final line in lines.skip(1)) '    $line',
    ];
  }

  static final RegExp _durationPattern = RegExp(
    r'(?<![\w.])(\d+(?:\.\d+)?)s\b',
  );

  /// Rewrites `119.999999833s` as `120s` and `0.25s` as `250ms`.
  static String _roundDurations(String text) =>
      text.replaceAllMapped(_durationPattern, (match) {
        final seconds = double.parse(match[1]!);
        return seconds < 1
            ? '${(seconds * 1000).round()}ms'
            : '${seconds.round()}s';
      });

  static String _describeMcpStatus(Object? status) => switch (status) {
    null => 'status unavailable',
    'notStarted' => 'not started',
    'authenticationRequired' => 'authentication required',
    final String value when value.isNotEmpty => value,
    _ => 'unknown',
  };

  String _formatSkills(List<CodexSkill> skills) {
    return skills.isEmpty
        ? 'No skills are available.'
        : 'Available skills:\n'
              '${skills.map((skill) => '- ${skill.name}').join('\n')}';
  }

  /// Reads the skills out of a `skills/list` response. The server groups them
  /// per working directory — `data[].skills[]` — with the same skill repeated
  /// under every cwd that can see it (user-level skills always are), so
  /// entries are de-duplicated by name and disabled ones are dropped.
  /// A flat `data[]`/`skills[]` list of skills is accepted too.
  static Iterable<CodexSkill> parseSkills(CodexJsonObject response) sync* {
    final data = response['data'] ?? response['skills'];
    if (data is! List<Object?>) {
      return;
    }
    final seen = <String>{};
    Iterable<CodexSkill> ofEntry(Map<Object?, Object?> raw) sync* {
      final nested = raw['skills'];
      if (nested is List<Object?>) {
        // A per-cwd group: recurse into its skills.
        for (final inner in nested) {
          if (inner is Map<Object?, Object?>) {
            yield* ofEntry(inner);
          }
        }
        return;
      }
      final name = raw['name'];
      if (name is! String || name.isEmpty || raw['enabled'] == false) {
        return;
      }
      final interface = raw['interface'];
      final short = interface is Map<Object?, Object?>
          ? interface['shortDescription']
          : null;
      final description = raw['description'];
      yield CodexSkill(
        name: name,
        description: short is String && short.isNotEmpty
            ? short
            : (description is String && description.isNotEmpty
                  ? description
                  : 'Run the $name skill.'),
      );
    }

    for (final raw in data) {
      if (raw is! Map<Object?, Object?>) {
        continue;
      }
      for (final skill in ofEntry(raw)) {
        if (seen.add(skill.name)) {
          yield skill;
        }
      }
    }
  }

  String _formatGoal(CodexJsonObject response) {
    final goal = response.optionalObject('goal') ?? response;
    final objective = goal.optionalString('objective');
    if (objective == null || objective.isEmpty) {
      return 'No goal is active.';
    }
    return 'Goal: $objective\nStatus: ${goal.optionalString('status') ?? 'active'}';
  }

  (String, String)? _parse(List<ContentBlock> prompt) {
    if (prompt.length != 1 || prompt.single is! ContentBlockText) {
      return null;
    }
    final json = prompt.single.toJson();
    final text = json['text'];
    if (text is! String || !text.startsWith('/')) {
      return null;
    }
    final trimmed = text.substring(1).trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final space = trimmed.indexOf(RegExp(r'\s'));
    return space < 0
        ? (trimmed, '')
        : (trimmed.substring(0, space), trimmed.substring(space + 1).trim());
  }

  SessionUpdate _message(String text) =>
      SessionUpdate.fromJson(<String, Object?>{
        'sessionUpdate': 'agent_message_chunk',
        'content': <String, Object?>{'type': 'text', 'text': text},
      });

  static const List<Map<String, Object?>> _builtIns = <Map<String, Object?>>[
    <String, Object?>{
      'name': 'status',
      'description': 'Show account and session status.',
    },
    <String, Object?>{'name': 'mcp', 'description': 'Show MCP server status.'},
    <String, Object?>{
      'name': 'skills',
      'description': 'Reload and list available skills.',
    },
    <String, Object?>{
      'name': 'review',
      'description': 'Review uncommitted changes.',
      'input': <String, Object?>{'hint': 'optional review instructions'},
    },
    <String, Object?>{
      'name': 'review-branch',
      'description': 'Review changes against a base branch.',
      'input': <String, Object?>{'hint': 'branch name'},
    },
    <String, Object?>{
      'name': 'review-commit',
      'description': 'Review a commit.',
      'input': <String, Object?>{'hint': 'commit sha'},
    },
    <String, Object?>{
      'name': 'compact',
      'description': 'Compact the session context.',
    },
    <String, Object?>{
      'name': 'plan',
      'description': 'Enable plan mode; use /plan off to disable.',
      'input': <String, Object?>{'hint': 'off'},
    },
    <String, Object?>{
      'name': 'goal',
      'description': 'Inspect or control the session goal.',
      'input': <String, Object?>{'hint': '<objective>|clear|pause|resume'},
    },
    <String, Object?>{'name': 'logout', 'description': 'Log out of Codex.'},
  ];
}

/// The live `/mcp` list, possibly partial, and why when it is.
final class _LiveMcpList {
  const _LiveMcpList(this.servers, {this.note});

  final List<Map<Object?, Object?>> servers;
  final String? note;
}
