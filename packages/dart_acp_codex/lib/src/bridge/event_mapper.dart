import 'dart:convert';

import 'package:dart_acp_sdk/dart_acp_sdk.dart';

import '../app_server/backend.dart';
import '../app_server/json_values.dart';
import '../session/mcp_startup.dart';
import 'tool_mapper.dart';

/// Stateful mapper from current Codex app-server events to ACP session updates.
final class CodexEventMapper {
  /// Creates an event mapper.
  CodexEventMapper({
    CodexToolCallMapper toolCalls = const CodexToolCallMapper(),
  }) : _toolCalls = toolCalls;

  /// The session notice for an MCP server whose startup failed.
  ///
  /// It is an agent message, so every ACP client shows it, and its text
  /// carries Codex's own error verbatim: that text names the cause (the
  /// timeout, a spawn error) and, for a timeout, the `startup_timeout_sec`
  /// setting that changes it. `_meta.codex.mcpServerStartup` holds the
  /// status as Codex sent it, for clients that render the notice their own
  /// way. [messageId] keeps the notice its own message rather than a
  /// continuation of whatever text came before it.
  static SessionUpdate mcpServerStartupNotice(
    CodexMcpServerStartupStatus status, {
    required String messageId,
  }) {
    final reason =
        status.error ??
        switch (status.failureReason) {
          final reason? => 'Codex reported $reason.',
          null => null,
        };
    final text = reason == null || reason.isEmpty
        ? 'MCP server `${status.name}` failed to start.'
        : 'MCP server `${status.name}` failed to start: $reason';
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, Object?>{'type': 'text', 'text': '$text\n\n'},
      'messageId': messageId,
      '_meta': <String, Object?>{
        'codex': <String, Object?>{'mcpServerStartup': status.toJson()},
      },
    });
  }

  final CodexToolCallMapper _toolCalls;
  final Set<String> _streamedReasoningItems = <String>{};
  final Map<String, StringBuffer> _planDeltas = <String, StringBuffer>{};
  final Map<String, String> _agentMessagePhases = <String, String>{};
  final Set<String> _imageViews = <String>{};
  final Set<String> _imageGenerations = <String>{};
  final Set<String> _subAgentActivities = <String>{};
  final Set<String> _fuzzySearches = <String>{};
  final Set<String> _guardianReviews = <String>{};
  String? _goalSnapshot;

  /// Converts an app-server notification to zero or more ACP updates.
  List<SessionUpdate> map(CodexNotification notification) {
    final params = notification.params;
    final itemId = notification.itemId;
    return switch (notification.method) {
      'item/agentMessage/delta' => _one(
        _textChunk(
          'agent_message_chunk',
          params.optionalString('delta'),
          itemId,
          phase: itemId == null ? null : _agentMessagePhases[itemId.value],
        ),
      ),
      'item/reasoning/summaryTextDelta' ||
      'item/reasoning/textDelta' => _reasoningDelta(notification),
      'item/reasoning/summaryPartAdded' => _reasoningBreak(notification),
      'item/plan/delta' => _planDelta(notification),
      'item/started' => _startedItem(notification),
      'item/completed' => _completedItem(notification),
      'item/commandExecution/outputDelta' ||
      'item/mcpToolCall/progress' => _one(_toolCalls.progress(params)),
      'turn/plan/updated' => _one(_plan(params['plan'])),
      'thread/name/updated' => _one(_sessionTitle(params)),
      'thread/status/changed' => _one(
        _sessionMetadata(<String, Object?>{'threadStatus': params['status']}),
      ),
      'thread/archived' => _one(
        _sessionMetadata(<String, Object?>{'archived': true}),
      ),
      'thread/unarchived' => _one(
        _sessionMetadata(<String, Object?>{'archived': false}),
      ),
      'thread/closed' => _one(
        _sessionMetadata(<String, Object?>{'closed': true}),
      ),
      'thread/tokenUsage/updated' => _one(_usage(params)),
      'fuzzyFileSearch/sessionUpdated' => _one(_fuzzySearch(params)),
      'fuzzyFileSearch/sessionCompleted' => _one(_fuzzySearchCompleted(params)),
      'item/autoApprovalReview/started' => _one(
        _guardianReview(params, completed: false),
      ),
      'item/autoApprovalReview/completed' => _one(
        _guardianReview(params, completed: true),
      ),
      'thread/goal/updated' => _one(_goalUpdated(params)),
      'thread/goal/cleared' => _one(_goalCleared()),
      'item/commandExecution/terminalInteraction' => _one(
        _terminalInteraction(params),
      ),
      'warning' ||
      'configWarning' ||
      'model/rerouted' ||
      'thread/compacted' => _one(_informational(notification)),
      'guardianWarning' => const <SessionUpdate>[],
      'error' => _one(_error(notification)),
      _ => const <SessionUpdate>[],
    };
  }

  List<SessionUpdate> _startedItem(CodexNotification notification) {
    final item = notification.params.optionalObject('item');
    final id = item?.optionalString('id');
    final type = item?.optionalString('type');
    if (id != null && type == 'agentMessage') {
      final phase = item?.optionalString('phase');
      if (phase != null) {
        _agentMessagePhases[id] = phase;
      }
      return const <SessionUpdate>[];
    }
    if (id != null) {
      switch (type) {
        case 'imageView':
          _imageViews.add(id);
        case 'imageGeneration':
          _imageGenerations.add(id);
        case 'subAgentActivity':
          _subAgentActivities.add(id);
      }
    }
    return _one(_toolCalls.started(notification.params));
  }

  List<SessionUpdate> _reasoningDelta(CodexNotification notification) {
    final delta = notification.params.optionalString('delta');
    if (delta == null || delta.isEmpty) {
      return const <SessionUpdate>[];
    }
    final itemId = notification.itemId?.value;
    if (itemId != null) {
      _streamedReasoningItems.add(itemId);
    }
    return <SessionUpdate>[
      _textChunk('agent_thought_chunk', delta, notification.itemId)!,
    ];
  }

  List<SessionUpdate> _reasoningBreak(CodexNotification notification) {
    final itemId = notification.itemId?.value;
    if (itemId != null) {
      _streamedReasoningItems.add(itemId);
    }
    return <SessionUpdate>[
      _textChunk('agent_thought_chunk', '\n\n', notification.itemId)!,
    ];
  }

  List<SessionUpdate> _planDelta(CodexNotification notification) {
    final delta = notification.params.optionalString('delta');
    final id = notification.itemId?.value;
    if (delta == null || delta.isEmpty || id == null) {
      return const <SessionUpdate>[];
    }
    _planDeltas.putIfAbsent(id, StringBuffer.new).write(delta);
    return const <SessionUpdate>[];
  }

  List<SessionUpdate> _completedItem(CodexNotification notification) {
    final item = notification.params.optionalObject('item');
    final type = item?.optionalString('type');
    final id = item?.optionalString('id');
    if (id != null && type == 'agentMessage') {
      final phase = item?.optionalString('phase');
      if (phase != null) {
        _agentMessagePhases[id] = phase;
      }
      return const <SessionUpdate>[];
    }
    if (type == 'reasoning') {
      if (id != null && _streamedReasoningItems.remove(id)) {
        return const <SessionUpdate>[];
      }
      final text = _reasoningText(item);
      return _one(_textChunk('agent_thought_chunk', text, notification.itemId));
    }
    if (type == 'plan') {
      final text =
          item?.optionalString('text') ??
          (id == null ? null : _planDeltas.remove(id)?.toString());
      return _one(
        _textChunk(
          'agent_message_chunk',
          text,
          notification.itemId,
          phase: 'final_answer',
        ),
      );
    }
    if (type == 'exitedReviewMode') {
      return _one(
        _textChunk(
          'agent_message_chunk',
          item?.optionalString('review')?.trim(),
          notification.itemId,
        ),
      );
    }
    if (type == 'imageView' && id != null && _imageViews.remove(id)) {
      return const <SessionUpdate>[];
    }
    if (type == 'imageGeneration' &&
        id != null &&
        !_imageGenerations.remove(id)) {
      return _one(_toolCalls.started(notification.params));
    }
    if (type == 'subAgentActivity' &&
        id != null &&
        !_subAgentActivities.remove(id)) {
      return _one(_toolCalls.started(notification.params));
    }
    return _one(_toolCalls.completed(notification.params));
  }

  SessionUpdate? _textChunk(
    String discriminator,
    String? text,
    CodexItemId? itemId, {
    String? phase,
  }) {
    if (text == null || text.isEmpty) {
      return null;
    }
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': discriminator,
      'content': <String, Object?>{'type': 'text', 'text': text},
      if (itemId != null) 'messageId': itemId.value,
      if (phase != null)
        '_meta': <String, Object?>{
          'codex': <String, Object?>{'phase': phase},
        },
    });
  }

  SessionUpdate? _plan(Object? raw) {
    if (raw is! List<Object?>) {
      return null;
    }
    final entries = <Object?>[];
    for (final value in raw) {
      if (value is! Map<Object?, Object?> || value['step'] is! String) {
        continue;
      }
      final rawStatus = value['status'];
      final status = switch (rawStatus) {
        'inProgress' || 'in_progress' => 'in_progress',
        'completed' => 'completed',
        _ => 'pending',
      };
      entries.add(<String, Object?>{
        'content': value['step'],
        'priority': 'medium',
        'status': status,
      });
    }
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'plan',
      'entries': entries,
    });
  }

  SessionUpdate? _sessionTitle(CodexJsonObject params) {
    final title =
        params.optionalString('name') ?? params.optionalString('threadName');
    if (title == null) {
      return null;
    }
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'session_info_update',
      'title': title,
    });
  }

  SessionUpdate _sessionMetadata(Map<String, Object?> metadata) {
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'session_info_update',
      '_meta': <String, Object?>{'codex': metadata},
    });
  }

  SessionUpdate? _goalUpdated(CodexJsonObject params) {
    final goal = params['goal'];
    final snapshot = jsonEncode(goal);
    if (_goalSnapshot == snapshot) {
      return null;
    }
    _goalSnapshot = snapshot;
    return _sessionMetadata(<String, Object?>{'goal': goal});
  }

  SessionUpdate? _goalCleared() {
    if (_goalSnapshot == null) {
      return null;
    }
    _goalSnapshot = null;
    return _sessionMetadata(<String, Object?>{'goal': null});
  }

  SessionUpdate? _usage(CodexJsonObject params) {
    final usage =
        params.optionalObject('tokenUsage') ??
        params.optionalObject('usage') ??
        params;
    final used =
        usage.optionalInt('totalTokens') ??
        usage.optionalInt('total_tokens') ??
        usage.optionalInt('inputTokens') ??
        0;
    final size =
        usage.optionalInt('modelContextWindow') ??
        usage.optionalInt('contextWindow') ??
        usage.optionalInt('context_window') ??
        0;
    if (size <= 0) {
      return null;
    }
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'usage_update',
      'used': used.clamp(0, size),
      'size': size,
      // `used`/`size` describe the context window, which is all ACP models.
      // Codex also reports what the turn actually generated (output tokens,
      // reasoning tokens, cache hits), and a client that shows "N tokens" for
      // a turn has no way to get at it once this is collapsed to a total.
      // Pass the whole thing through rather than picking fields, so a shape
      // Codex grows later arrives without another release here.
      '_meta': <String, Object?>{
        'codex': <String, Object?>{'tokenUsage': usage.toJson()},
      },
    });
  }

  SessionUpdate? _informational(CodexNotification notification) {
    final params = notification.params;
    final details = params.optionalString('details');
    final message =
        switch (notification.method) {
          'configWarning' =>
            'Config warning: '
                '${params.optionalString('summary') ?? params.optionalString('message') ?? 'Unknown warning'}'
                '${details == null ? '' : '\n\n$details'}\n\n',
          'warning' =>
            'Warning: ${params.optionalString('message') ?? 'Unknown warning'}\n\n',
          'model/rerouted'
              when params.optionalString('fromModel') != null &&
                  params.optionalString('toModel') != null =>
            'Model rerouted from ${params.optionalString('fromModel')} '
                'to ${params.optionalString('toModel')} '
                '(${params.optionalString('reason') ?? 'service routing'}).\n\n',
          _ =>
            params.optionalString('message') ??
                params.optionalString('details'),
        } ??
        switch (notification.method) {
          'model/rerouted' =>
            'The service rerouted this turn to another model.',
          'thread/compacted' =>
            '*Context compacted to fit the model\'s context window.*\n\n',
          _ => null,
        };
    return _textChunk(
      notification.method == 'model/rerouted'
          ? 'agent_thought_chunk'
          : 'agent_message_chunk',
      message,
      notification.itemId,
    );
  }

  SessionUpdate? _error(CodexNotification notification) {
    final error = notification.params.optionalObject('error');
    final message =
        error?.optionalString('message') ??
        notification.params.optionalString('message') ??
        'The Codex app server reported an error.';
    return _textChunk(
      'agent_message_chunk',
      '\n\nError: $message',
      notification.itemId,
    );
  }

  String? _reasoningText(CodexJsonObject? item) {
    if (item == null) {
      return null;
    }
    final summary = item['summary'];
    if (summary is List<Object?>) {
      final parts = <String>[
        for (final value in summary)
          if (value is String)
            value
          else if (value is Map<Object?, Object?> && value['text'] is String)
            value['text']! as String,
      ];
      if (parts.isNotEmpty) {
        return parts.join('\n\n');
      }
    }
    return item.optionalString('text');
  }

  List<SessionUpdate> _one(SessionUpdate? update) =>
      update == null ? const <SessionUpdate>[] : <SessionUpdate>[update];

  SessionUpdate? _fuzzySearch(CodexJsonObject params) {
    final sessionId = params.optionalString('sessionId');
    if (sessionId == null) {
      return null;
    }
    final id = 'fuzzyFileSearch.$sessionId';
    final started = _fuzzySearches.add(id);
    final query = params.optionalString('query');
    final locations = <Object?>[];
    final files = params['files'];
    if (files is List<Object?>) {
      for (final raw in files) {
        if (raw is! Map<Object?, Object?>) {
          continue;
        }
        final file = CodexJsonObject.from(raw);
        final path = file.optionalString('path');
        final root = file.optionalString('root');
        if (path != null) {
          locations.add(<String, Object?>{
            'path': path.startsWith('/') || root == null ? path : '$root/$path',
          });
        }
      }
    }
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': started ? 'tool_call' : 'tool_call_update',
      'toolCallId': id,
      if (started) 'kind': 'search',
      'title': query == null ? 'Search' : "Search for '$query'",
      'status': 'in_progress',
      'locations': locations,
      if (started) 'rawInput': <String, Object?>{'query': query},
    });
  }

  SessionUpdate? _fuzzySearchCompleted(CodexJsonObject params) {
    final sessionId = params.optionalString('sessionId');
    if (sessionId == null) {
      return null;
    }
    final id = 'fuzzyFileSearch.$sessionId';
    _fuzzySearches.remove(id);
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': id,
      'status': 'completed',
    });
  }

  SessionUpdate? _guardianReview(
    CodexJsonObject params, {
    required bool completed,
  }) {
    final reviewId = params.optionalString('reviewId');
    final review = params.optionalObject('review');
    if (reviewId == null || review == null) {
      return null;
    }
    final id = 'guardian_assessment:$reviewId';
    final wasActive = completed
        ? _guardianReviews.remove(reviewId)
        : !_guardianReviews.add(reviewId);
    final status = switch (review.optionalString('status')) {
      'approved' => 'completed',
      'inProgress' => 'in_progress',
      _ => 'failed',
    };
    final lines = <String>[
      'Status: ${review.optionalString('status') ?? 'unknown'}',
      if (review.optionalString('riskLevel') case final risk?) 'Risk: $risk',
      if (review.optionalString('userAuthorization') case final auth?)
        'Authorization: $auth',
      if (review.optionalString('rationale') case final rationale?
          when rationale.trim().isNotEmpty)
        'Rationale: $rationale',
    ];
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': wasActive ? 'tool_call_update' : 'tool_call',
      'toolCallId': id,
      if (!wasActive) 'kind': 'think',
      if (!wasActive) 'title': 'Guardian Review',
      'status': status,
      'content': <Object?>[
        <String, Object?>{
          'type': 'content',
          'content': <String, Object?>{
            'type': 'text',
            'text': lines.join('\n'),
          },
        },
      ],
      if (wasActive)
        'rawOutput': params.toJson()
      else
        'rawInput': params.toJson(),
    });
  }

  SessionUpdate? _terminalInteraction(CodexJsonObject params) {
    final id = params.optionalString('itemId');
    final stdin = params.optionalString('stdin');
    if (id == null || stdin == null) {
      return null;
    }
    final delta = '\n$stdin\n';
    return SessionUpdate.fromJson(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': id,
      '_meta': <String, Object?>{
        'terminal_output_delta': <String, Object?>{
          'data': delta,
          'terminal_id': id,
        },
      },
    });
  }
}
