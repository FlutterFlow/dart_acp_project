import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _defaultPackagePath = 'packages/dart_acp_sdk';
const Set<String> _dartifyWorkspaceRoots = <String>{'sources', 'specs'};
const Set<String> _requiredPackageFiles = <String>{
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
const Set<String> _requiredMetadataKeys = <String>{
  'description',
  'homepage',
  'issue_tracker',
  'name',
  'repository',
  'version',
};
const Set<String> _allowedRuntimeDependencies = <String>{'json_annotation'};
const List<String> _publicLanguageNeedles = <String>[
  'agentclientprotocol_typescript-sdk_clone',
  'javascript sdk',
  'node.js sdk',
  'plan.md',
  'porting process',
  'todo.md',
  'typescript sdk',
];
const Set<String> _ignoredDirectories = <String>{
  '.dart_tool',
  '.git',
  '.melos_tool',
  'build',
  'coverage',
};

/// Audits the package's archive-facing metadata, links, assets, and boundaries.
void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options == null) {
    exitCode = 64;
    return;
  }
  if (options.showHelp) {
    _printUsage();
    return;
  }

  final repository = Directory(options.repositoryPath).absolute;
  final package = Directory(
    _join(repository.path, options.packagePath),
  ).absolute;
  final findings = <String>[];

  if (!repository.existsSync()) {
    stderr.writeln('Repository does not exist: ${repository.path}');
    exitCode = 66;
    return;
  }
  if (!package.existsSync()) {
    stderr.writeln('Package does not exist: ${package.path}');
    exitCode = 66;
    return;
  }

  _checkRequiredFiles(package, findings);
  _checkPubspec(package, findings);
  _checkLogos(repository, package, findings);
  _checkIgnoredReference(repository, findings);
  _checkPackageBoundary(package, findings);
  _checkPublicLanguage(package, findings);
  _checkMarkdownLinks(repository, package, findings);

  findings.sort();
  if (findings.isNotEmpty) {
    stderr.writeln('Release hygiene check failed:');
    for (final finding in findings) {
      stderr.writeln('  - $finding');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Release hygiene check passed: metadata, dependencies, public '
    'entrypoints, examples, links, package boundary, and logos are valid.',
  );
}

void _checkRequiredFiles(Directory package, List<String> findings) {
  for (final path in _requiredPackageFiles) {
    if (!File(_join(package.path, path)).existsSync()) {
      findings.add('missing required package file: $path');
    }
  }
}

void _checkPubspec(Directory package, List<String> findings) {
  final pubspec = File(_join(package.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return;
  }
  final source = pubspec.readAsStringSync();
  final topLevel = _topLevelScalars(source);
  for (final key in _requiredMetadataKeys) {
    final value = topLevel[key];
    if (value == null || value.trim().isEmpty) {
      findings.add('pubspec is missing nonempty `$key` metadata');
    }
  }
  if (topLevel['name'] != 'dart_acp_sdk') {
    findings.add('pubspec package name must be `dart_acp_sdk`');
  }
  final version = topLevel['version']?.replaceAll(
    RegExp(r'''^['"]|['"]$'''),
    '',
  );
  if (version != null && version.isNotEmpty) {
    _checkVersion(package, version, findings);
  }
  final topics = _IndentedSection.parse(source, 'topics').items;
  if (topics.length < 3 || topics.length > 5) {
    findings.add('pubspec must contain between 3 and 5 topics');
  }
  final runtimeDependencies = _IndentedSection.parse(
    source,
    'dependencies',
  ).mappingKeys;
  final unexpected = runtimeDependencies.difference(
    _allowedRuntimeDependencies,
  );
  final missing = _allowedRuntimeDependencies.difference(runtimeDependencies);
  if (unexpected.isNotEmpty || missing.isNotEmpty) {
    findings.add(
      'runtime dependencies must be exactly '
      '${_allowedRuntimeDependencies.toList()..sort()}; '
      'found ${runtimeDependencies.toList()..sort()}',
    );
  }
}

/// Requires a semantic version that the newest CHANGELOG entry documents.
void _checkVersion(Directory package, String version, List<String> findings) {
  if (!_semanticVersion.hasMatch(version)) {
    findings.add('pubspec version `$version` is not a semantic version');
  }
  final changelog = File(_join(package.path, 'CHANGELOG.md'));
  if (!changelog.existsSync()) {
    return;
  }
  final heading = const LineSplitter()
      .convert(changelog.readAsStringSync())
      .firstWhere((line) => line.startsWith('## '), orElse: () => '');
  final documented = heading.isEmpty
      ? null
      : heading.substring(3).trim().split(RegExp(r'\s+')).first;
  if (documented == null) {
    findings.add('CHANGELOG.md has no `## <version>` entry');
  } else if (documented != version) {
    findings.add(
      'CHANGELOG.md top entry `$documented` must match pubspec version '
      '`$version`',
    );
  }
}

final RegExp _semanticVersion = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
  r'(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$',
);

void _checkLogos(
  Directory repository,
  Directory package,
  List<String> findings,
) {
  final rootLogo = File(_join(repository.path, 'assets/logo.png'));
  final packageLogo = File(_join(package.path, 'assets/logo.png'));
  if (!rootLogo.existsSync() || !packageLogo.existsSync()) {
    if (!rootLogo.existsSync()) {
      findings.add('missing root logo: assets/logo.png');
    }
    return;
  }
  final rootBytes = rootLogo.readAsBytesSync();
  final packageBytes = packageLogo.readAsBytesSync();
  if (!_bytesEqual(rootBytes, packageBytes)) {
    findings.add('root and package logo bytes differ');
  }
  final png = _PngHeader.tryParse(packageBytes);
  if (png == null) {
    findings.add('package logo is not a valid PNG with an IHDR header');
  } else {
    if (png.width != 512 || png.height != 512) {
      findings.add(
        'package logo must be 512x512; found ${png.width}x${png.height}',
      );
    }
    if (!png.hasAlpha) {
      findings.add('package logo must use a PNG color type with alpha');
    }
  }
}

void _checkIgnoredReference(Directory repository, List<String> findings) {
  final gitignore = File(_join(repository.path, '.gitignore'));
  if (!gitignore.existsSync()) {
    findings.add('missing root .gitignore');
    return;
  }
  final ignored = gitignore
      .readAsLinesSync()
      .map((line) => line.trim().replaceAll(RegExp(r'^/+|/+$'), ''))
      .toSet();
  for (final root in _dartifyWorkspaceRoots) {
    if (!ignored.contains(root)) {
      findings.add('ignored Dartify workspace `$root/` is missing');
    }
  }
}

void _checkPackageBoundary(Directory package, List<String> findings) {
  final prohibitedNames = <String>{
    'PLAN.md',
    'TODO.md',
    'phases',
    ..._dartifyWorkspaceRoots,
  };
  for (final entity in _walk(package)) {
    final relative = _relativePath(package, entity);
    final segments = relative.split('/');
    if (segments.any(prohibitedNames.contains)) {
      findings.add(
        'internal planning/reference path is inside package: $relative',
      );
    }
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final source = entity.readAsStringSync().toLowerCase();
    if (_dartifyWorkspaceRoots.any(
      (String root) => source.contains('../$root/'),
    )) {
      findings.add(
        'Dart build/test input references an ignored Dartify workspace: '
        '$relative',
      );
    }
  }
}

void _checkPublicLanguage(Directory package, List<String> findings) {
  final publicFiles = <File>[];
  for (final root in <String>[
    'README.md',
    'CHANGELOG.md',
    'SECURITY.md',
    'lib',
    'example',
    'benchmark',
  ]) {
    final entityPath = _join(package.path, root);
    final file = File(entityPath);
    if (file.existsSync()) {
      publicFiles.add(file);
      continue;
    }
    final directory = Directory(entityPath);
    if (directory.existsSync()) {
      publicFiles.addAll(
        _walk(directory).whereType<File>().where(
          (entry) => entry.path.endsWith('.dart') || entry.path.endsWith('.md'),
        ),
      );
    }
  }
  for (final file in publicFiles) {
    final lower = file.readAsStringSync().toLowerCase();
    for (final needle in _publicLanguageNeedles) {
      if (lower.contains(needle)) {
        findings.add(
          'public file contains implementation-process language '
          '`${needle.toLowerCase()}`: ${_relativePath(package, file)}',
        );
      }
    }
  }
}

void _checkMarkdownLinks(
  Directory repository,
  Directory package,
  List<String> findings,
) {
  final markdownFiles =
      _walk(
          repository,
        ).whereType<File>().where((file) => file.path.endsWith('.md')).toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  final markdownLink = RegExp(r'!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
  final htmlAsset = RegExp(r'''(?:href|src)=["']([^"']+)["']''');
  for (final file in markdownFiles) {
    final source = file.readAsStringSync();
    final targets = <String>[
      ...markdownLink
          .allMatches(source)
          .map((match) => match.group(1))
          .whereType<String>(),
      ...htmlAsset
          .allMatches(source)
          .map((match) => match.group(1))
          .whereType<String>(),
    ];
    for (final rawTarget in targets) {
      final target = _decodeLinkTarget(rawTarget);
      if (target == null) {
        continue;
      }
      final resolved = File(_join(file.parent.path, target)).absolute;
      final directoryTarget = Directory(resolved.path);
      if (!resolved.existsSync() && !directoryTarget.existsSync()) {
        findings.add(
          'broken local link `$rawTarget` in '
          '${_relativePath(repository, file)}',
        );
        continue;
      }
      if (_isWithin(package, file) && !_isWithin(package, resolved)) {
        findings.add(
          'published Markdown link escapes package archive: '
          '${_relativePath(package, file)} -> $rawTarget',
        );
      }
    }
  }
}

String? _decodeLinkTarget(String rawTarget) {
  if (rawTarget.startsWith('#') ||
      rawTarget.startsWith('/') ||
      rawTarget.startsWith('data:') ||
      rawTarget.startsWith('http:') ||
      rawTarget.startsWith('https:') ||
      rawTarget.startsWith('mailto:')) {
    return null;
  }
  final withoutFragment = rawTarget.split('#').first.split('?').first;
  if (withoutFragment.isEmpty) {
    return null;
  }
  try {
    return Uri.decodeComponent(withoutFragment);
  } on FormatException {
    return withoutFragment;
  }
}

Map<String, String> _topLevelScalars(String yaml) {
  final result = <String, String>{};
  final scalar = RegExp(r'^([a-z_]+):\s*(.*?)\s*$');
  for (final line in const LineSplitter().convert(yaml)) {
    if (line.startsWith(RegExp(r'\s')) || line.trimLeft().startsWith('#')) {
      continue;
    }
    final match = scalar.firstMatch(line);
    if (match != null && match.group(2)!.isNotEmpty) {
      result[match.group(1)!] = match.group(2)!;
    }
  }
  return result;
}

Iterable<FileSystemEntity> _walk(Directory root) sync* {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    final entries = directory.listSync(followLinks: false)
      ..sort((left, right) => right.path.compareTo(left.path));
    for (final entry in entries) {
      if (entry is Directory) {
        if (!_ignoredDirectories.contains(_basename(entry.path)) &&
            !_dartifyWorkspaceRoots.contains(_basename(entry.path))) {
          pending.add(entry);
        }
      } else {
        yield entry;
      }
    }
  }
}

bool _isWithin(Directory parent, FileSystemEntity child) {
  final parentPath = '${parent.absolute.path}${Platform.pathSeparator}';
  return child.absolute.path.startsWith(parentPath);
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

String _join(String first, String second) =>
    '$first${Platform.pathSeparator}'
    '${second.replaceAll('/', Platform.pathSeparator)}';

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _relativePath(Directory root, FileSystemEntity entity) {
  final prefix = '${root.absolute.path}${Platform.pathSeparator}';
  return entity.absolute.path
      .substring(prefix.length)
      .replaceAll(Platform.pathSeparator, '/');
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/check_release_hygiene.dart '
    '[--root=.] [--package-root=packages/dart_acp_sdk]',
  );
}

final class _Options {
  const _Options({
    required this.repositoryPath,
    required this.packagePath,
    required this.showHelp,
  });

  final String repositoryPath;
  final String packagePath;
  final bool showHelp;

  static _Options? parse(List<String> arguments) {
    var repositoryPath = '.';
    var packagePath = _defaultPackagePath;
    var showHelp = false;
    for (final argument in arguments) {
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
      } else if (argument.startsWith('--root=')) {
        repositoryPath = argument.substring('--root='.length);
      } else if (argument.startsWith('--package-root=')) {
        packagePath = argument.substring('--package-root='.length);
      } else {
        stderr.writeln('Unknown argument: $argument');
        _printUsage();
        return null;
      }
    }
    if (repositoryPath.isEmpty || packagePath.isEmpty) {
      stderr.writeln('Root and package paths must not be empty.');
      return null;
    }
    return _Options(
      repositoryPath: repositoryPath,
      packagePath: packagePath,
      showHelp: showHelp,
    );
  }
}

final class _IndentedSection {
  const _IndentedSection({required this.items, required this.mappingKeys});

  final List<String> items;
  final Set<String> mappingKeys;

  static _IndentedSection parse(String yaml, String name) {
    final lines = const LineSplitter().convert(yaml);
    final headerIndex = lines.indexWhere((line) => line == '$name:');
    if (headerIndex < 0) {
      return const _IndentedSection(items: <String>[], mappingKeys: <String>{});
    }
    final items = <String>[];
    final mappingKeys = <String>{};
    for (var index = headerIndex + 1; index < lines.length; index += 1) {
      final line = lines[index];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ')) {
        break;
      }
      final trimmed = line.trim();
      if (trimmed.startsWith('- ')) {
        items.add(trimmed.substring(2).trim());
      }
      final mapping = RegExp(r'^([a-zA-Z0-9_]+):').firstMatch(trimmed);
      if (mapping != null) {
        mappingKeys.add(mapping.group(1)!);
      }
    }
    return _IndentedSection(items: items, mappingKeys: mappingKeys);
  }
}

final class _PngHeader {
  const _PngHeader({
    required this.width,
    required this.height,
    required this.hasAlpha,
  });

  final int width;
  final int height;
  final bool hasAlpha;

  static _PngHeader? tryParse(Uint8List bytes) {
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 29 ||
        !_bytesEqual(Uint8List.fromList(signature), bytes.sublist(0, 8)) ||
        ascii.decode(bytes.sublist(12, 16), allowInvalid: true) != 'IHDR') {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    final colorType = bytes[25];
    return _PngHeader(
      width: width,
      height: height,
      hasAlpha: colorType == 4 || colorType == 6,
    );
  }
}
