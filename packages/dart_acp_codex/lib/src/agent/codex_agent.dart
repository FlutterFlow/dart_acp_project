import 'dart:async';
import 'dart:collection';

import 'package:dart_acp_sdk/dart_acp_sdk.dart';
import 'package:dart_acp_sdk/experimental/v1_unstable.dart' as unstable;

import '../app_server/backend.dart';
import '../app_server/json_values.dart';
import '../bridge/approval_bridge.dart';
import '../bridge/commands.dart';
import '../bridge/elicitation_bridge.dart';
import '../bridge/event_mapper.dart';
import '../bridge/history_mapper.dart';
import '../bridge/mcp_mapper.dart';
import '../bridge/prompt_mapper.dart';
import '../bridge/response_history.dart';
import '../bridge/tool_mapper.dart';
import '../config/authentication.dart';
import '../config/models.dart';
import '../config/modes.dart';
import '../config/providers.dart';
import '../runtime/diagnostics.dart';
import '../runtime/options.dart';
import '../session/mcp_startup.dart';
import '../session/state.dart';
import '../session/steering_queue.dart';
import '../session/thread_title.dart';
import 'extensions.dart';

/// ACP agent backed by a Codex app-server connection.
final class CodexAgent {
  /// Creates an agent over [backend].
  CodexAgent({
    required CodexBackend backend,
    CodexAdapterOptions? options,
    CodexPromptMapper promptMapper = const CodexPromptMapper(),
    CodexMcpMapper mcpMapper = const CodexMcpMapper(),
  }) : _backend = backend,
       options = options ?? CodexAdapterOptions(),
       _promptMapper = promptMapper,
       _mcpMapper = mcpMapper,
       _commands = CodexCommands(
         backend,
         mcpStatusTimeout:
             options?.mcpStatusTimeout ?? CodexCommands.defaultMcpStatusTimeout,
       ) {
    if (this.options.defaultAuthentication case CodexGatewayAuthentication(
      :final baseUrl,
      :final headers,
      :final providerName,
    )) {
      _gateway = CodexGatewayConfiguration(
        baseUrl: baseUrl,
        headers: <String, String>{'X-Client-Feature-ID': 'codex', ...headers},
        providerName: providerName ?? 'User-provided gateway',
      );
    }
    final baseApp = AcpAgentApp.v1(
      implementation: Implementation(
        name: 'dart_acp_codex',
        title: 'Codex',
        version: '0.1.5',
      ),
      capabilities: AgentCapabilities(
        loadSession: true,
        promptCapabilities: PromptCapabilities(
          image: true,
          audio: false,
          embeddedContext: true,
        ),
        mcpCapabilities: McpCapabilities(http: true, sse: false),
        sessionCapabilities: SessionCapabilities(
          list: SessionListCapabilities(),
          delete: SessionDeleteCapabilities(),
          additionalDirectories: SessionAdditionalDirectoriesCapabilities(),
          resume: SessionResumeCapabilities(),
          close: SessionCloseCapabilities(),
        ),
        auth: AgentAuthCapabilities(logout: LogoutCapabilities()),
        meta: AcpJsonObject.fromObject(<String, Object?>{
          'steering': <String, Object?>{'supported': true},
          'goalControl': AcpGoalControlCapabilities(
            AcpGoalControlAction.values,
          ).toJson(),
        }),
      ),
      authMethods: _authMethods(this.options),
      capabilityExtensions: AcpJsonObject.fromObject(<String, Object?>{
        'providers': <String, Object?>{},
      }),
      // The adapter runs in the client's own process (see [CodexAcpClient]),
      // so there is no trust boundary to hide behind: a handler exception
      // surfaced as a bare "Internal error" is a failed turn nobody can
      // diagnose. Details ride in the error's `data`.
      //
      // `allowBatches: false` is repeated deliberately, not inherited:
      // [AcpApplicationOptions] defaults this whole object to
      // `JsonRpcConnectionOptions(allowBatches: false)`, while
      // [JsonRpcConnectionOptions] itself defaults the flag to true — so
      // naming any option here would silently turn batching back on, and
      // stable v1 keeps rejecting batches.
      options: const AcpApplicationOptions(
        jsonRpcOptions: JsonRpcConnectionOptions(
          allowBatches: false,
          exposeInternalErrorDetails: true,
        ),
      ),
    );
    final unstableApp = unstable.AcpV1UnstableAgentApp(
      baseApp,
    ).withV1UnstableMethods();
    app = unstableApp
        .onConnect(_onConnect)
        .onAuthenticate(_authenticate)
        .onLogout(_logout)
        .onNewSession(_newSession)
        .onResumeSession(_resumeSession)
        .onLoadSession(_loadSession)
        .onListSessions(_listSessions)
        .onDeleteSession(_deleteSession)
        .onCloseSession(_closeSession)
        .onSetSessionMode(_setMode)
        .onSetSessionConfigOption(_setConfigOption)
        .onPrompt(_prompt)
        .onCancelSession(_cancel)
        .onRequest(unstable.providersListMethod, _listProviders)
        .onRequest(unstable.providersSetMethod, _setProvider)
        .onRequest(unstable.providersDisableMethod, _disableProvider)
        .onRequest(codexSteeringMethod, _steerExtension)
        .onRequest(acpSessionGoalControlMethod, _goalControlExtension);
  }

  final CodexBackend _backend;

  /// Runtime options.
  final CodexAdapterOptions options;

  final CodexPromptMapper _promptMapper;
  final CodexMcpMapper _mcpMapper;
  final CodexCommands _commands;
  final CodexResponseHistory _responseHistory = const CodexResponseHistory();
  final CodexSessionRegistry _sessions = CodexSessionRegistry();
  final Map<String, CodexEventMapper> _events = <String, CodexEventMapper>{};
  final Map<String, CodexHistoryMapper> _history =
      <String, CodexHistoryMapper>{};
  final Map<String, CodexApprovalBridge> _approvals =
      <String, CodexApprovalBridge>{};
  final Map<String, CodexElicitationBridge> _elicitations =
      <String, CodexElicitationBridge>{};
  final Map<String, CodexSteeringQueue<List<ContentBlock>>> _steeringQueues =
      <String, CodexSteeringQueue<List<ContentBlock>>>{};
  final List<CodexModel> _models = <CodexModel>[];
  Future<void>? _initialization;
  AcpAgentContext? _client;
  // Cancelled when the owning backend closes its streams.
  // ignore: cancel_subscriptions
  StreamSubscription<CodexNotification>? _notificationSubscription;
  // Cancelled when the owning backend closes its streams.
  // ignore: cancel_subscriptions
  StreamSubscription<CodexPendingServerRequest>? _requestSubscription;
  bool _terminalOutput = false;
  // Set once the app-server streams end: the process behind every session in
  // this adapter is gone, and nothing can run on it again.
  bool _backendGone = false;

  /// Immutable typed ACP application.
  late final AcpAgentApp app;

  /// Completes after the app-server handshake and model discovery finish.
  Future<void> get initialized => _ensureInitialized();

  static List<AuthMethod> _authMethods(CodexAdapterOptions options) {
    final methods = <AuthMethod>[
      AuthMethodAgentVariant(
        AuthMethodAgent(
          id: AuthMethodId('api-key'),
          name: 'API Key',
          description: 'Use an API key to authenticate.',
          meta: AcpJsonObject.fromObject(<String, Object?>{
            'api-key': <String, Object?>{'provider': 'openai'},
          }),
        ),
      ),
    ];
    if (options.environment['NO_BROWSER'] == null) {
      methods.add(
        AuthMethodAgentVariant(
          AuthMethodAgent(
            id: AuthMethodId('chat-gpt'),
            name: 'ChatGPT',
            description: 'Use ChatGPT to authenticate.',
          ),
        ),
      );
    }
    methods.add(
      AuthMethodAgentVariant(
        AuthMethodAgent(
          id: AuthMethodId('gateway'),
          name: 'Custom model gateway',
          description: 'Use an OpenAI-compatible model gateway.',
          meta: AcpJsonObject.fromObject(<String, Object?>{
            'gateway': <String, Object?>{
              'protocol': 'openai',
              'restartRequired': false,
            },
          }),
        ),
      ),
    );
    return methods;
  }

  Future<void> _onConnect(AcpAgentConnection connection) async {
    _client = connection.client;
    final capabilities = connection.lifecycle.peerCapabilities.value.toObject();
    final meta = capabilities['_meta'];
    _terminalOutput =
        meta is Map<Object?, Object?> && meta['terminal_output'] == true;
    _notificationSubscription ??= _backend.notifications.listen(
      _handleNotification,
      onError: _handleBackendError,
      onDone: _handleBackendClosed,
    );
    _requestSubscription ??= _backend.requests.listen(
      _handleServerRequest,
      onError: _handleBackendError,
      onDone: _handleBackendClosed,
    );
    await _ensureInitialized();
  }

  Future<void> _ensureInitialized() => _initialization ??= _initializeBackend();

  Future<void> _initializeBackend() async {
    await _backend.request(
      'initialize',
      params: CodexJsonObject.from(<String, Object?>{
        'clientInfo': <String, Object?>{
          'name': 'dart_acp_codex',
          'title': 'Dart ACP Codex',
          'version': '0.1.5',
        },
        'capabilities': <String, Object?>{
          'experimentalApi': true,
          'requestAttestation': false,
        },
      }),
    );
    await _backend.notify('initialized');
    await _refreshModels();
  }

  Future<void> _refreshModels() async {
    final parsed = <CodexModel>[];
    String? cursor;
    do {
      final response = await _backend.request(
        'model/list',
        params: CodexJsonObject.from(<String, Object?>{
          'cursor': cursor,
          'limit': null,
        }),
      );
      final data = response['data'];
      if (data is List<Object?>) {
        for (final value in data) {
          if (value is Map<Object?, Object?>) {
            final model = _parseModel(CodexJsonObject.from(value));
            if (model != null) {
              parsed.add(model);
            }
          }
        }
      }
      cursor = response.optionalString('nextCursor');
    } while (cursor != null && cursor.isNotEmpty);
    _models
      ..clear()
      ..addAll(parsed);
  }

  CodexModel? _parseModel(CodexJsonObject json) {
    final id = json.optionalString('model') ?? json.optionalString('id');
    if (id == null || id.isEmpty || json['hidden'] == true) {
      return null;
    }
    final efforts = <CodexReasoningEffort>[];
    final rawEfforts = json['supportedReasoningEfforts'];
    if (rawEfforts is List<Object?>) {
      for (final value in rawEfforts) {
        final raw = value is String
            ? value
            : value is Map<Object?, Object?>
            ? value['reasoningEffort'] ?? value['effort']
            : null;
        if (raw is String) {
          final effort = CodexReasoningEffort.tryParse(raw);
          if (effort != null) {
            efforts.add(effort);
          }
        }
      }
    }
    final defaultEffort =
        CodexReasoningEffort.tryParse(
          json.optionalString('defaultReasoningEffort'),
        ) ??
        efforts.firstOrNull ??
        CodexReasoningEffort.medium;
    if (!efforts.contains(defaultEffort)) {
      efforts.add(defaultEffort);
    }
    final modalities = <CodexInputModality>{CodexInputModality.text};
    final rawModalities = json['inputModalities'];
    if (rawModalities is List<Object?> && rawModalities.contains('image')) {
      modalities.add(CodexInputModality.image);
    }
    final tiers = <CodexServiceTier>{};
    final rawTiers = json['serviceTiers'];
    if (rawTiers is List<Object?>) {
      for (final value in rawTiers) {
        final id = value is String
            ? value
            : value is Map<Object?, Object?>
            ? value['id']
            : null;
        if (id == CodexServiceTier.fast.id) {
          tiers.add(CodexServiceTier.fast);
        }
      }
    }
    return CodexModel(
      id: id,
      name: json.optionalString('displayName') ?? id,
      description: json.optionalString('description') ?? '',
      isDefault: json['isDefault'] == true,
      defaultReasoningEffort: defaultEffort,
      reasoningEfforts: efforts,
      inputModalities: modalities,
      serviceTiers: tiers,
      contextWindow: json.optionalInt('contextWindow'),
    );
  }

  Future<AuthenticateResponse> _authenticate(
    AcpAgentRequestContext<AuthenticateRequest> context,
  ) async {
    await _ensureInitialized();
    final request = context.params;
    switch (request.methodId.value) {
      case 'api-key':
        final meta = request.meta?.toObject();
        final apiKeyMeta = meta?['api-key'];
        final apiKey = apiKeyMeta is Map<Object?, Object?>
            ? apiKeyMeta['apiKey']
            : null;
        final resolved = apiKey is String && apiKey.trim().isNotEmpty
            ? apiKey
            : _apiKeyFromOptions();
        await _loginAndWait(<String, Object?>{
          'type': 'apiKey',
          'apiKey': resolved,
        });
      case 'chat-gpt':
        final account = await _backend.request(
          'account/read',
          params: CodexJsonObject.from(<String, Object?>{'refreshToken': true}),
        );
        if (account.optionalObject('account')?.optionalString('type') !=
            'chatgpt') {
          await _loginAndWait(<String, Object?>{'type': 'chatgpt'});
        }
      case 'gateway':
        _configureGateway(request);
      default:
        throw JsonRpcRequestException.invalidParams(
          data: <String, Object?>{'methodId': request.methodId.value},
        );
    }
    return AuthenticateResponse();
  }

  String _apiKeyFromOptions() {
    if (options.defaultAuthentication case CodexApiKeyAuthentication(
      :final apiKey,
    )) {
      return apiKey;
    }
    for (final name in const <String>['CODEX_API_KEY', 'OPENAI_API_KEY']) {
      final value = options.environment[name]?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    throw const CodexConfigurationException(
      'CODEX_API_KEY or OPENAI_API_KEY is required for API-key login.',
    );
  }

  Future<void> _loginAndWait(Map<String, Object?> params) async {
    final completed = _nextNotification('account/login/completed');
    await _backend.request(
      'account/login/start',
      params: CodexJsonObject.from(params),
    );
    final result = await completed;
    if (result.params['success'] != true) {
      throw const CodexProtocolException('Codex authentication failed.');
    }
  }

  void _configureGateway(AuthenticateRequest request) {
    final meta = request.meta?.toObject();
    final raw = meta?['gateway'];
    if (raw is! Map<Object?, Object?> ||
        raw['baseUrl'] is! String ||
        raw['headers'] is! Map<Object?, Object?>) {
      throw const CodexConfigurationException(
        'Gateway authentication requires baseUrl and headers metadata.',
      );
    }
    final headers = <String, String>{};
    for (final entry in (raw['headers']! as Map<Object?, Object?>).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const CodexConfigurationException(
          'Gateway headers must contain string keys and values.',
        );
      }
      headers[entry.key! as String] = entry.value! as String;
    }
    final providerName = raw['providerName'];
    _gateway = CodexGatewayConfiguration(
      baseUrl: Uri.parse(raw['baseUrl']! as String),
      headers: <String, String>{'X-Client-Feature-ID': 'codex', ...headers},
      providerName: providerName is String
          ? providerName
          : 'User-provided gateway',
    );
  }

  static const String _customGatewayProviderId = 'custom-gateway';

  CodexGatewayConfiguration? _gateway;

  unstable.ListProvidersResponse _listProviders(
    AcpAgentRequestContext<unstable.ListProvidersRequest> context,
  ) {
    final gateway = _gateway;
    return unstable.ListProvidersResponse(
      providers: <unstable.ProviderInfo>[
        unstable.ProviderInfo(
          providerId: unstable.ProviderId(_customGatewayProviderId),
          supported: const <unstable.LlmProtocol>[unstable.LlmProtocol.openai],
          requiredValue: false,
          current: gateway == null
              ? null
              : unstable.ProviderCurrentConfig(
                  apiType: unstable.LlmProtocol.openai,
                  baseUrl: gateway.baseUrl.toString(),
                ),
        ),
      ],
    );
  }

  unstable.SetProviderResponse _setProvider(
    AcpAgentRequestContext<unstable.SetProviderRequest> context,
  ) {
    final request = context.params;
    if (request.providerId.value != _customGatewayProviderId) {
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'providerId': request.providerId.value},
      );
    }
    if (request.apiType != unstable.LlmProtocol.openai) {
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'apiType': request.apiType.value},
      );
    }
    try {
      _gateway = CodexGatewayConfiguration(
        baseUrl: Uri.parse(request.baseUrl),
        headers: <String, String>{
          'X-Client-Feature-ID': 'codex',
          ...?request.headers,
        },
        providerName: 'User-provided gateway',
      );
    } on FormatException catch (error) {
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'baseUrl': request.baseUrl, 'error': '$error'},
      );
    } on CodexConfigurationException catch (error) {
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'baseUrl': request.baseUrl, 'error': '$error'},
      );
    }
    return unstable.SetProviderResponse();
  }

  unstable.DisableProviderResponse _disableProvider(
    AcpAgentRequestContext<unstable.DisableProviderRequest> context,
  ) {
    if (context.params.providerId.value == _customGatewayProviderId) {
      _gateway = null;
    }
    return unstable.DisableProviderResponse();
  }

  Future<LogoutResponse> _logout(
    AcpAgentRequestContext<LogoutRequest> context,
  ) async {
    await _ensureInitialized();
    await _backend.request('account/logout');
    _gateway = null;
    return LogoutResponse();
  }

  Future<NewSessionResponse> _newSession(
    AcpAgentRequestContext<NewSessionRequest> context,
  ) async {
    final state = await _openSession(
      cwd: context.params.cwd,
      additionalDirectories:
          context.params.additionalDirectories ?? const <String>[],
      mcpServers: context.params.mcpServers,
    );
    _scheduleInitialUpdates(context.client, state);
    return NewSessionResponse(
      sessionId: state.sessionId,
      modes: _modeState(state),
      configOptions: _configOptions(state),
    );
  }

  Future<ResumeSessionResponse> _resumeSession(
    AcpAgentRequestContext<ResumeSessionRequest> context,
  ) async {
    final state = await _openSession(
      requestedId: context.params.sessionId,
      cwd: context.params.cwd,
      additionalDirectories:
          context.params.additionalDirectories ?? const <String>[],
      mcpServers: context.params.mcpServers ?? const <McpServer>[],
      resume: true,
    );
    _scheduleInitialUpdates(context.client, state);
    return ResumeSessionResponse(
      modes: _modeState(state),
      configOptions: _configOptions(state),
    );
  }

  Future<LoadSessionResponse> _loadSession(
    AcpAgentRequestContext<LoadSessionRequest> context,
  ) async {
    final result = await _resumeThread(
      requestedId: context.params.sessionId,
      cwd: context.params.cwd,
      additionalDirectories:
          context.params.additionalDirectories ?? const <String>[],
      mcpServers: context.params.mcpServers,
    );
    final state = result.$1;
    final thread = result.$2.requireObject('thread');
    final structuredHistory = _historyFor(state).map(thread);
    final fallbackHistory = await _responseHistory.recover(thread);
    final history = fallbackHistory == null
        ? structuredHistory
        : _responseHistory.merge(fallbackHistory, structuredHistory);
    for (final update in history) {
      await context.client.updateSession(
        SessionNotification(sessionId: state.sessionId, update: update),
      );
    }
    _scheduleInitialUpdates(context.client, state);
    return LoadSessionResponse(
      modes: _modeState(state),
      configOptions: _configOptions(state),
    );
  }

  Future<CodexSessionState> _openSession({
    SessionId? requestedId,
    required String cwd,
    required Iterable<String> additionalDirectories,
    required Iterable<McpServer> mcpServers,
    bool resume = false,
  }) async {
    if (resume) {
      return (await _resumeThread(
        requestedId: requestedId!,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        mcpServers: mcpServers,
        excludeTurns: options.excludeTurnsOnResume,
      )).$1;
    }
    await _ensureInitialized();
    final model = _defaultModel;
    final response = await _backend.request(
      'thread/start',
      params: CodexJsonObject.from(<String, Object?>{
        'model': model?.id,
        'modelProvider': options.modelProvider ?? _gatewayProviderId,
        'serviceTier': null,
        'cwd': cwd,
        'approvalPolicy': CodexAgentMode.workspaceWrite.approvalPolicy,
        'sandbox': 'workspace-write',
        'config': _sessionConfig(mcpServers),
        'threadSource': 'appServer',
      }),
    );
    try {
      final state = _installSession(
        response: response,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        fallbackId: requestedId,
        autoNameOnPrompt: true,
      );
      await _refreshGoal(state);
      return state;
    } on Object {
      await _unsubscribeResponseThread(response);
      rethrow;
    }
  }

  Future<(CodexSessionState, CodexJsonObject)> _resumeThread({
    required SessionId requestedId,
    required String cwd,
    required Iterable<String> additionalDirectories,
    required Iterable<McpServer> mcpServers,
    bool excludeTurns = false,
  }) async {
    await _ensureInitialized();
    final response = await _backend.request(
      'thread/resume',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': requestedId.value,
        'cwd': cwd,
        'modelProvider': options.modelProvider ?? _gatewayProviderId,
        'config': _sessionConfig(mcpServers),
        if (excludeTurns) 'excludeTurns': true,
      }),
    );
    try {
      final state = _installSession(
        response: response,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        fallbackId: requestedId,
        autoNameOnPrompt: false,
      );
      await _refreshGoal(state);
      return (state, response);
    } on Object {
      await _unsubscribeResponseThread(response);
      rethrow;
    }
  }

  Future<void> _unsubscribeResponseThread(CodexJsonObject response) async {
    final id = response.optionalObject('thread')?.optionalString('id');
    if (id != null) {
      await _backend.request(
        'thread/unsubscribe',
        params: CodexJsonObject.from(<String, Object?>{'threadId': id}),
      );
    }
  }

  CodexSessionState _installSession({
    required CodexJsonObject response,
    required String cwd,
    required Iterable<String> additionalDirectories,
    required bool autoNameOnPrompt,
    SessionId? fallbackId,
  }) {
    final thread = response.requireObject('thread');
    final id = thread.optionalString('id') ?? fallbackId?.value;
    if (id == null || id.isEmpty) {
      throw const CodexProtocolException(
        'thread/start or thread/resume omitted the thread id.',
      );
    }
    final modelId =
        response.optionalString('model') ?? _defaultModel?.id ?? 'default';
    final model = _models.where((value) => value.id == modelId).firstOrNull;
    final state = CodexSessionState(
      sessionId: SessionId(id),
      cwd: response.optionalString('cwd') ?? cwd,
      additionalDirectories: additionalDirectories,
      agentMode: _agentModeFromResponse(response),
      collaborationMode: CodexCollaborationMode.standard,
      model: modelId,
      effort:
          CodexReasoningEffort.tryParse(
            response.optionalString('reasoningEffort'),
          ) ??
          model?.defaultReasoningEffort ??
          CodexReasoningEffort.medium,
      autoNameOnPrompt: autoNameOnPrompt,
      contextWindow: model?.contextWindow,
    );
    _sessions.add(state);
    _events[id] = CodexEventMapper(
      toolCalls: CodexToolCallMapper(terminalOutput: _terminalOutput),
    );
    _history[id] = CodexHistoryMapper(events: _events[id]);
    _steeringQueues[id] = CodexSteeringQueue<List<ContentBlock>>(
      (prompt) => _steer(state, prompt),
    );
    if (_client case final client?) {
      _approvals[id] = CodexApprovalBridge(client: client, session: state);
      _elicitations[id] = CodexElicitationBridge(
        client: client,
        session: state,
      );
    }
    _replayEarlyMcpServerStartup(state);
    return state;
  }

  CodexAgentMode _agentModeFromResponse(CodexJsonObject response) {
    final sandbox = response.optionalObject('sandbox');
    final type =
        sandbox?.optionalString('type') ?? response.optionalString('sandbox');
    return switch (type) {
      'readOnly' || 'read-only' => CodexAgentMode.readOnly,
      'dangerFullAccess' || 'danger-full-access' => CodexAgentMode.fullAccess,
      _ => CodexAgentMode.workspaceWrite,
    };
  }

  Map<String, Object?> _sessionConfig(Iterable<McpServer> mcpServers) {
    final config = <String, Object?>{...options.configuration.toJson()};
    _setWorkspaceWriteNetworkAccess(config);
    final mapped = _mcpMapper.map(
      mcpServers,
      startupTimeout: options.mcpServerStartupTimeout,
    );
    if (mapped.isNotEmpty) {
      config['mcp_servers'] = mapped;
    }
    if (_gateway case final gateway?) {
      const providerId = _customGatewayProviderId;
      config
        ..['model_provider'] = providerId
        ..['model_providers'] = <String, Object?>{
          providerId: <String, Object?>{
            'name': gateway.providerName,
            'base_url': gateway.baseUrl.toString(),
            'http_headers': gateway.headers,
            'wire_api': gateway.protocol.wireApi,
          },
        };
    }
    return config;
  }

  /// Gives the thread the same workspace-write network access that every
  /// `turn/start` sandbox policy sends.
  ///
  /// App-server applies each config key as its own override, and a
  /// `sandbox_workspace_write` table replaces the whole table. A dotted key
  /// beside that table can be lost, so when the base configuration has one,
  /// the value goes inside it.
  void _setWorkspaceWriteNetworkAccess(Map<String, Object?> config) {
    const table = 'sandbox_workspace_write';
    final networkAccess = options.workspaceWriteNetworkAccess;
    if (config[table] case final Map<String, Object?> existing) {
      config[table] = <String, Object?>{
        ...existing,
        'network_access': networkAccess,
      };
    } else {
      config['$table.network_access'] = networkAccess;
    }
  }

  String? get _gatewayProviderId =>
      _gateway == null ? null : _customGatewayProviderId;

  CodexModel? get _defaultModel =>
      _models.where((model) => model.isDefault).firstOrNull ??
      _models.firstOrNull;

  Future<ListSessionsResponse> _listSessions(
    AcpAgentRequestContext<ListSessionsRequest> context,
  ) async {
    await _ensureInitialized();
    final preferredProvider = options.modelProvider ?? _gatewayProviderId;
    final response = await _backend.request(
      'thread/list',
      params: CodexJsonObject.from(<String, Object?>{
        'cursor': context.params.cursor,
        'modelProviders': <Object?>[?preferredProvider],
        'sourceKinds': const <Object?>[
          'cli',
          'vscode',
          'exec',
          'appServer',
          'unknown',
        ],
        if (context.params.cwd != null) 'cwd': context.params.cwd,
      }),
    );
    final sessions = <SessionInfo>[];
    final data = response['data'];
    if (data is List<Object?>) {
      for (final raw in data) {
        if (raw is! Map<Object?, Object?>) {
          continue;
        }
        final thread = CodexJsonObject.from(raw);
        final id = thread.optionalString('id');
        final cwd = thread.optionalString('cwd');
        if (id == null || cwd == null) {
          continue;
        }
        final timestamp = thread.optionalNumber('updatedAt');
        sessions.add(
          SessionInfo(
            sessionId: SessionId(id),
            cwd: cwd,
            title:
                thread.optionalString('name') ??
                thread.optionalString('preview'),
            updatedAt: timestamp == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (timestamp * 1000).round(),
                    isUtc: true,
                  ).toIso8601String(),
          ),
        );
      }
    }
    return ListSessionsResponse(
      sessions: sessions,
      nextCursor: response.optionalString('nextCursor'),
    );
  }

  Future<DeleteSessionResponse> _deleteSession(
    AcpAgentRequestContext<DeleteSessionRequest> context,
  ) async {
    await _ensureInitialized();
    final state = _sessions[context.params.sessionId];
    if (state != null) {
      await _stopSessionTurn(state);
    }
    await _backend.request(
      'thread/archive',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': context.params.sessionId.value,
      }),
    );
    _removeSession(context.params.sessionId);
    return DeleteSessionResponse();
  }

  Future<CloseSessionResponse> _closeSession(
    AcpAgentRequestContext<CloseSessionRequest> context,
  ) async {
    await _ensureInitialized();
    final state = _sessions[context.params.sessionId];
    if (state != null) {
      await _stopSessionTurn(state);
    }
    await _backend.request(
      'thread/unsubscribe',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': context.params.sessionId.value,
      }),
    );
    _removeSession(context.params.sessionId);
    return CloseSessionResponse();
  }

  Future<void> _stopSessionTurn(CodexSessionState state) async {
    final turn = state.activeTurn;
    if (turn != null) {
      await _interrupt(state, turn);
      return;
    }
    final completion = state.turnCompletion;
    if (completion != null && !completion.isCompleted) {
      completion.complete(StopReason.cancelled);
      state.turnCompletion = null;
    }
  }

  void _removeSession(SessionId id) {
    _sessions.remove(id);
    _events.remove(id.value);
    _history.remove(id.value);
    _approvals.remove(id.value);
    _elicitations.remove(id.value);
    _steeringQueues.remove(id.value);
  }

  Future<SetSessionModeResponse> _setMode(
    AcpAgentRequestContext<SetSessionModeRequest> context,
  ) async {
    final state = _requireSession(context.params.sessionId);
    final mode = CodexCollaborationMode.tryParse(context.params.modeId.value);
    if (mode == null) {
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'modeId': context.params.modeId.value},
      );
    }
    await _backend.request(
      'thread/settings/update',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': state.sessionId.value,
        'collaborationMode': <String, Object?>{
          'mode': mode.id,
          'settings': <String, Object?>{'model': state.model},
        },
      }),
    );
    state.collaborationMode = mode;
    return SetSessionModeResponse();
  }

  Future<SetSessionConfigOptionResponse> _setConfigOption(
    AcpAgentRequestContext<SetSessionConfigOptionRequest> context,
  ) async {
    final request = context.params;
    final state = _requireSession(request.sessionId);
    final value = switch (request.variant) {
      SetSessionConfigOptionRequestValueId(:final value) => value.value,
      SetSessionConfigOptionRequestBoolean(:final value) => value,
    };
    switch (request.configId.value) {
      case 'agent-mode':
        if (value is! String || CodexAgentMode.tryParse(value) == null) {
          throw JsonRpcRequestException.invalidParams();
        }
        state.agentMode = CodexAgentMode.tryParse(value)!;
      case 'model':
        if (value is! String ||
            !_models.any((candidate) => candidate.id == value)) {
          throw JsonRpcRequestException.invalidParams();
        }
        state.model = value;
        state.contextWindow = _models
            .firstWhere((candidate) => candidate.id == value)
            .contextWindow;
      case 'reasoning-effort':
        if (value is! String || CodexReasoningEffort.tryParse(value) == null) {
          throw JsonRpcRequestException.invalidParams();
        }
        state.effort = CodexReasoningEffort.tryParse(value)!;
      case 'fast-mode':
        if (value is! bool) {
          throw JsonRpcRequestException.invalidParams();
        }
        state.fastMode = value;
      default:
        throw JsonRpcRequestException.invalidParams(
          data: <String, Object?>{'configId': request.configId.value},
        );
    }
    return SetSessionConfigOptionResponse(configOptions: _configOptions(state));
  }

  static bool _startsWithSlash(List<ContentBlock> prompt) {
    if (prompt.isEmpty) return false;
    final first = prompt.first;
    if (first is! ContentBlockText) return false;
    final text = first.toJson()['text'];
    return text is String && text.startsWith('/');
  }

  /// `/name args` → `\$name args` when `name` is a skill the app server
  /// reported. Anything else — unknown names, prompts that don't start with a
  /// slash, multi-block prompts whose first block isn't the command — passes
  /// through untouched.
  List<ContentBlock> _rewriteSkillInvocation(
    List<ContentBlock> prompt,
    CodexSessionState state,
  ) {
    if (prompt.isEmpty || state.skills.isEmpty) {
      return prompt;
    }
    final first = prompt.first;
    if (first is! ContentBlockText) {
      return prompt;
    }
    final text = first.toJson()['text'];
    if (text is! String || !text.startsWith('/')) {
      return prompt;
    }
    final space = text.indexOf(RegExp(r'\s'));
    final name = (space < 0 ? text.substring(1) : text.substring(1, space))
        .trim();
    if (name.isEmpty || !state.skills.any((skill) => skill.name == name)) {
      return prompt;
    }
    return <ContentBlock>[
      ContentBlockText(
        TextContent(text: r'$' + name + text.substring(1 + name.length)),
      ),
      ...prompt.skip(1),
    ];
  }

  Future<PromptResponse> _prompt(
    AcpAgentRequestContext<PromptRequest> context,
  ) async {
    final request = context.params;
    final state = _requireSession(request.sessionId);
    final command = await _commands.execute(request.prompt, state);
    if (command.handled) {
      for (final update in command.updates) {
        await context.client.updateSession(
          SessionNotification(sessionId: state.sessionId, update: update),
        );
      }
      return PromptResponse(stopReason: StopReason.endTurn);
    }
    // A client that lists skills as slash commands sends `/name …` — but the
    // invocation Codex resolves is the `\$name` mention (its /-form is a known
    // upstream gap, openai/codex#11817), so a leading slash naming a known
    // skill is rewritten before the turn starts.
    //
    // Clients cache the command list so their picker works before a session
    // exists, and start the session on the first prompt — so a cached skill
    // can arrive while the session-start discovery is still in flight, when
    // [CodexSessionState.skills] is empty and the rewrite would silently pass
    // the slash form through. A slash prompt waits (bounded) for discovery;
    // everything else pays nothing.
    if (state.skills.isEmpty && _startsWithSlash(request.prompt)) {
      try {
        await state.skillsDiscovery?.timeout(const Duration(seconds: 10));
      } on Object {
        // Discovery failing or dragging must not block the prompt.
      }
    }
    final prompt = _rewriteSkillInvocation(request.prompt, state);
    // A dead MCP server is revived BEFORE the turn, so the first tool call
    // after a transport death succeeds instead of failing once as a
    // detection signal. The in-turn heal below stays as the backstop for a
    // server that dies mid-turn.
    await _reviveFailedMcpServers(state);
    final titleMetadata = request.meta;
    await _maybeSetInitialThreadName(
      state,
      prompt,
      titleHintProvided:
          titleMetadata?.containsKey(codexThreadTitlePromptMetaKey) ?? false,
      titleHint: titleMetadata?[codexThreadTitlePromptMetaKey]?.toObject(),
    );
    if (state.activeTurn case final activeTurn?) {
      // A steered prompt needs the same closure translation as a started one:
      // the panel deliberately lets a follow-up join a running turn, so this
      // is a normal path, and an app server dying while `turn/steer` is
      // pending would otherwise surface a bare transport error.
      try {
        await _backend.request(
          'turn/steer',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'expectedTurnId': activeTurn.value,
            'input': _promptMapper.map(prompt),
          }),
        );
      } on Object {
        if (_deathIfBackendGone() case final death?) {
          throw death;
        }
        rethrow;
      }
      final completion = state.turnCompletion;
      return PromptResponse(
        stopReason: completion == null
            ? StopReason.endTurn
            : await completion.future,
      );
    }
    final completer = state.beginTurn();
    final generation = state.generation;
    try {
      final response = await _backend.request(
        'turn/start',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': state.sessionId.value,
          'input': _promptMapper.map(prompt),
          'cwd': state.cwd,
          'approvalPolicy': state.agentMode.approvalPolicy,
          'approvalsReviewer': options
              .resolveApprovalsReviewer(
                agentMode: state.agentMode,
                collaborationMode: state.collaborationMode,
              )
              .appServerValue,
          'sandboxPolicy': _sandboxPolicy(state),
          'model': state.model,
          'serviceTier': state.fastMode ? 'fast' : null,
          'effort': state.effort == CodexReasoningEffort.none
              ? null
              : state.effort.id,
          'summary': state.effort == CodexReasoningEffort.none
              ? 'none'
              : 'auto',
        }),
      );
      final turn = response.requireObject('turn');
      final id = turn.requireString('id');
      final turnId = CodexTurnId(id);
      if (state.isClosed || state.generation != generation) {
        await _backend.request(
          'turn/interrupt',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'turnId': id,
          }),
        );
        _backend.markTurnStale(CodexThreadId(state.sessionId.value), turnId);
        if (!completer.isCompleted) {
          completer.complete(StopReason.cancelled);
        }
        return PromptResponse(stopReason: await completer.future);
      }
      if (completer.isCompleted) {
        _backend.markTurnStale(CodexThreadId(state.sessionId.value), turnId);
        return PromptResponse(stopReason: await completer.future);
      }
      state.activeTurn = turnId;
      return PromptResponse(stopReason: await completer.future);
    } on Object {
      state
        ..activeTurn = null
        ..turnCompletion = null;
      if (_deathIfBackendGone() case final death?) {
        throw death;
      }
      rethrow;
    }
  }

  /// The session's death when the app server is gone, else null.
  ///
  /// An app server that dies while a request is in flight fails it with a
  /// transport error that says nothing about the session. Answering with the
  /// death instead is what makes the client replace the session rather than
  /// send the next prompt to a process that is gone.
  ///
  /// [_backendGone] alone is too late: the connection rejects the pending
  /// request BEFORE the streams whose `onDone` sets that flag are closed, so
  /// the FIRST prompt after a crash would fail as an opaque "JSON-RPC
  /// connection closed" and only the SECOND would carry the marker — costing
  /// the user a message. The backend's own closed state flips before that
  /// rejection, so it is asked directly.
  JsonRpcRequestException? _deathIfBackendGone() {
    if (!_backendGone && !_backend.isClosed) {
      return null;
    }
    _handleBackendClosed();
    return _deadBackendError('The Codex app server exited mid-turn.');
  }

  Future<void> _maybeSetInitialThreadName(
    CodexSessionState state,
    Iterable<ContentBlock> prompt, {
    required bool titleHintProvided,
    Object? titleHint,
  }) async {
    if (!state.autoNameOnPrompt) {
      return;
    }
    final title = titleHintProvided
        ? CodexThreadTitle.fromText(titleHint)
        : CodexThreadTitle.fromPrompt(prompt);
    if (title == null) {
      return;
    }
    state.autoNameOnPrompt = false;
    try {
      await _backend.request(
        'thread/name/set',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': state.sessionId.value,
          'name': title,
        }),
      );
    } on Object {
      options.onDiagnostic?.call(
        const CodexDiagnostic(
          level: CodexDiagnosticLevel.warning,
          category: CodexDiagnosticCategory.protocol,
          message: 'The Codex app server could not name the new thread.',
        ),
      );
    }
  }

  Map<String, Object?> _sandboxPolicy(CodexSessionState state) {
    return switch (state.agentMode) {
      CodexAgentMode.fullAccess => <String, Object?>{
        'type': 'dangerFullAccess',
      },
      CodexAgentMode.readOnly => <String, Object?>{
        'type': 'readOnly',
        'networkAccess': false,
      },
      CodexAgentMode.workspaceWrite => <String, Object?>{
        'type': 'workspaceWrite',
        'writableRoots': state.additionalDirectories,
        'networkAccess': options.workspaceWriteNetworkAccess,
        'excludeTmpdirEnvVar': false,
        'excludeSlashTmp': false,
      },
    };
  }

  Future<void> _cancel(
    AcpAgentNotificationContext<CancelNotification> context,
  ) async {
    final state = _sessions[context.params.sessionId];
    final turn = state?.activeTurn;
    if (state == null || turn == null) {
      return;
    }
    await _interrupt(state, turn);
  }

  Future<CodexSteeringResponse> _steerExtension(
    AcpAgentRequestContext<CodexSteeringRequest> context,
  ) async {
    final request = context.params;
    final state = _requireSession(request.sessionId);
    final queue = _steeringQueues[state.sessionId.value];
    if (queue == null) {
      return CodexSteeringResponse.failed;
    }
    final outcome = await queue.enqueue(request.prompt);
    return switch (outcome) {
      CodexSteeringInjected() => CodexSteeringResponse.injected,
      CodexSteeringStartedNewTurn() => CodexSteeringResponse.startedNewTurn,
      CodexSteeringFailed() => CodexSteeringResponse.failed,
    };
  }

  Future<CodexSteeringOutcome> _steer(
    CodexSessionState state,
    List<ContentBlock> prompt,
  ) async {
    try {
      if (state.activeTurn case final turn?) {
        await _backend.request(
          'turn/steer',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'expectedTurnId': turn.value,
            'input': _promptMapper.map(prompt),
          }),
        );
        return const CodexSteeringInjected();
      }
      final response = await _backend.request(
        'turn/start',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': state.sessionId.value,
          'input': _promptMapper.map(prompt),
          'cwd': state.cwd,
          'approvalPolicy': state.agentMode.approvalPolicy,
          'approvalsReviewer': options
              .resolveApprovalsReviewer(
                agentMode: state.agentMode,
                collaborationMode: state.collaborationMode,
              )
              .appServerValue,
          'sandboxPolicy': _sandboxPolicy(state),
          'model': state.model,
          'serviceTier': state.fastMode ? 'fast' : null,
          'effort': state.effort == CodexReasoningEffort.none
              ? null
              : state.effort.id,
          'summary': state.effort == CodexReasoningEffort.none
              ? 'none'
              : 'auto',
        }),
      );
      state.activeTurn = CodexTurnId(
        response.requireObject('turn').requireString('id'),
      );
      state.beginTurn();
      return const CodexSteeringStartedNewTurn();
    } on Object {
      return const CodexSteeringFailed();
    }
  }

  Future<AcpNoResult> _goalControlExtension(
    AcpAgentRequestContext<AcpGoalControlRequest> context,
  ) async {
    final request = context.params;
    final state = _requireSession(request.sessionId);
    switch (request.action) {
      case AcpGoalControlAction.update:
        final objective = request.objective?.trim();
        if (objective == null || objective.isEmpty) {
          throw JsonRpcRequestException.invalidParams(
            data: <String, Object?>{
              'message': 'Updating a goal requires a non-empty objective.',
            },
          );
        }
        await _backend.request(
          'thread/goal/set',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'objective': objective,
          }),
        );
        state
          ..goalObjective = objective
          ..goalStatus = 'active';
      case AcpGoalControlAction.pause:
        await _backend.request(
          'thread/goal/set',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'status': 'paused',
          }),
        );
        state.goalStatus = 'paused';
      case AcpGoalControlAction.resume:
        await _backend.request(
          'thread/goal/set',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'status': 'active',
          }),
        );
        state.goalStatus = 'active';
      case AcpGoalControlAction.clear:
        await _backend.request(
          'thread/goal/clear',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
          }),
        );
        state
          ..goalObjective = null
          ..goalStatus = null;
    }
    await _sendGoalUpdate(context.client, state);
    return const AcpNoResult();
  }

  Future<void> _refreshGoal(CodexSessionState state) async {
    try {
      final response = await _backend.request(
        'thread/goal/get',
        params: CodexJsonObject.from(<String, Object?>{
          'threadId': state.sessionId.value,
        }),
      );
      final goal = response.optionalObject('goal');
      state
        ..goalObjective = goal?.optionalString('objective')
        ..goalStatus = goal?.optionalString('status');
    } on Object {
      // Goal support is an app-server extension. Older servers can still run
      // normal ACP sessions; they simply begin without an observable goal.
    }
  }

  Future<void> _interrupt(CodexSessionState state, CodexTurnId turn) async {
    await _backend.request(
      'turn/interrupt',
      params: CodexJsonObject.from(<String, Object?>{
        'threadId': state.sessionId.value,
        'turnId': turn.value,
      }),
    );
    _backend.markTurnStale(CodexThreadId(state.sessionId.value), turn);
    _completeTurn(state, StopReason.cancelled, turn);
  }

  /// When the last MCP server reload was requested, so a burst of failing
  /// calls (the model retrying, several tools on the same dead server) asks
  /// for one restart rather than one per failure.
  DateTime? _lastMcpReloadAt;

  /// Minimum spacing between reload requests, shared by the pre-turn revive
  /// and the failure-time heal so they never restart servers mid-handshake
  /// on top of each other.
  static const Duration _mcpReloadCooldown = Duration(seconds: 20);

  /// Until when pre-turn revival is suppressed because the last attempt left
  /// servers failed anyway. A server that stays failed after a reload (a
  /// missing executable, bad credentials, a crash loop) is not going to be
  /// fixed by reloading harder — without this, every prompt would pay the
  /// full reload-and-wait window for the rest of the session.
  DateTime? _reviveSuppressedUntil;

  /// Suppression grows on each consecutive unsuccessful revive and resets the
  /// moment the fleet reports healthy.
  Duration _reviveSuppression = _initialReviveSuppression;
  static const Duration _initialReviveSuppression = Duration(minutes: 1);
  static const Duration _maxReviveSuppression = Duration(minutes: 10);

  /// Revives dead MCP servers before a turn starts. Codex tracks a server's
  /// pipe health — `runtimeStatus` flips to `failed` within seconds of the
  /// process dying (probed on 0.150) — but never restarts one on its own, so
  /// without this the first tool call of the turn fails just to reveal the
  /// death. Bounded and best-effort throughout: a turn must never be blocked
  /// on health machinery, so any error or timeout just lets the turn run
  /// (where the failure-time heal still applies).
  Future<void> _reviveFailedMcpServers(CodexSessionState state) async {
    try {
      if (_reviveSuppressedUntil case final until?
          when DateTime.now().isBefore(until)) {
        // The last attempt already reloaded and waited, and the server stayed
        // failed. Let the turn run immediately; the failure-time heal still
        // covers any server that can actually be revived.
        return;
      }
      final hadFailed = await _anyMcpServerFailed(state);
      if (!hadFailed) {
        _reviveSuppressedUntil = null;
        _reviveSuppression = _initialReviveSuppression;
        return;
      }
      // The failure-time heal may have requested a reload moments ago (its
      // burst cooldown below) — then the respawn is already in flight, and a
      // second reload would only restart servers mid-handshake. Skip straight
      // to waiting for it.
      final now = DateTime.now();
      final lastReload = _lastMcpReloadAt;
      final reloadInFlight =
          lastReload != null && now.difference(lastReload) < _mcpReloadCooldown;
      if (!reloadInFlight) {
        _lastMcpReloadAt = now;
        await _backend
            .request('config/mcpServer/reload')
            .timeout(const Duration(seconds: 5));
      }
      // Give the respawn time to connect, so the turn's first call finds it
      // up rather than racing the handshake. Bounded (~9s at the defaults)
      // but exits the moment the fleet reports healthy — a real server (the
      // FlutterFlow one initializes an SDK on boot) can need several seconds,
      // and a first call that works is worth a short wait on a turn that
      // would otherwise open with failures.
      for (
        var attempt = 0;
        attempt < options.mcpRevivePollAttempts;
        attempt++
      ) {
        await Future<void>.delayed(options.mcpRevivePollInterval);
        if (!await _anyMcpServerFailed(state)) {
          _reviveSuppressedUntil = null;
          _reviveSuppression = _initialReviveSuppression;
          return;
        }
      }
      // Reloading did not help, so it will not help next turn either.
      // Suppress with growing spacing; a later successful check resets it.
      _reviveSuppressedUntil = DateTime.now().add(_reviveSuppression);
      final doubled = _reviveSuppression * 2;
      _reviveSuppression = doubled > _maxReviveSuppression
          ? _maxReviveSuppression
          : doubled;
    } on Object {
      // Run the turn regardless.
    }
  }

  Future<bool> _anyMcpServerFailed(CodexSessionState state) async {
    final response = await _backend
        .request(
          'mcpServerStatus/list',
          params: CodexJsonObject.from(<String, Object?>{
            'threadId': state.sessionId.value,
            'cwds': <Object?>[state.cwd, ...state.additionalDirectories],
          }),
        )
        .timeout(const Duration(seconds: 3));
    final data = response['data'] ?? response['servers'];
    if (data is! List<Object?>) {
      return false;
    }
    for (final raw in data) {
      if (raw is Map<Object?, Object?> && raw['runtimeStatus'] == 'failed') {
        return true;
      }
    }
    return false;
  }

  /// Restarts the app server's MCP servers when a tool call dies on a closed
  /// transport, so the very next attempt reconnects instead of every later
  /// call failing instantly for the rest of the session.
  ///
  /// Codex does not do this itself — killed a server mid-session on codex
  /// 0.150 and every subsequent call failed with "Transport closed" until
  /// `config/mcpServer/reload` (parameterless, global) was requested, after
  /// which the same tool answered from a freshly spawned process. The reload
  /// covers session-provided servers, not just config.toml ones: the respawn
  /// was observed with a server passed in the thread's own config.
  void _healClosedMcpTransport(CodexNotification notification) {
    if (notification.method != 'item/completed') {
      return;
    }
    final item = notification.params.optionalObject('item');
    if (item == null ||
        item.optionalString('type') != 'mcpToolCall' ||
        item.optionalString('status') != 'failed') {
      return;
    }
    final error = item['error'];
    final message = error is Map<Object?, Object?>
        ? error['message']?.toString()
        : error?.toString();
    if (message == null ||
        !message.toLowerCase().contains('transport closed')) {
      return;
    }
    final now = DateTime.now();
    if (_lastMcpReloadAt case final last?
        when now.difference(last) < _mcpReloadCooldown) {
      return;
    }
    _lastMcpReloadAt = now;
    unawaited(
      _backend
          .request('config/mcpServer/reload')
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// Startup statuses for threads with no installed session yet, oldest
  /// first. Codex starts a thread's MCP servers while it handles
  /// `thread/start` (and `thread/resume`), so a fast failure such as a
  /// command that cannot spawn can arrive before the response that installs
  /// the session. Bounded: statuses for threads that never install here (a
  /// subagent's, another client's) are evicted oldest first.
  final ListQueue<CodexMcpServerStartupStatus> _earlyMcpServerStartup =
      ListQueue<CodexMcpServerStartupStatus>();
  static const int _maximumEarlyMcpServerStartup = 64;

  /// Counts startup notices so each one gets its own message id.
  int _mcpServerStartupNotices = 0;

  /// Handles `mcpServer/startupStatus/updated`: the host hears every status;
  /// the owning session records it for `/mcp` and, when startup failed, shows
  /// Codex's error as a notice. Nothing else in the adapter surfaces a
  /// startup failure: Codex reports it only through this notification, and
  /// otherwise the session just has no tools from that server.
  void _handleMcpServerStartup(CodexNotification notification) {
    final status = CodexMcpServerStartupStatus.fromParams(notification.params);
    if (status == null) {
      return;
    }
    if (options.onMcpServerStartupStatus case final callback?) {
      try {
        callback(status);
      } on Object {
        // A host callback failure must not break the notification stream.
      }
    }
    final threadId = status.threadId;
    if (threadId == null) {
      return;
    }
    final state = _sessions.byThread(CodexThreadId(threadId));
    if (state == null) {
      _earlyMcpServerStartup.addLast(status);
      while (_earlyMcpServerStartup.length > _maximumEarlyMcpServerStartup) {
        _earlyMcpServerStartup.removeFirst();
      }
      return;
    }
    if (!state.isClosed) {
      _applyMcpServerStartup(state, status);
    }
  }

  void _replayEarlyMcpServerStartup(CodexSessionState state) {
    if (_earlyMcpServerStartup.isEmpty) {
      return;
    }
    final id = state.sessionId.value;
    final early = _earlyMcpServerStartup
        .where((status) => status.threadId == id)
        .toList();
    _earlyMcpServerStartup.removeWhere((status) => status.threadId == id);
    for (final status in early) {
      _applyMcpServerStartup(state, status);
    }
  }

  void _applyMcpServerStartup(
    CodexSessionState state,
    CodexMcpServerStartupStatus status,
  ) {
    state.mcpServerStartup[status.name] = status;
    final client = _client;
    if (status.state != CodexMcpServerStartupState.failed || client == null) {
      return;
    }
    final update = CodexEventMapper.mcpServerStartupNotice(
      status,
      messageId: 'mcp-startup-${++_mcpServerStartupNotices}',
    );
    final generation = state.generation;
    state.enqueueNotification(() async {
      if (!state.isClosed && state.generation == generation) {
        await client.updateSession(
          SessionNotification(sessionId: state.sessionId, update: update),
        );
      }
    });
  }

  void _handleNotification(CodexNotification notification) {
    if (notification.method == codexMcpServerStartupStatusMethod) {
      _handleMcpServerStartup(notification);
      return;
    }
    final threadId = notification.threadId;
    if (threadId == null &&
        notification.method == 'account/rateLimits/updated') {
      for (final state in _sessions.values) {
        state.rateLimits = notification.params;
      }
      return;
    }
    if (threadId == null) {
      return;
    }
    final state = _sessions.byThread(threadId);
    if (state == null || state.isClosed) {
      return;
    }
    if (notification.method == 'turn/started') {
      final turn = notification.params.optionalObject('turn');
      final id = turn?.optionalString('id') ?? notification.turnId?.value;
      if (id != null) {
        state.activeTurn = CodexTurnId(id);
      }
    }
    _healClosedMcpTransport(notification);
    if (notification.method == 'turn/completed') {
      final turn = notification.params.optionalObject('turn');
      final id = turn?.optionalString('id') ?? notification.turnId?.value;
      final status = turn?.optionalString('status');
      if (id != null) {
        _completeTurn(
          state,
          status == 'interrupted'
              ? StopReason.cancelled
              : status == 'failed'
              ? StopReason.refusal
              : StopReason.endTurn,
          CodexTurnId(id),
        );
      }
    }
    if (notification.method == 'thread/tokenUsage/updated') {
      final usage =
          notification.params.optionalObject('tokenUsage') ??
          notification.params.optionalObject('usage') ??
          notification.params;
      state.usedTokens =
          usage.optionalInt('totalTokens') ??
          usage.optionalInt('total_tokens') ??
          usage.optionalInt('inputTokens');
      state.contextWindow =
          usage.optionalInt('modelContextWindow') ??
          usage.optionalInt('contextWindow') ??
          usage.optionalInt('context_window') ??
          state.contextWindow;
    }
    if (notification.method == 'thread/goal/updated') {
      final goal = notification.params.optionalObject('goal');
      state
        ..goalObjective = goal?.optionalString('objective')
        ..goalStatus = goal?.optionalString('status');
    }
    if (notification.method == 'thread/goal/cleared') {
      state
        ..goalObjective = null
        ..goalStatus = null;
    }
    if (notification.method == 'thread/goal/updated' ||
        notification.method == 'thread/goal/cleared') {
      final client = _client;
      if (client != null) {
        final generation = state.generation;
        state.enqueueNotification(() async {
          if (!state.isClosed && state.generation == generation) {
            await _sendGoalUpdate(client, state);
          }
        });
      }
    }
    if (_elicitations[state.sessionId.value] case final bridge?) {
      unawaited(bridge.observe(notification));
    }
    final mapper = _events[state.sessionId.value];
    final client = _client;
    if (mapper == null || client == null) {
      return;
    }
    for (final update in mapper.map(notification)) {
      final generation = state.generation;
      state.enqueueNotification(() async {
        if (!state.isClosed && state.generation == generation) {
          await client.updateSession(
            SessionNotification(sessionId: state.sessionId, update: update),
          );
        }
      });
    }
  }

  void _completeTurn(
    CodexSessionState state,
    StopReason reason,
    CodexTurnId turn,
  ) {
    if (state.activeTurn != null && state.activeTurn!.value != turn.value) {
      return;
    }
    final completer = state.turnCompletion;
    state
      ..activeTurn = null
      ..turnCompletion = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(reason);
    }
    _backend.markTurnStale(CodexThreadId(state.sessionId.value), turn);
  }

  Future<CodexNotification> _nextNotification(String method) {
    return _backend.notifications.firstWhere(
      (notification) => notification.method == method,
    );
  }

  void _handleServerRequest(CodexPendingServerRequest pending) {
    unawaited(_respondToServerRequest(pending));
  }

  Future<void> _respondToServerRequest(
    CodexPendingServerRequest pending,
  ) async {
    final request = pending.request;
    final state = _sessions.byThread(request.threadId);
    if (state == null || state.isClosed) {
      await pending.respond(_safeServerRequestDefault(request));
      return;
    }
    final result = switch (request) {
      CodexCommandApprovalRequest() ||
      CodexFileChangeApprovalRequest() ||
      CodexPermissionsRequest() =>
        await (_approvals[state.sessionId.value]?.handle(request) ??
            Future<CodexJsonObject>.value(_safeServerRequestDefault(request))),
      CodexMcpElicitationRequest() || CodexUserInputRequest() =>
        await (_elicitations[state.sessionId.value]?.handle(request) ??
            Future<CodexJsonObject>.value(_safeServerRequestDefault(request))),
    };
    await pending.respond(result);
  }

  CodexJsonObject _safeServerRequestDefault(CodexServerRequest request) {
    return switch (request) {
      CodexCommandApprovalRequest() || CodexFileChangeApprovalRequest() =>
        CodexJsonObject.from(<String, Object?>{'decision': 'cancel'}),
      CodexPermissionsRequest() => CodexJsonObject.from(<String, Object?>{
        'permissions': <String, Object?>{},
        'scope': 'turn',
        'strictAutoReview': true,
      }),
      CodexMcpElicitationRequest() => CodexJsonObject.from(<String, Object?>{
        'action': 'cancel',
        'content': null,
        '_meta': null,
      }),
      CodexUserInputRequest() => CodexJsonObject.from(<String, Object?>{
        'answers': <String, Object?>{},
      }),
    };
  }

  void _handleBackendError(Object error, StackTrace stackTrace) {
    options.onDiagnostic?.call(
      const CodexDiagnostic(
        level: CodexDiagnosticLevel.error,
        category: CodexDiagnosticCategory.protocol,
        message: 'The Codex app-server stream reported an error.',
      ),
    );
    for (final state in _sessions.values) {
      final completer = state.turnCompletion;
      if (completer != null && !completer.isCompleted) {
        // The raw error reaches the client as a bare "Internal error" — it is
        // not a JsonRpcRequestException, so the mapper drops it. Name the
        // cause. The stream itself is broadcast and stays open, so this does
        // NOT claim the session is dead; only [_handleBackendClosed] does.
        completer.completeError(
          JsonRpcRequestException.internalError(
            data: <String, Object?>{
              'message': 'The Codex app-server stream failed: $error',
            },
          ),
          stackTrace,
        );
      }
    }
  }

  /// The app-server streams ended: its process exited, or the transport under
  /// it died. Sessions are retired HERE, not just their in-flight turns — a
  /// session left open over a dead app server accepts later prompts and drops
  /// them, with nothing telling the client its backend no longer exists.
  /// `sessionDead` in the error data is what lets a client retire its handle
  /// and start a replacement on the same conversation.
  void _handleBackendClosed() {
    if (_backendGone) {
      return;
    }
    _backendGone = true;
    options.onDiagnostic?.call(
      const CodexDiagnostic(
        level: CodexDiagnosticLevel.error,
        category: CodexDiagnosticCategory.protocol,
        message: 'The Codex app-server connection closed.',
      ),
    );
    for (final state in _sessions.values) {
      final completer = state.turnCompletion;
      state
        ..isClosed = true
        ..generation += 1
        ..activeTurn = null
        ..turnCompletion = null;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
          _deadBackendError('The Codex app server exited mid-turn.'),
        );
      }
    }
  }

  JsonRpcRequestException _deadBackendError(String reason) =>
      JsonRpcRequestException.internalError(
        data: <String, Object?>{
          'message': '$reason Start a new session.',
          'sessionDead': true,
        },
      );

  CodexSessionState _requireSession(SessionId id) {
    final state = _sessions[id];
    if (state == null || state.isClosed) {
      // A dead app server makes every session unusable, not merely unknown.
      // Answering "invalid params" reads as a client bug and offers nothing to
      // recover from; `sessionDead` tells the client to replace the session.
      // The backend is asked as well as the flag: a prompt can arrive after
      // the connection closed but before the streams' `onDone` has run.
      if (_backendGone || _backend.isClosed) {
        throw _deadBackendError(
          'The Codex app server behind this session has exited.',
        );
      }
      throw JsonRpcRequestException.invalidParams(
        data: <String, Object?>{'sessionId': id.value},
      );
    }
    return state;
  }

  CodexHistoryMapper _historyFor(CodexSessionState state) =>
      _history[state.sessionId.value] ??= CodexHistoryMapper();

  void _scheduleInitialUpdates(
    AcpAgentContext client,
    CodexSessionState state,
  ) {
    final generation = state.generation;
    final discovery = Future<void>(() async {
      await client.lifecycle.ready;
      if (state.isClosed ||
          state.generation != generation ||
          !client.lifecycle.isReady) {
        return;
      }
      try {
        // Skills are commands too: the CLI's own composer lists installed
        // skills next to the built-ins, and a client fed only the built-ins
        // shows a picker with the user's skills missing. A failed lookup
        // falls back to the built-ins alone.
        final skills = await _commands.listSkills(<String>[
          state.cwd,
          ...state.additionalDirectories,
        ]);
        if (state.isClosed || state.generation != generation) {
          return;
        }
        state.skills = skills;
        await client.updateSession(
          SessionNotification(
            sessionId: state.sessionId,
            update: _commands.availableCommands(skills: skills),
          ),
        );
        await _sendGoalUpdate(client, state);
      } on AcpConnectionStateException {
        // The connection can close between the readiness check and send.
      }
    });
    state.skillsDiscovery = discovery;
    unawaited(discovery);
  }

  Future<void> _sendGoalUpdate(
    AcpAgentContext client,
    CodexSessionState state,
  ) => client.updateSession(
    SessionNotification(
      sessionId: state.sessionId,
      update: SessionUpdate.fromJson(<String, Object?>{
        'sessionUpdate': 'session_info_update',
        '_meta': <String, Object?>{
          'goal': switch (state.goalObjective) {
            final objective? => AcpGoalSnapshot(
              objective: objective,
              status: switch (state.goalStatus) {
                'paused' => AcpGoalStatus.paused,
                'completed' || 'complete' => AcpGoalStatus.completed,
                'cancelled' || 'canceled' => AcpGoalStatus.cancelled,
                _ => AcpGoalStatus.active,
              },
            ).toJson(),
            null => null,
          },
        },
      }),
    ),
  );

  SessionModeState _modeState(CodexSessionState state) {
    return SessionModeState(
      currentModeId: SessionModeId(state.collaborationMode.id),
      availableModes: <SessionMode>[
        for (final mode in CodexCollaborationMode.values)
          SessionMode(
            id: SessionModeId(mode.id),
            name: mode.label,
            description: mode == CodexCollaborationMode.plan
                ? 'Plan before making changes.'
                : 'Collaborate and act directly.',
          ),
      ],
    );
  }

  List<SessionConfigOption> _configOptions(CodexSessionState state) {
    final selectedModel = _models
        .where((candidate) => candidate.id == state.model)
        .firstOrNull;
    final efforts = selectedModel?.reasoningEfforts.isNotEmpty ?? false
        ? selectedModel!.reasoningEfforts
        : CodexReasoningEffort.values;
    return <SessionConfigOption>[
      _selectOption(
        id: 'agent-mode',
        name: 'Agent mode',
        category: 'mode',
        current: state.agentMode.id,
        options: <(String, String, String?)>[
          for (final mode in CodexAgentMode.values)
            (mode.id, mode.label, mode.description),
        ],
      ),
      if (_models.isNotEmpty)
        _selectOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          current: state.model,
          options: <(String, String, String?)>[
            for (final model in _models)
              (model.id, model.name, model.description),
          ],
          optionMeta: <String, AcpJsonObject>{
            for (final model in _models)
              model.id: acpModelOptionMeta(
                inputModalities: <AcpModelInputModality>[
                  for (final modality in model.inputModalities)
                    switch (modality) {
                      CodexInputModality.text => AcpModelInputModality.text,
                      CodexInputModality.image => AcpModelInputModality.image,
                    },
                ],
              ),
          },
        ),
      _selectOption(
        id: 'reasoning-effort',
        name: 'Reasoning effort',
        category: 'thought_level',
        current: state.effort.id,
        options: <(String, String, String?)>[
          for (final effort in efforts)
            (effort.id, _titleCase(effort.id), null),
        ],
      ),
      if (selectedModel?.supportsFast ?? false)
        SessionConfigOption.fromJson(<String, Object?>{
          'type': 'boolean',
          'id': 'fast-mode',
          'name': 'Fast mode',
          'description': 'Use the faster service tier.',
          'category': 'model_config',
          'currentValue': state.fastMode,
        }),
    ];
  }

  SessionConfigOption _selectOption({
    required String id,
    required String name,
    required String category,
    required String current,
    required List<(String, String, String?)> options,
    Map<String, AcpJsonObject> optionMeta = const <String, AcpJsonObject>{},
  }) {
    return SessionConfigOption.fromJson(<String, Object?>{
      'type': 'select',
      'id': id,
      'name': name,
      'category': category,
      'currentValue': current,
      'options': <Object?>[
        for (final option in options)
          <String, Object?>{
            'value': option.$1,
            'name': option.$2,
            if (option.$3 != null && option.$3!.isNotEmpty)
              'description': option.$3,
            '_meta': ?optionMeta[option.$1]?.toObject(),
          },
      ],
    });
  }

  String _titleCase(String value) => value
      .split(RegExp('[-_]'))
      .map(
        (part) => part.isEmpty
            ? part
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}
