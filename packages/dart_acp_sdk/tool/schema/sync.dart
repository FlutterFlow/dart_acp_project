import 'dart:convert';
import 'dart:io';

import 'src/drift.dart';
import 'src/schema_loader.dart';
import 'src/sha256.dart';

const _officialSlug = 'agentclientprotocol/agent-client-protocol';
const _sdkSlug = 'agentclientprotocol/typescript-sdk';
const _officialRepository =
    'https://github.com/agentclientprotocol/agent-client-protocol';
const _sdkRepository = 'https://github.com/agentclientprotocol/typescript-sdk';

void main(List<String> arguments) async {
  if (arguments.length != 1 ||
      (arguments.single != '--check' && arguments.single != '--update')) {
    stderr.writeln('Usage: dart run tool/schema/sync.dart --check|--update');
    exitCode = 64;
    return;
  }
  final bool update = arguments.single == '--update';
  final Directory schemaRoot = File.fromUri(Platform.script).parent;
  final Directory packageRoot = schemaRoot.parent.parent;
  final HttpClient client = HttpClient()
    ..userAgent = 'dart_acp_sdk schema sync';
  try {
    final commits = await Future.wait(<Future<String>>[
      _resolveMain(client, _officialSlug),
      _resolveMain(client, _sdkSlug),
    ]);
    final String officialCommit = commits[0];
    final String sdkCommit = commits[1];
    final List<String> sdkPaths = await _repositorySchemaPaths(
      client,
      _sdkSlug,
      sdkCommit,
    );
    const officialPaths = <String>[
      'schema/v1/meta.json',
      'schema/v1/meta.unstable.json',
      'schema/v1/schema.json',
      'schema/v1/schema.unstable.json',
      'schema/v2/meta.json',
      'schema/v2/meta.unstable.json',
      'schema/v2/schema.json',
      'schema/v2/schema.unstable.json',
    ];
    final specs =
        <_RemoteSnapshot>[
          for (final String path in officialPaths)
            _RemoteSnapshot(
              source: 'official',
              remotePath: path,
              localPath: 'snapshots/official/$path',
              commit: officialCommit,
              repositorySlug: _officialSlug,
            ),
          for (final String path in sdkPaths)
            _RemoteSnapshot(
              source: 'sdk',
              remotePath: path,
              localPath: 'snapshots/sdk/$path',
              commit: sdkCommit,
              repositorySlug: _sdkSlug,
            ),
        ]..sort(
          (_RemoteSnapshot left, _RemoteSnapshot right) =>
              left.localPath.compareTo(right.localPath),
        );
    final downloaded = await Future.wait(
      specs.map(
        (_RemoteSnapshot spec) async => _DownloadedSnapshot(
          spec: spec,
          bytes: await _downloadBytes(client, Uri.parse(spec.url)),
        ),
      ),
    );
    final Object manifestJson = _manifestJson(
      officialCommit: officialCommit,
      sdkCommit: sdkCommit,
      snapshots: downloaded,
    );

    final Directory staging = Directory.systemTemp.createTempSync(
      'dart_acp_schema_sync_',
    );
    try {
      final File stagedManifest = File('${staging.path}/schema_manifest.json');
      stagedManifest.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(manifestJson)}\n',
      );
      for (final _DownloadedSnapshot snapshot in downloaded) {
        final File file = File('${staging.path}/${snapshot.spec.localPath}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(snapshot.bytes);
      }
      final SchemaLoader stagedLoader = SchemaLoader(staging);
      stagedLoader.verifyAll();
      final DriftAllowlist allowlist = DriftAllowlist.fromJson(
        jsonDecode(
          File('${schemaRoot.path}/drift_allowlist.json').readAsStringSync(),
        ),
      );
      final SchemaDriftReport drift = computeSnapshotDrift(
        stagedLoader,
        allowlist,
      );
      final List<String> driftIssues = unexplainedDrift(drift, allowlist);
      if (driftIssues.isNotEmpty) {
        stderr.writeln('Remote schemas contain unexplained drift:');
        for (final String issue in driftIssues) {
          stderr.writeln('  $issue');
        }
        exitCode = 1;
        return;
      }

      if (!update) {
        final List<String> changes = _freshnessChanges(
          schemaRoot,
          stagedLoader.manifest,
          downloaded,
        );
        if (changes.isNotEmpty) {
          stderr.writeln('Checked schema snapshots are stale:');
          for (final String change in changes) {
            stderr.writeln('  $change');
          }
          exitCode = 1;
          return;
        }
        stdout.writeln(
          'Schema snapshots match official $officialCommit and SDK $sdkCommit.',
        );
        return;
      }

      _replaceSnapshots(schemaRoot, downloaded);
      File(
        '${schemaRoot.path}/schema_manifest.json',
      ).writeAsStringSync(stagedManifest.readAsStringSync());
      final int generationExit = _runDart(packageRoot, const <String>[
        'run',
        'tool/schema/generate.dart',
      ]);
      if (generationExit != 0) {
        exitCode = generationExit;
        return;
      }
      final int buildExit = _runDart(packageRoot, const <String>[
        'run',
        'build_runner',
        'build',
      ]);
      if (buildExit != 0) {
        exitCode = buildExit;
        return;
      }
      // No `dart format` pass here: both generators already format their
      // output, and build_runner does so with the locked dart_style, so the
      // generated sources come out the same on every supported SDK.
      stdout.writeln(
        'Updated schema snapshots, generated sources, and build outputs.',
      );
    } finally {
      if (staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
    }
  } on SocketException catch (error) {
    stderr.writeln('Schema sync network failure: $error');
    exitCode = 69;
  } on HttpException catch (error) {
    stderr.writeln('Schema sync HTTP failure: $error');
    exitCode = 69;
  } finally {
    client.close(force: true);
  }
}

Future<String> _resolveMain(HttpClient client, String slug) async {
  final Object? decoded = jsonDecode(
    utf8.decode(
      await _downloadBytes(
        client,
        Uri.https('api.github.com', '/repos/$slug/commits/main'),
        accept: 'application/vnd.github+json',
      ),
    ),
  );
  final Map<String, Object?> root = _stringMap(decoded, '$slug main commit');
  final Object? sha = root['sha'];
  if (sha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
    throw FormatException('GitHub returned an invalid commit for $slug');
  }
  return sha;
}

Future<List<String>> _repositorySchemaPaths(
  HttpClient client,
  String slug,
  String commit,
) async {
  final Object? decoded = jsonDecode(
    utf8.decode(
      await _downloadBytes(
        client,
        Uri.https(
          'api.github.com',
          '/repos/$slug/git/trees/$commit',
          <String, String>{'recursive': '1'},
        ),
        accept: 'application/vnd.github+json',
      ),
    ),
  );
  final Map<String, Object?> root = _stringMap(decoded, '$slug tree');
  if (root['truncated'] == true) {
    throw StateError('GitHub truncated the recursive tree for $slug');
  }
  final Object? tree = root['tree'];
  if (tree is! List<Object?>) {
    throw FormatException('GitHub tree is not an array for $slug');
  }
  final paths = <String>[];
  for (final Object? item in tree) {
    final Map<String, Object?> entry = _stringMap(item, '$slug tree item');
    final Object? path = entry['path'];
    if (entry['type'] == 'blob' &&
        path is String &&
        path.startsWith('schema/')) {
      paths.add(path);
    }
  }
  paths.sort();
  const required = <String>{
    'schema/meta.json',
    'schema/schema.json',
    'schema/v2/meta.unstable.json',
    'schema/v2/schema.unstable.json',
  };
  if (!paths.toSet().containsAll(required)) {
    throw StateError('SDK main is missing required schema inputs');
  }
  return List<String>.unmodifiable(paths);
}

Future<List<int>> _downloadBytes(
  HttpClient client,
  Uri uri, {
  String? accept,
}) async {
  final HttpClientRequest request = await client.getUrl(uri);
  if (accept != null) {
    request.headers.set(HttpHeaders.acceptHeader, accept);
  }
  final HttpClientResponse response = await request.close();
  final List<int> bytes = await response.fold<List<int>>(
    <int>[],
    (List<int> previous, List<int> chunk) => previous..addAll(chunk),
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException(
      'GET $uri returned ${response.statusCode}: '
      '${utf8.decode(bytes, allowMalformed: true)}',
      uri: uri,
    );
  }
  return List<int>.unmodifiable(bytes);
}

Map<String, Object?> _manifestJson({
  required String officialCommit,
  required String sdkCommit,
  required List<_DownloadedSnapshot> snapshots,
}) => <String, Object?>{
  'formatVersion': 1,
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'official': <String, Object?>{
    'repository': _officialRepository,
    'commit': officialCommit,
  },
  'sdk': <String, Object?>{'repository': _sdkRepository, 'commit': sdkCommit},
  'files': <Object?>[
    for (final _DownloadedSnapshot snapshot in snapshots)
      <String, Object?>{
        'source': snapshot.spec.source,
        'path': snapshot.spec.localPath,
        'sha256': sha256Hex(snapshot.bytes),
        'url': snapshot.spec.url,
      },
  ],
  'license': <String, Object?>{
    'spdx': 'Apache-2.0',
    'notice':
        'Snapshots are derived from the official Agent Client Protocol '
        'repositories.',
  },
};

List<String> _freshnessChanges(
  Directory schemaRoot,
  SchemaManifest remote,
  List<_DownloadedSnapshot> downloaded,
) {
  final changes = <String>[];
  final SchemaManifest local = SchemaManifest.load(
    File('${schemaRoot.path}/schema_manifest.json'),
  );
  if (local.official.commit != remote.official.commit) {
    changes.add(
      'official main moved from ${local.official.commit} '
      'to ${remote.official.commit}',
    );
  }
  if (local.sdk.commit != remote.sdk.commit) {
    changes.add(
      'SDK main moved from ${local.sdk.commit} to ${remote.sdk.commit}',
    );
  }
  final localEntries = <String, SnapshotEntry>{
    for (final SnapshotEntry entry in local.files) entry.path: entry,
  };
  final remoteEntries = <String, SnapshotEntry>{
    for (final SnapshotEntry entry in remote.files) entry.path: entry,
  };
  final allPaths = <String>{
    ...localEntries.keys,
    ...remoteEntries.keys,
  }.toList()..sort();
  for (final String path in allPaths) {
    final SnapshotEntry? before = localEntries[path];
    final SnapshotEntry? after = remoteEntries[path];
    if (before == null) {
      changes.add('new remote snapshot $path');
    } else if (after == null) {
      changes.add('remote snapshot removed $path');
    } else if (before.sha256 != after.sha256 || before.url != after.url) {
      changes.add('remote snapshot changed $path');
    }
  }
  final bytesByPath = <String, List<int>>{
    for (final _DownloadedSnapshot snapshot in downloaded)
      snapshot.spec.localPath: snapshot.bytes,
  };
  for (final String path in remoteEntries.keys) {
    final File file = File('${schemaRoot.path}/$path');
    if (!file.existsSync()) {
      changes.add('local snapshot missing $path');
    } else if (sha256Hex(file.readAsBytesSync()) !=
        sha256Hex(bytesByPath[path]!)) {
      changes.add('local snapshot content differs $path');
    }
  }
  return changes;
}

void _replaceSnapshots(
  Directory schemaRoot,
  List<_DownloadedSnapshot> snapshots,
) {
  final expected = <String>{
    for (final _DownloadedSnapshot snapshot in snapshots)
      snapshot.spec.localPath,
  };
  final Directory root = Directory('${schemaRoot.path}/snapshots');
  if (root.existsSync()) {
    for (final FileSystemEntity entity in root.listSync(recursive: true)) {
      if (entity is File) {
        final String relative = entity.path.substring(
          schemaRoot.path.length + 1,
        );
        if (!expected.contains(relative)) {
          entity.deleteSync();
        }
      }
    }
  }
  for (final _DownloadedSnapshot snapshot in snapshots) {
    final File target = File('${schemaRoot.path}/${snapshot.spec.localPath}');
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(snapshot.bytes);
  }
}

int _runDart(Directory packageRoot, List<String> arguments) {
  final ProcessResult result = Process.runSync(
    Platform.resolvedExecutable,
    <String>['--suppress-analytics', ...arguments],
    workingDirectory: packageRoot.path,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  return result.exitCode;
}

Map<String, Object?> _stringMap(Object? value, String context) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('Expected an object at $context');
  }
  final result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw FormatException('Expected string keys at $context');
    }
    result[key] = entry.value;
  }
  return result;
}

final class _RemoteSnapshot {
  const _RemoteSnapshot({
    required this.source,
    required this.remotePath,
    required this.localPath,
    required this.commit,
    required this.repositorySlug,
  });

  final String source;
  final String remotePath;
  final String localPath;
  final String commit;
  final String repositorySlug;

  String get url =>
      'https://raw.githubusercontent.com/$repositorySlug/$commit/$remotePath';
}

final class _DownloadedSnapshot {
  const _DownloadedSnapshot({required this.spec, required this.bytes});

  final _RemoteSnapshot spec;
  final List<int> bytes;
}
