import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

const double _defaultMinimum = 95;
const String _defaultSourceRoot = 'packages/dart_acp_sdk/lib';
const String _exemptionMarkerPrefix = '// coverage-exempt:';
const int _maximumExemptionMarkerLine = 5;

/// Enforces line coverage for every Dart source in the main package.
void main(List<String> arguments) {
  final options = _CoverageOptions.parse(arguments);
  if (options == null) {
    exitCode = 64;
    return;
  }
  if (options.showHelp) {
    _printUsage();
    return;
  }

  final lcovFile = File(options.lcovPath).absolute;
  final requestedSourceRoot = Directory(options.sourceRoot).absolute;
  if (!lcovFile.existsSync()) {
    stderr.writeln('LCOV report does not exist: ${lcovFile.path}');
    exitCode = 66;
    return;
  }
  if (!requestedSourceRoot.existsSync()) {
    stderr.writeln('Source root does not exist: ${requestedSourceRoot.path}');
    exitCode = 66;
    return;
  }
  final sourceRoot = Directory(requestedSourceRoot.resolveSymbolicLinksSync());

  final report = _parseLcov(
    contents: lcovFile.readAsStringSync(),
    sourceRoot: sourceRoot,
    lcovDirectory: lcovFile.parent,
  );
  if (report.error case final error?) {
    stderr.writeln(error);
    exitCode = 65;
    return;
  }

  final sourceFiles =
      sourceRoot
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => File(_canonicalPath(file)))
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  final exemptionResults = <String, _ExemptionResult>{
    for (final file in sourceFiles)
      file.path: _validateExemption(file, sourceRoot, sourceFiles),
  };
  final exemptionErrors = exemptionResults.values
      .map((result) => result.error)
      .whereType<String>()
      .toList();
  final exemptFiles = <String>{
    for (final entry in exemptionResults.entries)
      if (entry.value.kind != null && entry.value.error == null) entry.key,
  };
  for (final path in exemptFiles) {
    final lines = report.lineHits[path];
    if (lines != null && lines.isNotEmpty) {
      exemptionErrors.add(
        '${_displayPath(path)}: the exemption is invalid because LCOV reports '
        '${lines.length} executable line(s).',
      );
    }
  }
  exemptFiles.removeWhere((path) => report.lineHits[path]?.isNotEmpty ?? false);

  final measuredSourceFiles = sourceFiles
      .map((file) => file.path)
      .where((path) => !exemptFiles.contains(path))
      .toList();
  final missingFiles = measuredSourceFiles
      .where((path) => !report.lineHits.containsKey(path))
      .toList();

  var foundLines = 0;
  var hitLines = 0;
  for (final sourcePath in measuredSourceFiles) {
    final lines = report.lineHits[sourcePath];
    if (lines == null) {
      continue;
    }
    foundLines += lines.length;
    hitLines += lines.values.where((hits) => hits > 0).length;
  }

  if (missingFiles.isNotEmpty) {
    stderr.writeln('LCOV report is missing package sources:');
    for (final path in missingFiles) {
      stderr.writeln('  ${_displayPath(path)}');
    }
  }
  if (exemptionErrors.isNotEmpty) {
    stderr.writeln('Invalid coverage exemptions:');
    for (final error in exemptionErrors) {
      stderr.writeln('  $error');
    }
  }
  if (foundLines == 0) {
    stderr.writeln('LCOV report contains no executable package lines.');
    exitCode = 1;
    return;
  }

  final percentage = hitLines * 100 / foundLines;
  final summary =
      '$hitLines/$foundLines lines (${percentage.toStringAsFixed(2)}%, '
      'required ${options.minimum.toStringAsFixed(2)}%)';
  if (missingFiles.isNotEmpty ||
      exemptionErrors.isNotEmpty ||
      percentage + 0.0000001 < options.minimum) {
    stderr.writeln('Coverage check failed: $summary.');
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Coverage check passed: $summary; '
    '${exemptFiles.length} structurally validated exemption(s).',
  );
}

_ExemptionResult _validateExemption(
  File file,
  Directory sourceRoot,
  List<File> sourceFiles,
) {
  final contents = file.readAsStringSync();
  final markerLines = <({int number, String text})>[];
  final lines = contents.split(RegExp(r'\r?\n'));
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index].trim();
    if (line.startsWith(_exemptionMarkerPrefix)) {
      markerLines.add((number: index + 1, text: line));
    }
  }
  if (markerLines.isEmpty) {
    return const _ExemptionResult();
  }
  final displayPath = _displayPath(file.path);
  if (markerLines.length != 1) {
    return _ExemptionResult.error(
      '$displayPath: expected exactly one coverage exemption marker.',
    );
  }
  final marker = markerLines.single;
  if (marker.number > _maximumExemptionMarkerLine) {
    return _ExemptionResult.error(
      '$displayPath:${marker.number}: exemption markers must appear within '
      'the first $_maximumExemptionMarkerLine lines.',
    );
  }
  final kindName = marker.text.substring(_exemptionMarkerPrefix.length).trim();
  final kind = _CoverageExemptionKind.parse(kindName);
  if (kind == null || marker.text != '$_exemptionMarkerPrefix ${kind.name}') {
    return _ExemptionResult.error(
      '$displayPath:${marker.number}: unsupported or malformed exemption '
      '"${marker.text}". Allowed reasons: '
      '${_CoverageExemptionKind.values.map((value) => value.name).join(', ')}.',
    );
  }

  final parseResult = parseString(
    content: contents,
    path: file.path,
    throwIfDiagnostics: false,
  );
  if (parseResult.errors.isNotEmpty) {
    return _ExemptionResult.error(
      '$displayPath: marked source does not parse as valid Dart.',
    );
  }
  final unit = parseResult.unit;
  final structuralError = switch (kind) {
    _CoverageExemptionKind.directivesOnly => _validateDirectivesOnly(unit),
    _CoverageExemptionKind.constDeclarationsOnly =>
      _validateConstDeclarationsOnly(unit),
    _CoverageExemptionKind.abstractDeclarationsOnly =>
      _validateAbstractDeclarationsOnly(unit),
    _CoverageExemptionKind.conditionalFallback => _validateConditionalFallback(
      file,
      sourceRoot,
      sourceFiles,
    ),
  };
  if (structuralError != null) {
    return _ExemptionResult.error(
      '$displayPath:${marker.number}: reason "${kind.name}" is unjustified: '
      '$structuralError',
    );
  }
  return _ExemptionResult(kind: kind);
}

String? _validateDirectivesOnly(CompilationUnit unit) {
  if (unit.directives.isEmpty) {
    return 'the file contains no library directives.';
  }
  if (unit.declarations.isNotEmpty) {
    return 'the file contains top-level declarations.';
  }
  return null;
}

String? _validateConstDeclarationsOnly(CompilationUnit unit) {
  if (unit.declarations.isEmpty) {
    return 'the file contains no declarations.';
  }
  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration ||
        !declaration.variables.isConst) {
      return 'every top-level declaration must be const data.';
    }
  }
  return null;
}

String? _validateAbstractDeclarationsOnly(CompilationUnit unit) {
  if (unit.declarations.isEmpty) {
    return 'the file contains no declarations.';
  }
  for (final declaration in unit.declarations) {
    if (declaration is! ClassDeclaration ||
        declaration.abstractKeyword == null) {
      return 'every top-level declaration must be an abstract class.';
    }
    for (final member in declaration.body.members) {
      if (member case final MethodDeclaration method) {
        if (method.body is! EmptyFunctionBody) {
          return 'abstract class methods must not have implementations.';
        }
        continue;
      }
      return 'abstract classes may contain only unimplemented methods.';
    }
  }
  return null;
}

String? _validateConditionalFallback(
  File fallback,
  Directory sourceRoot,
  List<File> sourceFiles,
) {
  if (!fallback.path.endsWith('_stub.dart')) {
    return 'conditional fallback files must use the _stub.dart suffix.';
  }
  for (final sourceFile in sourceFiles) {
    if (sourceFile.path == fallback.path) {
      continue;
    }
    final contents = sourceFile.readAsStringSync();
    if (!contents.contains(fallback.uri.pathSegments.last)) {
      continue;
    }
    final parseResult = parseString(
      content: contents,
      path: sourceFile.path,
      throwIfDiagnostics: false,
    );
    if (parseResult.errors.isNotEmpty) {
      continue;
    }
    for (final directive in parseResult.unit.directives) {
      if (directive is! ImportDirective || directive.configurations.isEmpty) {
        continue;
      }
      final uri = directive.uri.stringValue;
      if (uri == null || Uri.tryParse(uri)?.scheme.isNotEmpty == true) {
        continue;
      }
      final imported = File.fromUri(sourceFile.absolute.uri.resolve(uri));
      if (_canonicalPath(imported) == fallback.path &&
          _isInside(sourceRoot.path, fallback.path)) {
        return null;
      }
    }
  }
  return 'the file is not the default target of a conditional import.';
}

_CoverageReport _parseLcov({
  required String contents,
  required Directory sourceRoot,
  required Directory lcovDirectory,
}) {
  final hits = <String, Map<int, int>>{};
  String? currentSource;
  final lines = contents.split(RegExp(r'\r?\n'));
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    if (line.startsWith('SF:')) {
      final value = line.substring(3).trim();
      if (value.isEmpty) {
        return _CoverageReport.error(
          'Malformed LCOV source record at line ${index + 1}.',
        );
      }
      currentSource = _resolveSourcePath(
        value,
        sourceRoot: sourceRoot,
        lcovDirectory: lcovDirectory,
      );
      if (_isInside(sourceRoot.path, currentSource)) {
        hits.putIfAbsent(currentSource, () => <int, int>{});
      }
      continue;
    }
    if (!line.startsWith('DA:') || currentSource == null) {
      continue;
    }
    if (!hits.containsKey(currentSource)) {
      continue;
    }
    final values = line.substring(3).split(',');
    if (values.length < 2) {
      return _CoverageReport.error(
        'Malformed LCOV line record at line ${index + 1}.',
      );
    }
    final lineNumber = int.tryParse(values[0]);
    final hitCount = int.tryParse(values[1]);
    if (lineNumber == null || lineNumber < 1 || hitCount == null) {
      return _CoverageReport.error(
        'Malformed LCOV line record at line ${index + 1}.',
      );
    }
    final sourceHits = hits[currentSource]!;
    final previous = sourceHits[lineNumber] ?? 0;
    if (hitCount > previous) {
      sourceHits[lineNumber] = hitCount;
    } else {
      sourceHits.putIfAbsent(lineNumber, () => hitCount);
    }
  }
  return _CoverageReport(lineHits: hits);
}

String _resolveSourcePath(
  String source, {
  required Directory sourceRoot,
  required Directory lcovDirectory,
}) {
  if (File(source).isAbsolute) {
    return _canonicalPath(File(source));
  }

  final packageRoot = sourceRoot.parent;
  final candidates = <File>[
    File('${Directory.current.path}${Platform.pathSeparator}$source'),
    File('${packageRoot.path}${Platform.pathSeparator}$source'),
    File('${lcovDirectory.path}${Platform.pathSeparator}$source'),
  ];
  for (final candidate in candidates) {
    if (candidate.existsSync()) {
      return _canonicalPath(candidate);
    }
  }
  return _canonicalPath(candidates.first);
}

String _canonicalPath(File file) {
  if (file.existsSync()) {
    return file.resolveSymbolicLinksSync();
  }
  return file.absolute.path;
}

bool _isInside(String directoryPath, String filePath) {
  final prefix = directoryPath.endsWith(Platform.pathSeparator)
      ? directoryPath
      : '$directoryPath${Platform.pathSeparator}';
  return filePath.startsWith(prefix);
}

String _displayPath(String path) {
  final root = Directory.current.absolute.path;
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/check_coverage.dart '
    '[--minimum=95] [--source-root=packages/dart_acp_sdk/lib] '
    '<coverage/lcov.info>',
  );
}

final class _CoverageOptions {
  const _CoverageOptions({
    required this.lcovPath,
    required this.sourceRoot,
    required this.minimum,
    required this.showHelp,
  });

  final String lcovPath;
  final String sourceRoot;
  final double minimum;
  final bool showHelp;

  static _CoverageOptions? parse(List<String> arguments) {
    var sourceRoot = _defaultSourceRoot;
    var minimum = _defaultMinimum;
    var showHelp = false;
    final positional = <String>[];

    for (final argument in arguments) {
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
      } else if (argument.startsWith('--minimum=')) {
        final value = argument.substring('--minimum='.length);
        minimum = double.tryParse(value) ?? -1;
      } else if (argument.startsWith('--source-root=')) {
        sourceRoot = argument.substring('--source-root='.length);
      } else if (argument.startsWith('-')) {
        stderr.writeln('Unknown argument: $argument');
        _printUsage();
        return null;
      } else {
        positional.add(argument);
      }
    }

    if (showHelp) {
      return _CoverageOptions(
        lcovPath: '',
        sourceRoot: sourceRoot,
        minimum: minimum,
        showHelp: true,
      );
    }
    if (minimum < 0 || minimum > 100) {
      stderr.writeln('Coverage minimum must be between 0 and 100.');
      return null;
    }
    if (sourceRoot.isEmpty || positional.length != 1) {
      _printUsage();
      return null;
    }
    return _CoverageOptions(
      lcovPath: positional.single,
      sourceRoot: sourceRoot,
      minimum: minimum,
      showHelp: false,
    );
  }
}

enum _CoverageExemptionKind {
  directivesOnly('directives-only'),
  constDeclarationsOnly('const-declarations-only'),
  abstractDeclarationsOnly('abstract-declarations-only'),
  conditionalFallback('conditional-fallback');

  const _CoverageExemptionKind(this.name);

  final String name;

  static _CoverageExemptionKind? parse(String name) {
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}

final class _ExemptionResult {
  const _ExemptionResult({this.kind}) : error = null;

  const _ExemptionResult.error(String this.error) : kind = null;

  final _CoverageExemptionKind? kind;
  final String? error;
}

final class _CoverageReport {
  const _CoverageReport({required this.lineHits}) : error = null;

  const _CoverageReport.error(String message)
    : lineHits = const <String, Map<int, int>>{},
      error = message;

  final Map<String, Map<int, int>> lineHits;
  final String? error;
}
