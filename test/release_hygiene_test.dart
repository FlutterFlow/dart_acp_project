import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  final script = File(
    '${Directory.current.path}${Platform.pathSeparator}tool'
    '${Platform.pathSeparator}check_release_hygiene.dart',
  ).absolute.path;

  test('accepts a complete archive-facing package', () async {
    final fixture = _fixture();
    addTearDown(() => fixture.deleteSync(recursive: true));
    _writeCompletePackage(fixture);

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      script,
      '--root=${fixture.path}',
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Release hygiene check passed'));
  });

  test('reports broken links, dependency drift, and logo mismatch', () async {
    final fixture = _fixture();
    addTearDown(() => fixture.deleteSync(recursive: true));
    final package = _writeCompletePackage(fixture);
    File('${package.path}/README.md').writeAsStringSync(
      '[missing](missing.md)\nTypeScript SDK porting process\n',
    );
    File('${package.path}/pubspec.yaml').writeAsStringSync(
      _pubspec.replaceFirst('  json_annotation: ^4.12.0', '  http: ^1.0.0'),
    );
    File(
      '${package.path}/assets/logo.png',
    ).writeAsBytesSync(Uint8List.fromList(_pngHeader(width: 1, height: 1)));

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      script,
      '--root=${fixture.path}',
    ]);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('broken local link'));
    expect(result.stderr, contains('runtime dependencies'));
    expect(result.stderr, contains('implementation-process language'));
    expect(result.stderr, contains('root and package logo bytes differ'));
  });

  test('accepts any version that the top CHANGELOG entry documents', () async {
    final fixture = _fixture();
    addTearDown(() => fixture.deleteSync(recursive: true));
    final package = _writeCompletePackage(fixture);
    File('${package.path}/pubspec.yaml').writeAsStringSync(
      _pubspec.replaceFirst('version: 0.1.0', 'version: 1.2.3-dev.1'),
    );
    File('${package.path}/CHANGELOG.md').writeAsStringSync(
      _changelog.replaceFirst(
        '## 0.1.0',
        '## 1.2.3-dev.1\n\n- Next.\n\n## 0.1.0',
      ),
    );

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      script,
      '--root=${fixture.path}',
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  test('reports an undocumented or malformed version', () async {
    final fixture = _fixture();
    addTearDown(() => fixture.deleteSync(recursive: true));
    final package = _writeCompletePackage(fixture);
    final pubspec = File('${package.path}/pubspec.yaml');

    pubspec.writeAsStringSync(
      _pubspec.replaceFirst('version: 0.1.0', 'version: 0.2.0'),
    );
    var result = await Process.run(Platform.resolvedExecutable, <String>[
      script,
      '--root=${fixture.path}',
    ]);
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains(
        'CHANGELOG.md top entry `0.1.0` must match pubspec version '
        '`0.2.0`',
      ),
    );

    pubspec.writeAsStringSync(
      _pubspec.replaceFirst('version: 0.1.0', 'version: 0.1'),
    );
    result = await Process.run(Platform.resolvedExecutable, <String>[
      script,
      '--root=${fixture.path}',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('`0.1` is not a semantic version'));
  });
}

Directory _fixture() =>
    Directory.systemTemp.createTempSync('dart_acp_sdk_release_audit_');

Directory _writeCompletePackage(Directory root) {
  File('${root.path}/.gitignore').writeAsStringSync('sources/\nspecs/\n');
  final logo = Uint8List.fromList(_pngHeader(width: 512, height: 512));
  _writeBytes(root, 'assets/logo.png', logo);
  final package = Directory('${root.path}/packages/dart_acp_sdk')
    ..createSync(recursive: true);
  for (final relative in _requiredFiles) {
    final file = File('${package.path}/$relative');
    file.parent.createSync(recursive: true);
    if (relative == 'pubspec.yaml') {
      file.writeAsStringSync(_pubspec);
    } else if (relative == 'CHANGELOG.md') {
      file.writeAsStringSync(_changelog);
    } else if (relative == 'assets/logo.png') {
      file.writeAsBytesSync(logo);
    } else if (relative == 'README.md') {
      file.writeAsStringSync('[license](LICENSE)\n');
    } else {
      file.writeAsStringSync('// package artifact\n');
    }
  }
  return package;
}

void _writeBytes(Directory root, String relative, Uint8List bytes) {
  final file = File('${root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

List<int> _pngHeader({required int width, required int height}) {
  final bytes = Uint8List(29);
  bytes.setAll(0, const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setAll(8, const <int>[0, 0, 0, 13, 73, 72, 68, 82]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width);
  data.setUint32(20, height);
  bytes[24] = 8;
  bytes[25] = 6;
  return bytes;
}

const Set<String> _requiredFiles = <String>{
  'CHANGELOG.md',
  'LICENSE',
  'README.md',
  'SECURITY.md',
  'assets/logo.png',
  'benchmark/README.md',
  'example/README.md',
  'example/dual_version_agent.dart',
  'example/http_client.dart',
  'example/http_server.dart',
  'example/main.dart',
  'example/stdio_agent.dart',
  'example/stdio_client.dart',
  'example/web_socket_client.dart',
  'lib/dart_acp_sdk.dart',
  'lib/experimental/http.dart',
  'lib/experimental/protocol_router.dart',
  'lib/experimental/server.dart',
  'lib/experimental/v1_unstable.dart',
  'lib/experimental/v2.dart',
  'lib/experimental/v2_unstable.dart',
  'lib/experimental/web_socket.dart',
  'pubspec.yaml',
};

const String _pubspec = '''
name: dart_acp_sdk
description: A strongly typed Dart SDK for ACP.
version: 0.1.0
repository: https://example.test/repository
issue_tracker: https://example.test/issues
homepage: https://example.test/
documentation: https://example.test/docs
topics:
  - agents
  - protocol
  - rpc
dependencies:
  json_annotation: ^4.12.0
dev_dependencies:
  test: ^1.0.0
''';

const String _changelog = '''
# Changelog

## 0.1.0

- Initial release.
''';
