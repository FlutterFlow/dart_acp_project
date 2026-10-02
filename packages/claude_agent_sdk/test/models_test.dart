import 'package:claude_agent_sdk/claude_agent_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeInitializationResult', () {
    test(
      'reads capabilities sent as a list of names (Claude Code 2.1.287)',
      () {
        final result = ClaudeInitializationResult.fromJson({
          'commands': <Object?>[],
          'models': <Object?>[],
          'agents': <Object?>[],
          'capabilities': ['ui_surface_v1'],
        });
        expect(result.capabilities, {'ui_surface_v1': true});
        expect(result.raw['capabilities'], ['ui_surface_v1']);
      },
    );

    test('reads capabilities sent as an object', () {
      final result = ClaudeInitializationResult.fromJson({
        'capabilities': {
          'ui_surface': {'version': 1},
        },
      });
      expect(result.capabilities, {
        'ui_surface': {'version': 1},
      });
    });

    test('an unknown or missing capabilities shape does not fail', () {
      expect(ClaudeInitializationResult.fromJson({}).capabilities, isEmpty);
      expect(
        ClaudeInitializationResult.fromJson({
          'capabilities': 'ui_surface_v1',
        }).capabilities,
        isEmpty,
      );
    });
  });

  group('JSON boundaries', () {
    test('recursively freezes maps and lists', () {
      final source = <Object?>[
        {
          'type': 'text',
          'text': 'hello',
          'nested': {
            'values': [1, 2],
          },
        },
      ];
      final input = UserInput(content: source);
      (source.single! as Map)['late'] = true;

      final encoded = input.toJson();
      final content = (encoded['message'] as Map)['content'] as List;
      expect(content.single, isNot(contains('late')));
      expect(() => (content.single as Map)['x'] = 1, throwsUnsupportedError);
    });

    test('rejects non-JSON values and keys', () {
      expect(
        () => UserInput(content: DateTime.now()),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UserInput(content: {1: 'value'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('encodes turn identity and steering priority', () {
      final input = UserInput.text('steer', uuid: 'turn-uuid', priority: 'now');
      expect(input.toJson(), containsPair('uuid', 'turn-uuid'));
      expect(input.toJson(), containsPair('priority', 'now'));
    });
  });

  group('permissions', () {
    test('round-trips every permission update shape', () {
      final updates = <PermissionUpdate>[
        AddPermissionRules(
          rules: const [
            PermissionRule(toolName: 'Bash', ruleContent: 'git status:*'),
          ],
          behavior: PermissionBehavior.allow,
          destination: PermissionUpdateDestination.session,
        ),
        ReplacePermissionRules(
          rules: const [PermissionRule(toolName: 'Read')],
          behavior: PermissionBehavior.ask,
        ),
        RemovePermissionRules(
          rules: const [PermissionRule(toolName: 'Write')],
          behavior: PermissionBehavior.deny,
        ),
        const SetPermissionMode(mode: PermissionMode.plan),
        AddPermissionDirectories(directories: const ['/tmp/a']),
        RemovePermissionDirectories(directories: const ['/tmp/b']),
      ];

      for (final update in updates) {
        expect(
          PermissionUpdate.fromJson(update.toJson()).toJson(),
          update.toJson(),
        );
      }
    });

    test('validates empty rules and directories', () {
      expect(
        () => AddPermissionRules(
          rules: const [],
          behavior: PermissionBehavior.allow,
        ),
        throwsArgumentError,
      );
      expect(
        () => AddPermissionDirectories(directories: const []),
        throwsArgumentError,
      );
    });
  });

  group('hooks', () {
    test('decodes typed tool and notification inputs', () {
      final preTool = HookInput.fromJson({
        'hook_event_name': 'PreToolUse',
        'session_id': 'session',
        'transcript_path': '/tmp/session.jsonl',
        'cwd': '/tmp',
        'tool_name': 'Read',
        'tool_input': {'file_path': '/tmp/a'},
        'tool_use_id': 'tool',
      });
      final notification = HookInput.fromJson({
        'hook_event_name': 'Notification',
        'session_id': 'session',
        'transcript_path': '/tmp/session.jsonl',
        'cwd': '/tmp',
        'message': 'Needs attention',
        'title': 'Claude',
        'notification_type': 'permission_prompt',
      });

      expect(preTool, isA<PreToolUseHookInput>());
      expect((preTool as PreToolUseHookInput).toolName, 'Read');
      expect(notification, isA<NotificationHookInput>());
    });

    test('encodes synchronous and deferred outputs', () {
      expect(
        const HookOutput(
          shouldContinue: false,
          stopReason: 'stop',
          shouldBlock: true,
        ).toJson(),
        {'continue': false, 'stopReason': 'stop', 'decision': 'block'},
      );
      expect(HookOutput.async(timeout: const Duration(seconds: 3)).toJson(), {
        'async': true,
        'asyncTimeout': 3000,
      });
    });
  });

  group('SDK MCP', () {
    late SdkMcpServer server;

    setUp(() {
      server = SdkMcpServer(
        name: 'test',
        version: '2.0.0',
        tools: [
          SdkMcpTool(
            name: 'sum',
            description: 'Adds values',
            inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
            annotations: const McpToolAnnotations(isReadOnly: true),
            handler: (input) async => McpToolResult(
              content: [
                McpTextContent('${(input['a'] as num) + (input['b'] as num)}'),
              ],
            ),
          ),
        ],
      );
    });

    test('handles initialize and tool listing', () async {
      final initialize = await server.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
      });
      final list = await server.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      });

      expect(
        ((initialize['result'] as Map)['serverInfo'] as Map)['version'],
        '2.0.0',
      );
      expect(((list['result'] as Map)['tools'] as List), hasLength(1));
    });

    test('calls tools and returns JSON-RPC errors', () async {
      final called = await server.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'sum',
          'arguments': {'a': 2, 'b': 3},
        },
      });
      final missing = await server.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'missing', 'arguments': <String, Object?>{}},
      });

      expect(
        ((((called['result'] as Map)['content'] as List).single
            as Map)['text']),
        '5',
      );
      expect((missing['error'] as Map)['code'], -32602);
    });
  });

  test('agent definitions encode current nested fields', () {
    final definition = AgentDefinition(
      description: 'Reviews code',
      prompt: 'Review carefully',
      tools: const ['Read'],
      skills: const ['review'],
      mcpServers: [
        const AgentMcpServer.named('github'),
        AgentMcpServer.inline(
          'local',
          McpHttpServerConfig(url: 'https://example.com/mcp'),
        ),
      ],
      effort: EffortLevel.high,
      permissionMode: PermissionMode.plan,
    );

    expect(definition.toJson(), containsPair('effort', 'high'));
    expect(definition.toJson(), containsPair('permissionMode', 'plan'));
    expect(definition.toJson()['mcpServers'], hasLength(2));
  });
}
