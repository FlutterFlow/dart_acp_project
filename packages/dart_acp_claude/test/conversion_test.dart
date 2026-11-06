import 'package:claude_agent_sdk/claude_agent_sdk.dart' as claude;
import 'package:dart_acp_claude/dart_acp_claude.dart';
import 'package:test/test.dart';

void main() {
  group('prompt conversion', () {
    const mapper = ClaudePromptMapper();

    test('maps text, links, embedded context, images, and MCP commands', () {
      final input = mapper.map(<ContentBlock>[
        ContentBlockText(TextContent(text: '/mcp:review src')),
        ContentBlockResourceLink(
          ResourceLink(name: 'guide', uri: 'file:///tmp/guide.md'),
        ),
        ContentBlockResource(
          EmbeddedResource(
            resource: EmbeddedResourceResourceTextResourceContents(
              TextResourceContents(uri: 'file:///tmp/context', text: 'value'),
            ),
          ),
        ),
        ContentBlockImage(ImageContent(data: 'YWJj', mimeType: 'image/png')),
      ]);
      final blocks = input.content! as List<Object?>;
      expect((blocks[0]! as Map)['text'], '/review (MCP) src');
      expect((blocks[1]! as Map)['text'], '[@guide](file:///tmp/guide.md)');
      expect((blocks[2]! as Map)['text'], contains('<context'));
      expect(
        ((blocks[3]! as Map)['source']! as Map)['media_type'],
        'image/png',
      );
    });

    test('rejects empty and malformed supported prompts', () {
      expect(
        () => mapper.map(<ContentBlock>[
          ContentBlockAudio(AudioContent(data: 'AA==', mimeType: 'audio/wav')),
        ]),
        throwsFormatException,
      );
      final malformed = ContentBlock.fromJson(<String, Object?>{
        'type': 'image',
        'data': 'AA==',
        'mimeType': 'text/plain',
      });
      expect(
        () => mapper.map(<ContentBlock>[malformed]),
        throwsFormatException,
      );
    });
  });

  group('tool and message projection', () {
    const tools = ClaudeToolProjector();
    const messages = ClaudeMessageProjector();

    test('maps tool kinds, titles, paths, results, and usage', () {
      final start = tools.start(
        claude.ToolUseBlock(
          id: 'tool',
          name: 'Edit',
          input: <String, Object?>{'file_path': 'lib/a.dart'},
        ),
        cwd: '/workspace',
      );
      expect(start.discriminator, 'tool_call');
      expect(start.toJson(), containsPair('kind', 'edit'));
      expect(
        (start.toJson()['locations']! as List).single,
        containsPair('path', '/workspace/lib/a.dart'),
      );

      final finish = tools.finish(
        claude.ToolResultBlock(
          toolUseId: 'tool',
          content: 'done\n<usage>tokens</usage>',
        ),
      );
      expect(finish.discriminator, 'tool_call_update');
      expect(finish.toJson(), containsPair('status', 'completed'));

      final resultUpdates = messages.project(
        claude.ResultMessage(
          subtype: 'success',
          duration: const Duration(milliseconds: 1),
          apiDuration: const Duration(milliseconds: 1),
          isError: false,
          turns: 1,
          sessionId: 'session',
          usage: <String, Object?>{'input_tokens': 10, 'output_tokens': 5},
          totalCostUsd: 0.02,
        ),
        cwd: '/workspace',
      );
      expect(resultUpdates.single.discriminator, 'usage_update');
      expect(resultUpdates.single.toJson(), containsPair('used', 15));
    });

    test('maps assistant content and preserves parent attribution', () {
      final updates = messages.project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            const claude.TextBlock('answer'),
            const claude.ThinkingBlock(
              thinking: 'reasoning',
              signature: 'signature',
            ),
            claude.ToolUseBlock(
              id: 'tool',
              name: 'Bash',
              input: <String, Object?>{'command': 'pwd'},
            ),
          ],
          model: 'model',
          messageId: 'message',
          parentToolUseId: 'parent',
          subagentType: 'test-runner',
          taskDescription: 'Run focused tests',
        ),
        cwd: '/workspace',
      );
      expect(updates.map((value) => value.discriminator), <String>[
        'agent_message_chunk',
        'agent_thought_chunk',
        'tool_call',
      ]);
      expect(updates.first.toJson().toString(), contains('parentToolUseId'));
      expect(updates.first.toJson().toString(), contains('test-runner'));
      expect(updates.first.toJson().toString(), contains('Run focused tests'));
      expect(updates.last.toJson().toString(), contains('test-runner'));
    });

    test('projects diffs, terminal content, questions, and safe fallbacks', () {
      final write = tools.start(
        claude.ToolUseBlock(
          id: 'write',
          name: 'Write',
          input: <String, Object?>{
            'file_path': 'lib/new.dart',
            'content': 'void main() {}',
          },
        ),
        cwd: '/workspace',
      );
      expect(write.toJson().toString(), contains('/workspace/lib/new.dart'));
      expect(write.toJson().toString(), contains('type: diff'));

      final terminal = tools.start(
        claude.ToolUseBlock(
          id: 'bash',
          name: 'Bash',
          input: <String, Object?>{'command': 'dart test'},
        ),
        cwd: '/workspace',
        supportsTerminalOutput: true,
      );
      expect(terminal.toJson().toString(), contains('terminalId: bash'));

      final question = tools.start(
        claude.ToolUseBlock(
          id: 'ask',
          name: 'AskUserQuestion',
          input: <String, Object?>{
            'questions': <Object?>[
              <String, Object?>{'question': 'Continue?'},
            ],
          },
        ),
        cwd: '/workspace',
      );
      expect(question.toJson().toString(), contains('Continue?'));

      final unknown = tools.start(
        claude.ToolUseBlock(
          id: 'unknown',
          name: 'FutureTool',
          input: <String, Object?>{'answer': 42},
        ),
        cwd: '/workspace',
      );
      expect(unknown.toJson().toString(), contains('```json'));
    });

    test('preserves image results and strips only tail trailers', () {
      final update = tools.finish(
        claude.ToolResultBlock(
          toolUseId: 'tool',
          content: <Object?>[
            <String, Object?>{
              'type': 'text',
              'text':
                  'Report mentions <usage>inline</usage>.\n'
                  '<usage>\ntokens: 2\n</usage>\n'
                  'agentId: worker-1 (use SendMessage to continue)',
            },
            <String, Object?>{
              'type': 'image',
              'data': 'YWJj',
              'mimeType': 'image/png',
            },
          ],
        ),
      );
      final json = update.toJson()['content'].toString();
      expect(json, contains('mentions <usage>inline</usage>'));
      expect(json, isNot(contains('tokens: 2')));
      expect(json, isNot(contains('worker-1')));
      expect(json, contains('image/png'));
    });

    test('routes terminal output metadata and keeps image results visible', () {
      final update = tools.finish(
        claude.ToolResultBlock(
          toolUseId: 'bash',
          content: <Object?>[
            <String, Object?>{'type': 'text', 'text': 'raw output'},
            <String, Object?>{
              'type': 'image',
              'source': <String, Object?>{
                'media_type': 'image/png',
                'data': 'YWJj',
              },
            },
          ],
        ),
        tool: claude.ToolUseBlock(
          id: 'bash',
          name: 'Bash',
          input: <String, Object?>{'command': 'run'},
        ),
        supportsTerminalOutput: true,
        toolUseResult: <String, Object?>{
          'output': <String, Object?>{
            'stdout': 'standard output',
            'stderr': 'standard error',
            'return_code': 7,
          },
        },
      );
      final json = update.toJson().toString();
      expect(json, contains('standard output'));
      expect(json, contains('standard error'));
      expect(json, contains('exit_code: 7'));
      expect(json, contains('image/png'));
    });

    test('does not attach one structured sidecar to batched tool results', () {
      final state = ClaudeMessageProjectionState()..beginTurn();
      state
        ..recordTool(
          claude.ToolUseBlock(
            id: 'first',
            name: 'Agent',
            input: const <String, Object?>{},
          ),
        )
        ..recordTool(
          claude.ToolUseBlock(
            id: 'second',
            name: 'Agent',
            input: const <String, Object?>{},
          ),
        );
      final updates = messages.project(
        claude.UserMessage.blocks(
          <claude.ContentBlock>[
            claude.ToolResultBlock(toolUseId: 'first', content: 'first raw'),
            claude.ToolResultBlock(toolUseId: 'second', content: 'second raw'),
          ],
          toolUseResult: <String, Object?>{
            'status': 'completed',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'wrong shared value'},
            ],
          },
        ),
        cwd: '/workspace',
        state: state,
      );
      final rendered = updates.map((update) => update.toJson()).toString();
      expect(rendered, allOf(contains('first raw'), contains('second raw')));
      expect(rendered, isNot(contains('wrong shared value')));
    });

    test('filters nested subagent prose for legacy clients', () {
      final updates = messages.project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            const claude.TextBlock('nested prose'),
            claude.ToolUseBlock(
              id: 'child-tool',
              name: 'Read',
              input: <String, Object?>{'file_path': 'child.dart'},
            ),
          ],
          model: 'model',
          parentToolUseId: 'parent',
        ),
        cwd: '/workspace',
        supportsSubagentTranscript: false,
      );
      expect(updates.map((update) => update.discriminator), <String>[
        'tool_call',
      ]);
    });

    test('uses result text only when no assistant text was projected', () {
      final state = ClaudeMessageProjectionState()..beginTurn();
      final fallback = messages.project(
        claude.ResultMessage(
          subtype: 'success',
          duration: Duration.zero,
          apiDuration: Duration.zero,
          isError: false,
          turns: 1,
          sessionId: 'session',
          result: 'fallback',
        ),
        cwd: '/workspace',
        state: state,
      );
      expect(fallback.single.discriminator, 'agent_message_chunk');
      messages.project(
        claude.AssistantMessage(
          content: const <claude.ContentBlock>[claude.TextBlock('answer')],
          model: 'model',
        ),
        cwd: '/workspace',
        state: state..beginTurn(),
      );
      expect(
        messages.project(
          claude.ResultMessage(
            subtype: 'success',
            duration: Duration.zero,
            apiDuration: Duration.zero,
            isError: false,
            turns: 1,
            sessionId: 'session',
            result: 'answer',
          ),
          cwd: '/workspace',
          state: state,
        ),
        isEmpty,
      );
    });

    test('projects stream deltas without duplicating consolidated content', () {
      final state = ClaudeMessageProjectionState();
      List<SessionUpdate> project(claude.AgentMessage message) =>
          messages.project(message, cwd: '/workspace', state: state);

      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-1',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'message_start',
              'message': <String, Object?>{
                'id': 'message',
                'usage': <String, Object?>{'input_tokens': 4},
              },
            },
          ),
        ).single.discriminator,
        'usage_update',
      );
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-2',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'content_block_start',
              'index': 0,
              'content_block': <String, Object?>{'type': 'text', 'text': ''},
            },
          ),
        ),
        isEmpty,
      );
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-3',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'content_block_delta',
              'index': 0,
              'delta': <String, Object?>{'type': 'text_delta', 'text': 'live'},
            },
          ),
        ).single.toJson().toString(),
        contains('live'),
      );
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-4',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'content_block_start',
              'index': 1,
              'content_block': <String, Object?>{
                'type': 'tool_use',
                'id': 'tool',
                'name': 'Read',
                'input': <String, Object?>{},
              },
            },
          ),
        ).single.discriminator,
        'tool_call',
      );
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-5',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'content_block_delta',
              'index': 1,
              'delta': <String, Object?>{
                'type': 'input_json_delta',
                'partial_json': '{"file_path":',
              },
            },
          ),
        ),
        isEmpty,
      );
      project(
        claude.StreamEventMessage(
          uuid: 'event-6',
          sessionId: 'session',
          event: <String, Object?>{
            'type': 'content_block_delta',
            'index': 1,
            'delta': <String, Object?>{
              'type': 'input_json_delta',
              'partial_json': '"README.md"}',
            },
          },
        ),
      );
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'event-7',
            sessionId: 'session',
            event: <String, Object?>{'type': 'content_block_stop', 'index': 1},
          ),
        ).single.toJson().toString(),
        contains('README.md'),
      );

      final consolidated = project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            const claude.TextBlock('live and complete'),
            claude.ToolUseBlock(
              id: 'tool',
              name: 'Read',
              input: <String, Object?>{'file_path': 'README.md'},
            ),
          ],
          model: 'model',
          messageId: 'message',
        ),
      );
      expect(consolidated, hasLength(1));
      expect(consolidated.single.discriminator, 'agent_message_chunk');
      expect(
        (consolidated.single.toJson()['content']! as Map)['text'],
        ' and complete',
      );
    });

    test('carries a streamed tool input when the assistant message precedes '
        'its content_block_stop', () {
      // The CLI's real ordering: content_block_start (empty input), the
      // input_json_delta chunks, then the assistant message — and only then
      // content_block_stop. Projecting the assistant message clears the
      // streamed state, so the input has to reach the client here or not at
      // all.
      final state = ClaudeMessageProjectionState();
      List<SessionUpdate> project(claude.AgentMessage message) =>
          messages.project(message, cwd: '/workspace', state: state);

      project(
        claude.StreamEventMessage(
          uuid: 'start',
          sessionId: 'session',
          event: <String, Object?>{
            'type': 'message_start',
            'message': <String, Object?>{'id': 'message', 'model': 'model'},
          },
        ),
      );
      final call = project(
        claude.StreamEventMessage(
          uuid: 'tool-start',
          sessionId: 'session',
          event: <String, Object?>{
            'type': 'content_block_start',
            'index': 0,
            'content_block': <String, Object?>{
              'type': 'tool_use',
              'id': 'tool',
              'name': 'Bash',
              'input': <String, Object?>{},
            },
          },
        ),
      ).single;
      expect(call.discriminator, 'tool_call');
      // Nothing to describe the call with yet, which is the whole problem.
      expect(call.toJson()['rawInput'], isEmpty);

      project(
        claude.StreamEventMessage(
          uuid: 'tool-delta',
          sessionId: 'session',
          event: <String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{
              'type': 'input_json_delta',
              'partial_json': '{"command":"echo hi"}',
            },
          },
        ),
      );

      final assistant = project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            claude.ToolUseBlock(
              id: 'tool',
              name: 'Bash',
              input: <String, Object?>{'command': 'echo hi'},
            ),
          ],
          model: 'model',
          messageId: 'message',
          sessionId: 'session',
          uuid: 'assistant',
        ),
      );
      final update = assistant.singleWhere(
        (u) => u.discriminator == 'tool_call_update',
      );
      expect(update.toJson()['toolCallId'], 'tool');
      expect((update.toJson()['rawInput'] as Map?)?['command'], 'echo hi');

      // The late stop adds nothing, and must not throw.
      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'tool-stop',
            sessionId: 'session',
            event: <String, Object?>{'type': 'content_block_stop', 'index': 0},
          ),
        ),
        isEmpty,
      );
    });

    test('streams TodoWrite as a plan instead of a generic tool card', () {
      final state = ClaudeMessageProjectionState()..beginTurn();
      List<SessionUpdate> project(claude.AgentMessage message) =>
          messages.project(message, cwd: '/workspace', state: state);

      expect(
        project(
          claude.StreamEventMessage(
            uuid: 'todo-start',
            sessionId: 'session',
            event: <String, Object?>{
              'type': 'content_block_start',
              'index': 0,
              'content_block': <String, Object?>{
                'type': 'tool_use',
                'id': 'todo',
                'name': 'TodoWrite',
                'input': <String, Object?>{},
              },
            },
          ),
        ),
        isEmpty,
      );
      project(
        claude.StreamEventMessage(
          uuid: 'todo-input',
          sessionId: 'session',
          event: <String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{
              'type': 'input_json_delta',
              'partial_json':
                  '{"todos":[{"content":"Inspect","status":"in_progress"}]}',
            },
          },
        ),
      );
      final plan = project(
        claude.StreamEventMessage(
          uuid: 'todo-stop',
          sessionId: 'session',
          event: <String, Object?>{'type': 'content_block_stop', 'index': 0},
        ),
      );
      expect(plan.single.discriminator, 'plan');
      expect(plan.single.toJson().toString(), contains('Inspect'));

      expect(
        project(
          claude.AssistantMessage(
            content: <claude.ContentBlock>[
              claude.ToolUseBlock(
                id: 'todo',
                name: 'TodoWrite',
                input: <String, Object?>{
                  'todos': <Object?>[
                    <String, Object?>{
                      'content': 'Inspect',
                      'status': 'in_progress',
                    },
                  ],
                },
              ),
            ],
            model: 'model',
          ),
        ),
        isEmpty,
      );
    });

    test('stamps non-execution metadata on the matching tool result', () {
      final state = ClaudeMessageProjectionState()..beginTurn();
      messages.project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            claude.ToolUseBlock(
              id: 'bash',
              name: 'Bash',
              input: <String, Object?>{'command': 'rm build.tmp'},
            ),
          ],
          model: 'model',
        ),
        cwd: '/workspace',
        state: state,
      );

      final update = messages
          .project(
            claude.UserMessage.blocks(
              <claude.ContentBlock>[
                claude.ToolResultBlock(
                  toolUseId: 'bash',
                  content: 'Permission denied',
                  isError: true,
                ),
              ],
              toolResultMetadata: <claude.ToolResultMetadata>[
                claude.ToolResultMetadata(
                  toolUseId: 'bash',
                  nonExecutionKind: 'user-rejected',
                  userFeedback: 'Use the package API',
                ),
              ],
            ),
            cwd: '/workspace',
            state: state,
          )
          .single
          .toJson();

      expect(
        update.toString(),
        allOf(contains('user-rejected'), contains('Use the package API')),
      );
    });

    test('maintains plans from todo and task lifecycle tools', () {
      final state = ClaudeMessageProjectionState();
      List<SessionUpdate> project(claude.AgentMessage message) =>
          messages.project(message, cwd: '/workspace', state: state);

      final todo = project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            claude.ToolUseBlock(
              id: 'todo',
              name: 'TodoWrite',
              input: <String, Object?>{
                'todos': <Object?>[
                  <String, Object?>{
                    'content': 'Inspect files',
                    'status': 'completed',
                  },
                  <String, Object?>{
                    'content': 'Implement fix',
                    'status': 'in_progress',
                  },
                ],
              },
            ),
          ],
          model: 'model',
        ),
      );
      expect(todo.single.discriminator, 'plan');
      expect(todo.single.toJson().toString(), contains('Inspect files'));
      expect(todo.single.toJson().toString(), contains('in_progress'));
      expect(
        project(
          claude.UserMessage.blocks(<claude.ContentBlock>[
            claude.ToolResultBlock(toolUseId: 'todo', content: 'ok'),
          ]),
        ),
        isEmpty,
      );

      expect(
        project(
          claude.AssistantMessage(
            content: <claude.ContentBlock>[
              claude.ToolUseBlock(
                id: 'create',
                name: 'TaskCreate',
                input: <String, Object?>{'subject': 'Run checks'},
              ),
            ],
            model: 'model',
          ),
        ),
        isEmpty,
      );
      final created = project(
        claude.UserMessage.blocks(<claude.ContentBlock>[
          claude.ToolResultBlock(
            toolUseId: 'create',
            content: '{"task":{"id":"task-1"}}',
          ),
        ]),
      );
      expect(created.single.discriminator, 'plan');
      expect(created.single.toJson().toString(), contains('Run checks'));

      project(
        claude.AssistantMessage(
          content: <claude.ContentBlock>[
            claude.ToolUseBlock(
              id: 'update',
              name: 'TaskUpdate',
              input: <String, Object?>{
                'taskId': 'task-1',
                'status': 'completed',
              },
            ),
          ],
          model: 'model',
        ),
      );
      final updated = project(
        claude.UserMessage.blocks(<claude.ContentBlock>[
          claude.ToolResultBlock(toolUseId: 'update', content: 'ok'),
        ]),
      );
      expect(updated.single.toJson().toString(), contains('completed'));
    });
  });

  test('provider environment is validated and secrets are redacted', () {
    final provider = ClaudeProviderConfiguration(
      apiType: 'anthropic',
      baseUrl: Uri.parse('https://gateway.example/v1'),
      headers: const <String, String>{'X-Key': 'secret'},
    );
    expect(provider.environment['ANTHROPIC_BASE_URL'], contains('gateway'));
    expect(
      provider.environment['ANTHROPIC_CUSTOM_HEADERS'],
      contains('secret'),
    );
    expect('$provider', isNot(contains('secret')));
    expect(
      () => ClaudeProviderConfiguration(
        apiType: 'vertex',
        baseUrl: Uri.parse('https://vertex.example'),
      ),
      throwsFormatException,
    );
  });

  test('local command metadata is removed without dropping real prose', () {
    expect(
      stripClaudeLocalCommandMetadata(
        '<command-name>/model</command-name>'
        '<local-command-stdout>changed</local-command-stdout>',
      ),
      isNull,
    );
    expect(
      stripClaudeLocalCommandMetadata(
        '<command-name>/model</command-name>keep me',
      ),
      'keep me',
    );
    expect(
      stripClaudeLocalCommandMetadata(<Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '<command-args>opus</command-args>',
        },
        <String, Object?>{'type': 'image', 'data': 'YWJj'},
      ]),
      hasLength(1),
    );
    expect(
      stripClaudeLocalCommandMetadata(<Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '<command-name>/model</command-name>visible',
          'cache_control': <String, Object?>{'type': 'ephemeral'},
        },
      ]),
      <Object?>[
        <String, Object?>{
          'type': 'text',
          'text': 'visible',
          'cache_control': <String, Object?>{'type': 'ephemeral'},
        },
      ],
    );
    expect(isClaudeLocalCommandMetadata('ordinary prose'), isFalse);
  });
}
