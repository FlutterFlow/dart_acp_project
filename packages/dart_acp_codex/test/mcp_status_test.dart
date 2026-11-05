import 'dart:async';

import 'package:dart_acp_codex/dart_acp_codex.dart';
import 'package:dart_acp_codex/src/bridge/commands.dart';
import 'package:dart_acp_codex/src/bridge/mcp_mapper.dart';
import 'package:test/test.dart';

import 'helpers/fake_backend.dart';

/// Codex's own text for a startup timeout, as codex-cli 0.160 sent it.
const String _timeoutError =
    'MCP client for `flutterflow_ai` timed out after 30 seconds. Add or '
    'adjust `startup_timeout_sec` in your config.toml:\n'
    '[mcp_servers.flutterflow_ai]\n'
    'startup_timeout_sec = XX';

void main() {
  test('/mcp lists the thread\'s servers with runtime status, tool count and '
      'errors', () async {
    final harness = await _connect(
      configureBackend: (backend) {
        backend.on('mcpServerStatus/list', (params) {
          // The real app server answers `{}` from the global config only, so
          // a server the session declared is missing without the thread id.
          if (params['threadId'] == null) {
            return CodexJsonObject.from(<String, Object?>{'data': <Object?>[]});
          }
          if (params['cursor'] == null) {
            return _page(<Object?>[
              <String, Object?>{
                'name': 'flutterflow_ai',
                'runtimeStatus': 'connected',
                'tools': <String, Object?>{
                  for (var i = 0; i < 88; i++) 'tool_$i': <String, Object?>{},
                },
                'toolsError': null,
              },
            ], nextCursor: 'page-2');
          }
          return _page(<Object?>[
            <String, Object?>{
              'name': 'slow',
              'runtimeStatus': 'failed',
              'tools': <String, Object?>{},
              'toolsError':
                  'MCP startup failed: timed out handshaking with MCP server '
                  'after 1.99999975s',
            },
            <String, Object?>{
              'name': 'pending',
              'runtimeStatus': null,
              'tools': <String, Object?>{'one': <String, Object?>{}},
            },
          ]);
        });
      },
    );
    addTearDown(harness.close);
    final session = await harness.newSession();
    harness.backend.emit(codexMcpServerStartupStatusMethod, <String, Object?>{
      'name': 'slow',
      'status': 'failed',
      'error': 'MCP client for `slow` timed out after 2 seconds.',
    }, threadId: session.value);
    await _flush();

    await harness.prompt(session, '/mcp');

    final calls = harness.backend.calls
        .where((call) => call.method == 'mcpServerStatus/list')
        .toList();
    expect(calls.map((call) => call.params['threadId']), <Object?>[
      session.value,
      session.value,
    ]);
    expect(calls.last.params['cursor'], 'page-2');
    expect(
      harness.texts.last,
      'MCP servers:\n'
      '- flutterflow_ai: connected, 88 tools\n'
      '- slow: failed, 0 tools\n'
      '  Tools error: MCP startup failed: timed out handshaking with MCP '
      'server after 1.99999975s\n'
      '  Startup error: MCP client for `slow` timed out after 2 seconds.\n'
      '- pending: status unavailable, 1 tool',
    );
  });

  test('/mcp still reads a pre-runtimeStatus `status` and says when nothing '
      'is configured', () {
    expect(
      CodexCommands.formatMcpServers(<Map<Object?, Object?>>[
        <Object?, Object?>{'name': 'legacy', 'status': 'ready'},
        <Object?, Object?>{'runtimeStatus': 'notStarted'},
      ]),
      'MCP servers:\n- legacy: ready\n- server: not started',
    );
    expect(
      CodexCommands.formatMcpServers(const <Map<Object?, Object?>>[]),
      'No MCP servers are configured.',
    );
  });

  test('a failed startup reaches the client as a notice with Codex\'s error '
      'verbatim, and the host hears every status', () async {
    final statuses = <CodexMcpServerStartupStatus>[];
    final harness = await _connect(
      options: CodexAdapterOptions(
        environment: const <String, String>{},
        onMcpServerStartupStatus: (status) {
          statuses.add(status);
          throw StateError('a host bug must not break the stream');
        },
      ),
    );
    addTearDown(harness.close);
    final session = await harness.newSession();

    for (final (status, error) in <(String, String?)>[
      ('starting', null),
      ('failed', _timeoutError),
    ]) {
      harness.backend.emit(codexMcpServerStartupStatusMethod, <String, Object?>{
        'name': 'flutterflow_ai',
        'status': status,
        'error': error,
        'failureReason': null,
      }, threadId: session.value);
    }
    // No thread: only the host hears it.
    harness.backend.emit(codexMcpServerStartupStatusMethod, <String, Object?>{
      'name': 'global',
      'status': 'ready',
    });
    // Malformed: no name, wrong types. Ignored without breaking the stream.
    harness.backend.emit(codexMcpServerStartupStatusMethod, <String, Object?>{
      'status': 7,
    }, threadId: session.value);
    await _flush();

    expect(statuses.map((s) => '${s.name}:${s.state.name}'), <String>[
      'flutterflow_ai:starting',
      'flutterflow_ai:failed',
      'global:ready',
    ]);
    expect(statuses[1].error, _timeoutError);
    final notices = harness.updates
        .where(
          (n) => n.update.toJson()['sessionUpdate'] == 'agent_message_chunk',
        )
        .toList();
    expect(notices, hasLength(1));
    final json = notices.single.update.toJson();
    expect(json['sessionUpdate'], 'agent_message_chunk');
    expect(
      (json['content']! as Map<Object?, Object?>)['text'],
      'MCP server `flutterflow_ai` failed to start: $_timeoutError\n\n',
    );
    expect(json['messageId'], isA<String>());
    final meta = json['_meta']! as Map<Object?, Object?>;
    expect((meta['codex']! as Map<Object?, Object?>)['mcpServerStartup'], {
      'threadId': session.value,
      'name': 'flutterflow_ai',
      'status': 'failed',
      'error': _timeoutError,
      'failureReason': null,
    });

    // The session keeps working after the throwing callback and bad input.
    await harness.prompt(session, '/mcp');
    expect(harness.texts.last, startsWith('MCP servers:'));
  });

  test('a failure that lands before thread/start returns still reaches the '
      'session, and the host hears it once', () async {
    final statuses = <CodexMcpServerStartupStatus>[];
    final harness = await _connect(
      options: CodexAdapterOptions(
        environment: const <String, String>{},
        onMcpServerStartupStatus: statuses.add,
      ),
      configureBackend: (backend) {
        backend.on('thread/start', (params) {
          // A command that cannot spawn fails while Codex is still handling
          // thread/start, before the response installs the session.
          backend.emit(codexMcpServerStartupStatusMethod, <String, Object?>{
            'name': 'missing',
            'status': 'failed',
            'error': 'No such file or directory (os error 2)',
          }, threadId: 'thread-early');
          return CodexJsonObject.from(<String, Object?>{
            'thread': <String, Object?>{'id': 'thread-early'},
            'cwd': '/workspace',
            'model': 'gpt-test',
          });
        });
      },
    );
    addTearDown(harness.close);
    final session = await harness.newSession();
    await _flush();

    expect(session.value, 'thread-early');
    expect(statuses, hasLength(1));
    expect(
      harness.texts,
      contains(
        'MCP server `missing` failed to start: '
        'No such file or directory (os error 2)\n\n',
      ),
    );
  });

  test('the startup timeout reaches every declared server only when set', () {
    final servers = <McpServer>[
      McpServer.fromJson(<String, Object?>{
        'name': 'stdio',
        'command': 'dart',
        'args': <Object?>['server.dill'],
        'env': <Object?>[],
      }),
      McpServer.fromJson(<String, Object?>{
        'type': 'http',
        'name': 'remote',
        'url': 'https://mcp.example.test',
        'headers': <Object?>[],
      }),
    ];
    const mapper = CodexMcpMapper();
    Object? timeoutOf(Map<String, Object?> config, String name) =>
        (config[name]! as Map<String, Object?>)['startup_timeout_sec'];

    final unset = mapper.map(servers);
    expect(
      unset.values.map((v) => (v! as Map).containsKey('startup_timeout_sec')),
      everyElement(isFalse),
    );
    final whole = mapper.map(
      servers,
      startupTimeout: const Duration(seconds: 120),
    );
    expect(timeoutOf(whole, 'stdio'), 120);
    expect(timeoutOf(whole, 'remote'), 120);
    final fraction = mapper.map(
      servers,
      startupTimeout: const Duration(milliseconds: 1500),
    );
    expect(timeoutOf(fraction, 'stdio'), 1.5);
    expect(
      () => CodexAdapterOptions(mcpServerStartupTimeout: Duration.zero),
      throwsA(isA<CodexConfigurationException>()),
    );
  });

  test('thread/start carries the configured startup timeout', () async {
    final harness = await _connect(
      options: CodexAdapterOptions(
        environment: const <String, String>{},
        mcpServerStartupTimeout: const Duration(seconds: 120),
      ),
    );
    addTearDown(harness.close);
    await harness.newSession(
      servers: <McpServer>[
        McpServer.fromJson(<String, Object?>{
          'name': 'flutterflow_ai',
          'command': 'dart',
          'args': <Object?>[],
          'env': <Object?>[],
        }),
      ],
    );
    final config = harness.backend
        .lastCall('thread/start')
        .params
        .requireObject('config');
    expect(config.toJson()['mcp_servers'], <String, Object?>{
      'flutterflow_ai': <String, Object?>{
        'command': 'dart',
        'args': <Object?>[],
        'env': <String, Object?>{},
        'startup_timeout_sec': 120,
      },
    });
  });
}

CodexJsonObject _page(List<Object?> data, {String? nextCursor}) =>
    CodexJsonObject.from(<String, Object?>{
      'data': data,
      'nextCursor': nextCursor,
    });

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _Harness {
  _Harness(this.backend, this.pair, this.updates);

  final FakeCodexBackend backend;
  final AcpDirectConnectionPair pair;
  final List<SessionNotification> updates;

  /// Text of every agent message chunk received, in order.
  List<String> get texts => <String>[
    for (final update in updates)
      if (update.update.toJson() case {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'text': final String text},
      })
        text,
  ];

  Future<SessionId> newSession({
    List<McpServer> servers = const <McpServer>[],
  }) async {
    final created = await pair.client.agent.createSession(
      NewSessionRequest(cwd: '/workspace', mcpServers: servers),
    );
    return created.sessionId;
  }

  Future<void> prompt(SessionId session, String text) =>
      pair.client.agent.sendPrompt(
        PromptRequest(
          sessionId: session,
          prompt: <ContentBlock>[ContentBlockText(TextContent(text: text))],
        ),
      );

  Future<void> close() async {
    await pair.close();
    await backend.close();
  }
}

Future<_Harness> _connect({
  CodexAdapterOptions? options,
  void Function(FakeCodexBackend backend)? configureBackend,
}) async {
  final backend = FakeCodexBackend();
  configureBackend?.call(backend);
  final agent = CodexAgent(
    backend: backend,
    options:
        options ?? CodexAdapterOptions(environment: const <String, String>{}),
  );
  final updates = <SessionNotification>[];
  final client = AcpClientApp.v1(
    implementation: Implementation(name: 'mcp-status-test', version: '1.0.0'),
    capabilities: ClientCapabilities.fromJson(<String, Object?>{
      'fs': <String, Object?>{'readTextFile': false, 'writeTextFile': false},
      'terminal': false,
    }),
  ).onSessionUpdate((context) => updates.add(context.params));
  final pair = await client.connectWith(agent.app);
  while (backend.count('model/list') == 0) {
    await _flush();
  }
  return _Harness(backend, pair, updates);
}
