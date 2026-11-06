import 'dart:convert';
import 'dart:io';

import 'src/conformance.dart';
import 'src/conformance_emitter.dart';
import 'src/drift.dart';
import 'src/emitter.dart';
import 'src/schema_loader.dart';

void main(List<String> arguments) {
  final unknown = arguments
      .where((String argument) => argument != '--check')
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown arguments: ${unknown.join(' ')}');
    stderr.writeln('Usage: dart run tool/schema/generate.dart [--check]');
    exitCode = 64;
    return;
  }
  final bool check = arguments.contains('--check');
  final Directory schemaRoot = File.fromUri(Platform.script).parent;
  final Directory packageRoot = schemaRoot.parent.parent;
  final loader = SchemaLoader(schemaRoot);
  loader.verifyAll();

  final generated = <String, String>{};
  final Object? allowlistJson = jsonDecode(
    File('${schemaRoot.path}/drift_allowlist.json').readAsStringSync(),
  );
  final DriftAllowlist allowlist = DriftAllowlist.fromJson(allowlistJson);
  final SchemaDriftReport drift = computeSnapshotDrift(loader, allowlist);
  final List<String> driftIssues = unexplainedDrift(drift, allowlist);
  if (driftIssues.isNotEmpty) {
    stderr.writeln('Unexplained schema drift:');
    for (final String issue in driftIssues) {
      stderr.writeln('  $issue');
    }
    exitCode = 1;
    return;
  }
  generated['tool/schema/drift_report.json'] =
      '${const JsonEncoder.withIndent('  ').convert(drift.toJson())}\n';
  final conformancePlans = <ConformanceLanePlan>[];
  for (final GenerationLane lane in generationLanes) {
    final LaneEmission emission = emitLaneArtifacts(loader: loader, lane: lane);
    generated
      ..addAll(emission.sources)
      ..addAll(emitConformanceMatrix(emission.conformance));
    conformancePlans.add(emission.conformance);
  }
  generated['tool/schema/conformance_report.json'] = emitConformanceReport(
    conformancePlans,
  );

  // Stage inside the package so `dart format` uses the package's language
  // version, as it does for the committed sources. Outside a package it falls
  // back to the running SDK's newest language version, whose style differs.
  final dartTool = Directory('${packageRoot.path}/.dart_tool')
    ..createSync(recursive: true);
  final Directory staging = dartTool.createTempSync(
    'dart_acp_schema_generation_',
  );
  try {
    for (final MapEntry<String, String> entry in generated.entries) {
      final file = File('${staging.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    final format = Process.runSync(Platform.resolvedExecutable, <String>[
      '--suppress-analytics',
      'format',
      staging.path,
    ], workingDirectory: packageRoot.path);
    if (format.exitCode != 0) {
      stderr
        ..writeln('Generated Dart failed to format.')
        ..write(format.stdout)
        ..write(format.stderr);
      exitCode = format.exitCode;
      return;
    }

    final differences = <String>[];
    final expectedPaths = generated.keys.toSet();
    for (final GenerationLane lane in generationLanes) {
      final Directory output = Directory(
        '${packageRoot.path}/${lane.outputPath}',
      );
      if (!output.existsSync()) {
        continue;
      }
      for (final FileSystemEntity entity in output.listSync()) {
        if (entity is! File) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        if (!RegExp(
          r'^(?:models|method_descriptors)_\d{3}\.dart$',
        ).hasMatch(name)) {
          continue;
        }
        final String relative = '${lane.outputPath}/$name';
        if (!expectedPaths.contains(relative)) {
          differences.add(relative);
          if (!check) {
            entity.deleteSync();
          }
        }
      }
    }
    final Directory conformanceOutput = Directory(
      '${packageRoot.path}/$conformanceOutputPath',
    );
    if (conformanceOutput.existsSync()) {
      for (final FileSystemEntity entity in conformanceOutput.listSync()) {
        if (entity is! File) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        if (!RegExp(
          r'^v[12]_(?:stable|unstable)_matrix_\d{3}\.dart$',
        ).hasMatch(name)) {
          continue;
        }
        final String relative = '$conformanceOutputPath/$name';
        if (!expectedPaths.contains(relative)) {
          differences.add(relative);
          if (!check) {
            entity.deleteSync();
          }
        }
      }
    }
    for (final String relativePath in generated.keys.toList()..sort()) {
      final File staged = File('${staging.path}/$relativePath');
      final File target = File('${packageRoot.path}/$relativePath');
      final String expected = staged.readAsStringSync();
      if (!target.existsSync() || target.readAsStringSync() != expected) {
        differences.add(relativePath);
        if (!check) {
          target.parent.createSync(recursive: true);
          target.writeAsStringSync(expected);
        }
      }
    }
    if (check && differences.isNotEmpty) {
      stderr.writeln('Generated schema sources are stale:');
      for (final String path in differences) {
        stderr.writeln('  $path');
      }
      exitCode = 1;
      return;
    }
    if (differences.isEmpty) {
      stdout.writeln('Generated schema sources are current.');
    } else {
      stdout.writeln('Updated ${differences.length} generated schema files.');
    }
  } finally {
    if (staging.existsSync()) {
      staging.deleteSync(recursive: true);
    }
  }
}
