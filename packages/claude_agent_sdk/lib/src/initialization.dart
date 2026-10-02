import 'json.dart';

/// One model offered by the connected Claude runtime.
final class ClaudeModelInfo {
  /// Decodes model discovery metadata.
  ClaudeModelInfo.fromJson(JsonMap json)
    : value = requiredString(json, 'value', 'model'),
      displayName =
          optionalString(json, 'displayName', 'model') ??
          requiredString(json, 'value', 'model'),
      description = optionalString(json, 'description', 'model') ?? '',
      resolvedModel = optionalString(json, 'resolvedModel', 'model'),
      supportsAutoMode =
          optionalBool(json, 'supportsAutoMode', 'model') ?? false,
      supportsEffort = optionalBool(json, 'supportsEffort', 'model') ?? false,
      supportsAdaptiveThinking =
          optionalBool(json, 'supportsAdaptiveThinking', 'model') ?? false,
      supportsFastMode =
          optionalBool(json, 'supportsFastMode', 'model') ?? false,
      supportedEffortLevels = _stringList(
        json['supportedEffortLevels'],
        'model.supportedEffortLevels',
      ),
      raw = immutableJsonMap(json);

  /// Picker value accepted by `setModel`.
  final String value;

  /// Human-readable model name.
  final String displayName;

  /// Human-readable model description.
  final String description;

  /// Canonical provider model, when reported.
  final String? resolvedModel;

  /// Whether the model supports autonomous permission mode.
  final bool supportsAutoMode;

  /// Whether the model supports an effort setting.
  final bool supportsEffort;

  /// Whether the model supports runtime-selected adaptive thinking.
  final bool supportsAdaptiveThinking;

  /// Whether the model supports Fast mode.
  final bool supportsFastMode;

  /// Supported effort values.
  final List<String> supportedEffortLevels;

  /// Complete forward-compatible payload.
  final JsonMap raw;
}

/// One slash command offered by the connected Claude runtime.
final class ClaudeCommandInfo {
  /// Decodes command discovery metadata.
  ClaudeCommandInfo.fromJson(JsonMap json)
    : name = requiredString(json, 'name', 'command'),
      description = optionalString(json, 'description', 'command') ?? '',
      argumentHint = _argumentHint(json['argumentHint']),
      raw = immutableJsonMap(json);

  /// Command name without a leading slash.
  final String name;

  /// Human-readable description.
  final String description;

  /// Optional command argument hint.
  final String? argumentHint;

  /// Complete forward-compatible payload.
  final JsonMap raw;
}

/// One main-thread or delegated agent offered by the runtime.
final class ClaudeAgentInfo {
  /// Decodes agent discovery metadata.
  ClaudeAgentInfo.fromJson(JsonMap json)
    : name = requiredString(json, 'name', 'agent'),
      description = optionalString(json, 'description', 'agent') ?? '',
      model = optionalString(json, 'model', 'agent'),
      raw = immutableJsonMap(json);

  /// Agent identifier.
  final String name;

  /// Human-readable description.
  final String description;

  /// Agent-specific model, when reported.
  final String? model;

  /// Complete forward-compatible payload.
  final JsonMap raw;
}

/// Account metadata returned during initialization.
final class ClaudeAccountInfo {
  /// Decodes account metadata.
  ClaudeAccountInfo.fromJson(JsonMap json)
    : email = optionalString(json, 'email', 'account'),
      organization = optionalString(json, 'organization', 'account'),
      subscriptionType = optionalString(json, 'subscriptionType', 'account'),
      tokenSource = optionalString(json, 'tokenSource', 'account'),
      apiKeySource = optionalString(json, 'apiKeySource', 'account'),
      apiProvider = optionalString(json, 'apiProvider', 'account'),
      raw = immutableJsonMap(json);

  /// Account email, when available.
  final String? email;

  /// Organization name, when available.
  final String? organization;

  /// Subscription tier, when available.
  final String? subscriptionType;

  /// Authentication token source, when available.
  final String? tokenSource;

  /// API-key source, when API-key authentication is active.
  final String? apiKeySource;

  /// Active API provider/backend.
  final String? apiProvider;

  /// Complete forward-compatible payload.
  final JsonMap raw;
}

/// Initialization metadata for a connected session.
final class ClaudeInitializationResult {
  /// Decodes an initialize response.
  ClaudeInitializationResult.fromJson(JsonMap json)
    : models = _objects(
        json['models'],
        'initialize.models',
        ClaudeModelInfo.fromJson,
      ),
      commands = _objects(
        json['commands'],
        'initialize.commands',
        ClaudeCommandInfo.fromJson,
      ),
      agents = _objects(
        json['agents'],
        'initialize.agents',
        ClaudeAgentInfo.fromJson,
      ),
      account = json['account'] == null
          ? null
          : ClaudeAccountInfo.fromJson(
              asJsonMap(json['account'], 'initialize.account'),
            ),
      outputStyle = optionalString(json, 'output_style', 'initialize'),
      availableOutputStyles = _stringList(
        json['available_output_styles'],
        'initialize.available_output_styles',
      ),
      fastModeState = optionalString(json, 'fast_mode_state', 'initialize'),
      fastModeDisabledReason = optionalString(
        json,
        'fast_mode_disabled_reason',
        'initialize',
      ),
      capabilities = _capabilities(json['capabilities']),
      raw = immutableJsonMap(json);

  /// Models available for this session.
  final List<ClaudeModelInfo> models;

  /// Commands available for this session.
  final List<ClaudeCommandInfo> commands;

  /// Agents reported during initialization.
  final List<ClaudeAgentInfo> agents;

  /// Connected account, when authenticated.
  final ClaudeAccountInfo? account;

  /// Selected output style.
  final String? outputStyle;

  /// Output styles selectable by this runtime.
  final List<String> availableOutputStyles;

  /// Fast-mode state (`on`, `off`, or `cooldown`), when supported.
  final String? fastModeState;

  /// Open-set reason Fast mode is unavailable.
  final String? fastModeDisabledReason;

  /// Runtime capability extensions.
  ///
  /// Claude Code sends either an object of named extensions or, since
  /// 2.1.287, a list of capability names (`["ui_surface_v1"]`); a listed name
  /// reads here as `name: true`. Any other shape is left to [raw].
  final JsonMap capabilities;

  /// Complete forward-compatible payload.
  final JsonMap raw;
}

/// [ClaudeInitializationResult.capabilities] from either wire shape. It is an
/// open-set advertisement, so a shape this SDK does not know must not fail
/// the whole initialize response (and with it the session).
JsonMap _capabilities(Object? value) => switch (value) {
  final Map<Object?, Object?> map => immutableJsonMap(
    asJsonMap(map, 'initialize.capabilities'),
  ),
  final List<Object?> names => immutableJsonMap({
    for (final name in names.whereType<String>()) name: true,
  }),
  _ => const <String, Object?>{},
};

List<String> _stringList(Object? value, String context) {
  if (value == null) return const <String>[];
  if (value is! List<Object?>) {
    throw FormatException('$context must be an array');
  }
  return List<String>.unmodifiable(
    value.map((item) {
      if (item is! String) {
        throw FormatException('$context must contain strings');
      }
      return item;
    }),
  );
}

String? _argumentHint(Object? value) => switch (value) {
  null => null,
  String() => value,
  List<Object?>() => value.whereType<String>().join(' '),
  _ => throw const FormatException(
    'command.argumentHint must be a string or string array',
  ),
};

List<T> _objects<T>(Object? value, String context, T Function(JsonMap) decode) {
  if (value == null) return <T>[];
  if (value is! List<Object?>) {
    throw FormatException('$context must be an array');
  }
  return List<T>.unmodifiable(
    value.map((item) => decode(asJsonMap(item, context))),
  );
}
