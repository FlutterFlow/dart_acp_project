import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.singleOrNull != 'app-server') {
    exitCode = 64;
    return;
  }
  switch (Platform.environment['FAKE_CODEX_MODE']) {
    case 'exit':
      stderr.writeln('fake process failure');
      exitCode = 3;
      return;
    case 'stderr':
      // Exercises the stderr line hook: CRLF, bytes that are not UTF-8, a
      // line past the default 2048-character cap, a blank line, and a last
      // line with no terminator.
      stderr
        ..add(utf8.encode('first line\ncrlf line\r\n'))
        ..add(<int>[0xff, 0xfe, 0x0a, 0x0a])
        ..add(utf8.encode('${'x' * 5000}\nno newline at end'));
      await stderr.flush();
      return;
    case 'hang':
      await Future<void>.delayed(const Duration(days: 1));
    default:
      break;
  }

  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final message = jsonDecode(line);
      if (message is! Map<String, Object?> || message['id'] == null) {
        continue;
      }
      final result = switch (message['method']) {
        'initialize' => <String, Object?>{'codexHome': '/tmp/fake-codex'},
        'model/list' => <String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 'fake-model',
              'isDefault': true,
              'defaultReasoningEffort': 'medium',
              'supportedReasoningEfforts': <Object?>['medium'],
              'inputModalities': <Object?>['text'],
            },
          ],
        },
        'thread/resume' => _resumedThread(message['params']),
        _ => <String, Object?>{},
      };
      stdout.writeln(
        jsonEncode(<String, Object?>{'id': message['id'], 'result': result}),
      );
    }
    _log('clean eof');
  } on Object catch (error, stackTrace) {
    _log('$error\n$stackTrace');
    rethrow;
  }
}

/// A resumed thread whose one command printed `FAKE_CODEX_RESUME_OUTPUT_BYTES`
/// bytes. Like a real `thread/resume`, the whole history is one response
/// line, so its size tracks the output, and `excludeTurns: true` leaves the
/// turns out.
Map<String, Object?> _resumedThread(Object? params) {
  final outputBytes =
      int.tryParse(
        Platform.environment['FAKE_CODEX_RESUME_OUTPUT_BYTES'] ?? '',
      ) ??
      0;
  final request = params is Map<String, Object?> ? params : null;
  return <String, Object?>{
    'thread': <String, Object?>{
      'id': request?['threadId'],
      'turns': <Object?>[
        if (request?['excludeTurns'] != true)
          <String, Object?>{
            'id': 'turn-1',
            'items': <Object?>[
              <String, Object?>{
                'type': 'commandExecution',
                'id': 'command-1',
                'command': 'cat build.log',
                'cwd': '/workspace',
                'status': 'completed',
                'exitCode': 0,
                'aggregatedOutput': 'x' * outputBytes,
              },
            ],
          },
      ],
    },
    'model': 'fake-model',
  };
}

void _log(String message) {
  final path = Platform.environment['FAKE_CODEX_LOG'];
  if (path != null) {
    File(path).writeAsStringSync('$message\n', mode: FileMode.append);
  }
}
