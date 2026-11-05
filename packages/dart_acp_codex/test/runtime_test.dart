import 'dart:io';

import 'package:dart_acp_codex/dart_acp_codex.dart';
import 'package:test/test.dart';

import 'helpers/fake_backend.dart';

late Directory _fixtureDirectory;
late String _fakeExecutable;

void main() {
  setUpAll(() async {
    _fixtureDirectory = await Directory.systemTemp.createTemp(
      'dart-acp-codex-process-',
    );
    _fakeExecutable = '${_fixtureDirectory.path}/fake_codex_process';
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      'compile',
      'exe',
      File('test/fixtures/fake_codex_process.dart').absolute.path,
      '-o',
      _fakeExecutable,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Unable to compile fake process: ${result.stderr}');
    }
  });

  tearDownAll(() async {
    await _fixtureDirectory.delete(recursive: true);
  });

  test(
    'injected backend runtime creates agents and closes idempotently',
    () async {
      final backend = FakeCodexBackend();
      final options = CodexAdapterOptions(
        environment: const <String, String>{},
      );
      final runtime = await CodexRuntime.start(
        options: options,
        backend: backend,
      );

      expect(runtime.options, same(options));
      expect(runtime.createAgent(), isA<CodexAgent>());
      expect(await runtime.exitCode, 0);
      await runtime.close();
      await runtime.close();
      expect(backend.isClosed, isTrue);
    },
  );

  test(
    'owns a real fake NDJSON process through initialization and close',
    () async {
      final log = File('${_fixtureDirectory.path}/clean.log');
      final runtime = await CodexRuntime.start(
        options: CodexAdapterOptions(
          executable: _fakeExecutable,
          environment: <String, String>{
            ...Platform.environment,
            'FAKE_CODEX_LOG': log.path,
          },
          shutdownTimeout: const Duration(seconds: 2),
        ),
      );
      final client = AcpClientApp.v1(
        implementation: Implementation(name: 'runtime-test', version: '1.0.0'),
        capabilities: ClientCapabilities.fromJson(<String, Object?>{
          'fs': <String, Object?>{
            'readTextFile': false,
            'writeTextFile': false,
          },
          'terminal': false,
        }),
      );
      final pair = await client.connectWith(runtime.createAgent().app);

      await pair.close();
      await runtime.close();
      expect(
        await runtime.exitCode,
        0,
        reason: log.existsSync() ? log.readAsStringSync() : 'no child log',
      );
    },
  );

  test('reports spawn failure without exposing the executable', () async {
    await expectLater(
      CodexRuntime.start(
        options: CodexAdapterOptions(
          executable: '/definitely/missing/dart-acp-codex',
          environment: const <String, String>{},
        ),
      ),
      throwsA(
        isA<CodexProcessException>().having(
          (error) => error.message,
          'message',
          isNot(contains('missing')),
        ),
      ),
    );
  });

  test('captures non-zero exit diagnostics without stderr content', () async {
    final diagnostics = <CodexDiagnostic>[];
    final runtime = await CodexRuntime.start(
      options: CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: <String, String>{
          ...Platform.environment,
          'FAKE_CODEX_MODE': 'exit',
        },
        onDiagnostic: diagnostics.add,
      ),
    );

    expect(await runtime.exitCode, 3);
    await Future<void>.delayed(Duration.zero);
    expect(diagnostics.single.exitCode, 3);
    expect(diagnostics.single.message, isNot(contains('fake process failure')));
    await runtime.close();
  });

  test('hands the host each stderr line, bounded and tolerant of bad '
      'bytes', () async {
    final lines = <String>[];
    final runtime = await CodexRuntime.start(
      options: CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: <String, String>{
          ...Platform.environment,
          'FAKE_CODEX_MODE': 'stderr',
        },
        onAppServerStderr: (line) {
          lines.add(line);
          throw StateError('a host bug must not stop stderr draining');
        },
      ),
    );
    addTearDown(runtime.close);

    expect(await runtime.exitCode, 0);
    for (var i = 0; i < 100 && lines.length < 7; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(lines, <String>[
      'first line',
      'crlf line',
      '\u{FFFD}\u{FFFD}',
      'x' * 2048,
      'x' * 2048,
      'x' * 904,
      'no newline at end',
    ]);
  });

  test('opens a thread whose history is one line over 16 MiB', () async {
    // The previous cap was the SDK's 16 MiB NDJSON default, and a real
    // month-long thread already resumes as a single 14.9 MiB line. Both ACP
    // entry points send `thread/resume`: session/resume discards the history
    // and session/load replays it, but both receive it as that one line.
    const outputBytes = 20 * 1024 * 1024;
    final updates = <SessionNotification>[];
    final agent = await _connectToFakeProcess(
      CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: _resumeEnvironment(outputBytes),
      ),
      updates,
    );

    await agent.resumeSession(
      ResumeSessionRequest(sessionId: SessionId('resumed'), cwd: '/workspace'),
    );
    await agent.loadSession(
      LoadSessionRequest(
        sessionId: SessionId('loaded'),
        cwd: '/workspace',
        mcpServers: const <McpServer>[],
      ),
    );

    expect(<String>[
      for (final notification in updates)
        if (notification.update.toJson()['rawOutput'] case <String, Object?>{
          'formatted_output': final String output,
        })
          output,
    ], anyElement(hasLength(outputBytes)));
  });

  test('fails a line over the configured maximum, naming it', () async {
    final agent = await _connectToFakeProcess(
      CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: _resumeEnvironment(2 * 1024 * 1024),
        maximumAppServerLineBytes: 1024 * 1024,
      ),
      <SessionNotification>[],
    );

    await expectLater(
      agent.resumeSession(
        ResumeSessionRequest(
          sessionId: SessionId('resumed'),
          cwd: '/workspace',
        ),
      ),
      throwsA(
        isA<JsonRpcRequestException>().having(
          (error) => '${error.data}',
          'data',
          allOf(
            contains('LineLengthExceededException'),
            contains('maximum: 1048576'),
          ),
        ),
      ),
    );
  });

  test('resumes without the history when excluding turns', () async {
    // The same 2 MiB history that fails a 1 MiB cap above: excludeTurns keeps
    // it off the wire for session/resume, while session/load, which replays
    // it, still asks for it and still hits the cap.
    final updates = <SessionNotification>[];
    final agent = await _connectToFakeProcess(
      CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: _resumeEnvironment(2 * 1024 * 1024),
        maximumAppServerLineBytes: 1024 * 1024,
        excludeTurnsOnResume: true,
      ),
      updates,
    );

    await agent.resumeSession(
      ResumeSessionRequest(sessionId: SessionId('resumed'), cwd: '/workspace'),
    );
    // The resumed session's initial updates end with its goal snapshot. Let
    // them land before the failing load takes the connection down.
    while (!updates.any(
      (notification) =>
          notification.update.discriminator == 'session_info_update',
    )) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await expectLater(
      agent.loadSession(
        LoadSessionRequest(
          sessionId: SessionId('loaded'),
          cwd: '/workspace',
          mcpServers: const <McpServer>[],
        ),
      ),
      throwsA(
        isA<JsonRpcRequestException>().having(
          (error) => '${error.data}',
          'data',
          contains('LineLengthExceededException'),
        ),
      ),
    );
  });

  test('kills an unresponsive owned process after the grace period', () async {
    final runtime = await CodexRuntime.start(
      options: CodexAdapterOptions(
        executable: _fakeExecutable,
        environment: <String, String>{
          ...Platform.environment,
          'FAKE_CODEX_MODE': 'hang',
        },
        shutdownTimeout: const Duration(milliseconds: 20),
      ),
    );

    await runtime.close();
    expect(await runtime.exitCode, isNot(0));
  });
}

Map<String, String> _resumeEnvironment(int outputBytes) => <String, String>{
  ...Platform.environment,
  'FAKE_CODEX_RESUME_OUTPUT_BYTES': '$outputBytes',
};

/// Connects an ACP client to an agent over a real fake app-server process,
/// collecting session updates into [updates].
Future<AcpClientContext> _connectToFakeProcess(
  CodexAdapterOptions options,
  List<SessionNotification> updates,
) async {
  final runtime = await CodexRuntime.start(options: options);
  addTearDown(runtime.close);
  final client =
      AcpClientApp.v1(
        implementation: Implementation(name: 'runtime-test', version: '1.0.0'),
        capabilities: ClientCapabilities.fromJson(<String, Object?>{
          'fs': <String, Object?>{
            'readTextFile': false,
            'writeTextFile': false,
          },
          'terminal': false,
        }),
      ).onSessionUpdate((context) {
        updates.add(context.params);
      });
  final pair = await client.connectWith(runtime.createAgent().app);
  addTearDown(pair.close);
  return pair.client.agent;
}
