import 'acp_json.dart';

/// Information identifying an ACP implementation.
final class AcpImplementation implements AcpExtensible {
  /// Creates implementation information.
  const AcpImplementation({
    required this.name,
    this.title,
    this.version,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses implementation information.
  factory AcpImplementation.fromJson(AcpJsonMap json) => AcpImplementation(
    name: AcpJson.string(json, 'name') ?? '',
    title: AcpJson.string(json, 'title'),
    version: AcpJson.string(json, 'version'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['name', 'title', 'version']),
  );

  /// Programmatic implementation name.
  final String name;

  /// Human-readable implementation title.
  final String? title;

  /// Implementation version.
  final String? version;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  /// Encodes this implementation.
  AcpJsonMap toJson() => <String, Object?>{
    'name': name,
    if (title != null) 'title': title,
    if (version != null) 'version': version,
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// File-system methods offered by an ACP client.
final class AcpFileSystemCapabilities implements AcpExtensible {
  /// Creates file-system capabilities.
  const AcpFileSystemCapabilities({
    this.readTextFile = false,
    this.writeTextFile = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Whether `fs/read_text_file` is supported.
  final bool readTextFile;

  /// Whether `fs/write_text_file` is supported.
  final bool writeTextFile;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  /// Encodes these capabilities.
  AcpJsonMap toJson() => <String, Object?>{
    'readTextFile': readTextFile,
    'writeTextFile': writeTextFile,
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Capabilities advertised by the ACP client.
final class AcpClientCapabilities implements AcpExtensible {
  /// Creates client capabilities.
  const AcpClientCapabilities({
    this.fileSystem,
    this.terminal = false,
    this.booleanConfigOptions = true,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Optional file-system capabilities.
  final AcpFileSystemCapabilities? fileSystem;

  /// Whether terminal methods are supported.
  final bool terminal;

  /// Whether boolean session configuration options are supported.
  final bool booleanConfigOptions;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  /// Encodes these capabilities.
  AcpJsonMap toJson() => <String, Object?>{
    if (fileSystem != null) 'fs': fileSystem!.toJson(),
    'terminal': terminal,
    if (booleanConfigOptions)
      'session': <String, Object?>{
        'configOptions': <String, Object?>{
          'boolean': const <String, Object?>{},
        },
      },
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Prompt content capabilities advertised by an ACP agent.
final class AcpPromptCapabilities implements AcpExtensible {
  /// Creates prompt capabilities.
  const AcpPromptCapabilities({
    this.image = false,
    this.audio = false,
    this.embeddedContext = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses prompt capabilities.
  factory AcpPromptCapabilities.fromJson(AcpJsonMap json) =>
      AcpPromptCapabilities(
        image: AcpJson.boolean(json, 'image') ?? false,
        audio: AcpJson.boolean(json, 'audio') ?? false,
        embeddedContext: AcpJson.boolean(json, 'embeddedContext') ?? false,
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'image',
          'audio',
          'embeddedContext',
        ]),
      );

  /// Whether image prompts are supported.
  final bool image;

  /// Whether audio prompts are supported.
  final bool audio;

  /// Whether embedded resource prompts are supported.
  final bool embeddedContext;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Optional session lifecycle operations advertised by an ACP agent.
final class AcpSessionCapabilities implements AcpExtensible {
  /// Creates session capabilities.
  const AcpSessionCapabilities({
    this.list = false,
    this.delete = false,
    this.additionalDirectories = false,
    this.fork = false,
    this.resume = false,
    this.close = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses session capabilities using capability-object presence semantics.
  factory AcpSessionCapabilities.fromJson(AcpJsonMap json) =>
      AcpSessionCapabilities(
        list: _supportsCapability(json, 'list'),
        delete: _supportsCapability(json, 'delete'),
        additionalDirectories: _supportsCapability(
          json,
          'additionalDirectories',
        ),
        fork: _supportsCapability(json, 'fork'),
        resume: _supportsCapability(json, 'resume'),
        close: _supportsCapability(json, 'close'),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'list',
          'delete',
          'additionalDirectories',
          'fork',
          'resume',
          'close',
        ]),
      );

  /// Whether `session/list` is supported.
  final bool list;

  /// Whether `session/delete` is supported.
  final bool delete;

  /// Whether additional workspace directories are supported.
  final bool additionalDirectories;

  /// Whether the unstable `session/fork` operation is supported.
  final bool fork;

  /// Whether `session/resume` is supported.
  final bool resume;

  /// Whether `session/close` is supported.
  final bool close;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// MCP transport capabilities advertised by an ACP agent.
final class AcpMcpCapabilities implements AcpExtensible {
  /// Creates MCP transport capabilities.
  const AcpMcpCapabilities({
    this.http = false,
    this.sse = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses MCP transport capabilities.
  factory AcpMcpCapabilities.fromJson(AcpJsonMap json) => AcpMcpCapabilities(
    http: AcpJson.boolean(json, 'http') ?? false,
    sse: AcpJson.boolean(json, 'sse') ?? false,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['http', 'sse']),
  );

  /// Whether MCP over HTTP is supported.
  final bool http;

  /// Whether deprecated MCP over SSE is supported.
  final bool sse;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Authentication capabilities advertised by an ACP agent.
final class AcpAuthCapabilities implements AcpExtensible {
  /// Creates authentication capabilities.
  const AcpAuthCapabilities({
    this.logout = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses authentication capabilities.
  factory AcpAuthCapabilities.fromJson(AcpJsonMap json) => AcpAuthCapabilities(
    logout: _supportsCapability(json, 'logout'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['logout']),
  );

  /// Whether `logout` is supported.
  final bool logout;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Capabilities advertised by an ACP agent.
final class AcpAgentCapabilities implements AcpExtensible {
  /// Creates agent capabilities.
  const AcpAgentCapabilities({
    this.loadSession = false,
    this.prompt = const AcpPromptCapabilities(),
    this.mcp = const AcpMcpCapabilities(),
    this.session = const AcpSessionCapabilities(),
    this.auth = const AcpAuthCapabilities(),
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses agent capabilities.
  factory AcpAgentCapabilities.fromJson(AcpJsonMap json) {
    final prompt = AcpJson.objectField(json, 'promptCapabilities');
    final mcp = AcpJson.objectField(json, 'mcpCapabilities');
    final session = AcpJson.objectField(json, 'sessionCapabilities');
    final auth = AcpJson.objectField(json, 'auth');
    return AcpAgentCapabilities(
      loadSession: AcpJson.boolean(json, 'loadSession') ?? false,
      prompt: prompt == null
          ? const AcpPromptCapabilities()
          : AcpPromptCapabilities.fromJson(prompt),
      mcp: mcp == null
          ? const AcpMcpCapabilities()
          : AcpMcpCapabilities.fromJson(mcp),
      session: session == null
          ? const AcpSessionCapabilities()
          : AcpSessionCapabilities.fromJson(session),
      auth: auth == null
          ? const AcpAuthCapabilities()
          : AcpAuthCapabilities.fromJson(auth),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'loadSession',
        'promptCapabilities',
        'mcpCapabilities',
        'sessionCapabilities',
        'auth',
      ]),
    );
  }

  /// Whether legacy `session/load` is supported.
  final bool loadSession;

  /// Supported prompt content.
  final AcpPromptCapabilities prompt;

  /// Supported MCP transports.
  final AcpMcpCapabilities mcp;

  /// Supported optional session operations.
  final AcpSessionCapabilities session;

  /// Supported authentication operations.
  final AcpAuthCapabilities auth;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// An authentication method offered by an ACP agent.
final class AcpAuthMethod implements AcpExtensible {
  /// Creates an authentication method.
  const AcpAuthMethod({
    required this.id,
    required this.name,
    this.type = 'agent',
    this.description,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an authentication method.
  factory AcpAuthMethod.fromJson(AcpJsonMap json) => AcpAuthMethod(
    id: AcpJson.identifier(json, 'id') ?? '',
    name: AcpJson.string(json, 'name') ?? '',
    type: AcpJson.string(json, 'type') ?? 'agent',
    description: AcpJson.string(json, 'description'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'id',
      'name',
      'type',
      'description',
    ]),
  );

  /// Stable authentication method identifier.
  final String id;

  /// Human-readable authentication method name.
  final String name;

  /// Authentication method discriminator.
  final String type;

  /// Optional method description.
  final String? description;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Result of ACP initialization.
final class AcpInitializeResult implements AcpExtensible {
  /// Creates an initialization result.
  const AcpInitializeResult({
    required this.protocolVersion,
    this.agentCapabilities = const AcpAgentCapabilities(),
    this.authMethods = const <AcpAuthMethod>[],
    this.agentInfo,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an initialization result.
  factory AcpInitializeResult.fromJson(AcpJsonMap json) {
    final capabilities = AcpJson.objectField(json, 'agentCapabilities');
    final info = AcpJson.objectField(json, 'agentInfo');
    return AcpInitializeResult(
      protocolVersion: AcpJson.integer(json, 'protocolVersion') ?? 0,
      agentCapabilities: capabilities == null
          ? const AcpAgentCapabilities()
          : AcpAgentCapabilities.fromJson(capabilities),
      authMethods: AcpJson.objectList(
        json['authMethods'],
        AcpAuthMethod.fromJson,
      ),
      agentInfo: info == null ? null : AcpImplementation.fromJson(info),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'protocolVersion',
        'agentCapabilities',
        'authMethods',
        'agentInfo',
      ]),
    );
  }

  /// Negotiated ACP major version.
  final int protocolVersion;

  /// Agent capabilities.
  final AcpAgentCapabilities agentCapabilities;

  /// Authentication methods.
  final List<AcpAuthMethod> authMethods;

  /// Optional agent implementation information.
  final AcpImplementation? agentInfo;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Summary of a resumable ACP session.
final class AcpSessionInfo implements AcpExtensible {
  /// Creates session information.
  const AcpSessionInfo({
    required this.sessionId,
    required this.cwd,
    this.additionalDirectories = const <String>[],
    this.title,
    this.updatedAt,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses session information.
  factory AcpSessionInfo.fromJson(AcpJsonMap json) => AcpSessionInfo(
    sessionId: AcpJson.identifier(json, 'sessionId') ?? '',
    cwd:
        AcpJson.string(json, 'cwd') ??
        AcpJson.string(json, 'workingDirectory') ??
        AcpJson.string(json, 'directory') ??
        '',
    additionalDirectories: AcpJson.strings(json['additionalDirectories']),
    title:
        AcpJson.string(json, 'title') ??
        AcpJson.string(json, 'summary') ??
        AcpJson.string(json, 'name'),
    updatedAt: _timestampValue(
      json['updatedAt'] ?? json['updated_at'] ?? json['updated'],
    ),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'sessionId',
      'cwd',
      'workingDirectory',
      'directory',
      'additionalDirectories',
      'title',
      'summary',
      'name',
      'updatedAt',
      'updated_at',
      'updated',
    ]),
  );

  /// Session identifier.
  final String sessionId;

  /// Session working directory.
  final String cwd;

  /// Additional workspace roots.
  final List<String> additionalDirectories;

  /// Optional session title.
  final String? title;

  /// ISO-8601 update timestamp or a legacy epoch-millisecond value.
  final Object? updatedAt;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A session mode offered by an ACP agent.
final class AcpSessionMode implements AcpExtensible {
  /// Creates a session mode.
  const AcpSessionMode({
    required this.id,
    required this.name,
    this.description,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a session mode.
  factory AcpSessionMode.fromJson(AcpJsonMap json) => AcpSessionMode(
    id: AcpJson.identifier(json, 'id') ?? '',
    name: AcpJson.string(json, 'name') ?? '',
    description: AcpJson.string(json, 'description'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['id', 'name', 'description']),
  );

  /// Mode identifier.
  final String id;

  /// Mode name.
  final String name;

  /// Optional mode description.
  final String? description;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Current and available legacy session modes.
final class AcpSessionModeState implements AcpExtensible {
  /// Creates session mode state.
  const AcpSessionModeState({
    required this.currentModeId,
    this.availableModes = const <AcpSessionMode>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses session mode state.
  factory AcpSessionModeState.fromJson(AcpJsonMap json) => AcpSessionModeState(
    currentModeId: AcpJson.identifier(json, 'currentModeId') ?? '',
    availableModes: AcpJson.objectList(
      json['availableModes'],
      AcpSessionMode.fromJson,
    ),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'currentModeId',
      'availableModes',
    ]),
  );

  /// Active mode identifier.
  final String currentModeId;

  /// Available modes.
  final List<AcpSessionMode> availableModes;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A legacy ACP model description retained for provider compatibility.
final class AcpModelInfo implements AcpExtensible {
  /// Creates model information.
  const AcpModelInfo({
    required this.id,
    required this.name,
    this.description,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses model information.
  factory AcpModelInfo.fromJson(AcpJsonMap json) => AcpModelInfo(
    id:
        AcpJson.identifier(json, 'id') ??
        AcpJson.identifier(json, 'modelId') ??
        AcpJson.identifier(json, 'value') ??
        '',
    name: AcpJson.string(json, 'name') ?? AcpJson.string(json, 'title') ?? '',
    description: AcpJson.string(json, 'description'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'id',
      'modelId',
      'value',
      'name',
      'title',
      'description',
    ]),
  );

  /// Model identifier.
  final String id;

  /// Model name.
  final String name;

  /// Optional model description.
  final String? description;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Current and available legacy ACP models.
final class AcpModelState implements AcpExtensible {
  /// Creates model state.
  const AcpModelState({
    required this.currentModelId,
    this.availableModels = const <AcpModelInfo>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses model state.
  factory AcpModelState.fromJson(AcpJsonMap json) {
    final models = <AcpModelInfo>[];
    final rawModels =
        AcpJson.listField(json, 'availableModels') ??
        AcpJson.listField(json, 'models') ??
        const <Object?>[];
    for (final item in rawModels) {
      final model = AcpJson.object(item);
      if (model != null) models.add(AcpModelInfo.fromJson(model));
    }
    return AcpModelState(
      currentModelId:
          AcpJson.identifier(json, 'currentModelId') ??
          AcpJson.identifier(json, 'modelId') ??
          '',
      availableModels: List<AcpModelInfo>.unmodifiable(models),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'currentModelId',
        'modelId',
        'availableModels',
        'models',
      ]),
    );
  }

  /// Active model identifier.
  final String currentModelId;

  /// Available models.
  final List<AcpModelInfo> availableModels;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A selectable value for a session configuration option.
final class AcpConfigValue implements AcpExtensible {
  /// Creates a configuration value.
  const AcpConfigValue({
    required this.value,
    required this.name,
    this.description,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a configuration value.
  factory AcpConfigValue.fromJson(AcpJsonMap json) => AcpConfigValue(
    value: AcpJson.identifier(json, 'value') ?? '',
    name: AcpJson.string(json, 'name') ?? '',
    description: AcpJson.string(json, 'description'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'value',
      'name',
      'description',
    ]),
  );

  /// Value identifier.
  final String value;

  /// Display name.
  final String name;

  /// Optional value description.
  final String? description;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A group of selectable configuration values.
final class AcpConfigValueGroup implements AcpExtensible {
  /// Creates a configuration value group.
  const AcpConfigValueGroup({
    required this.id,
    required this.name,
    this.options = const <AcpConfigValue>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a configuration value group.
  factory AcpConfigValueGroup.fromJson(AcpJsonMap json) => AcpConfigValueGroup(
    id: AcpJson.identifier(json, 'group') ?? '',
    name: AcpJson.string(json, 'name') ?? '',
    options: AcpJson.objectList(json['options'], AcpConfigValue.fromJson),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['group', 'name', 'options']),
  );

  /// Group identifier.
  final String id;

  /// Group display name.
  final String name;

  /// Values in this group.
  final List<AcpConfigValue> options;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Base class for ACP session configuration options.
sealed class AcpSessionConfigOption implements AcpExtensible {
  const AcpSessionConfigOption();

  /// Parses a known or extension configuration option.
  factory AcpSessionConfigOption.fromJson(AcpJsonMap json) =>
      switch (AcpJson.string(json, 'type')) {
        'select' => AcpSelectConfigOption.fromJson(json),
        'boolean' => AcpBooleanConfigOption.fromJson(json),
        _ => AcpUnknownConfigOption.fromJson(json),
      };

  /// Configuration identifier.
  String get id;

  /// Display name.
  String get name;

  /// Optional description.
  String? get description;

  /// Optional semantic category.
  String? get category;

  /// Configuration type discriminator.
  String get type;
}

/// A select configuration option.
final class AcpSelectConfigOption extends AcpSessionConfigOption {
  /// Creates a select configuration option.
  const AcpSelectConfigOption({
    required this.id,
    required this.name,
    required this.currentValue,
    this.options = const <AcpConfigValue>[],
    this.groups = const <AcpConfigValueGroup>[],
    this.description,
    this.category,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a select configuration option.
  factory AcpSelectConfigOption.fromJson(AcpJsonMap json) {
    final options = <AcpConfigValue>[];
    final groups = <AcpConfigValueGroup>[];
    for (final item in AcpJson.listField(json, 'options') ?? const []) {
      final option = AcpJson.object(item);
      if (option == null) continue;
      if (option.containsKey('group')) {
        groups.add(AcpConfigValueGroup.fromJson(option));
      } else {
        options.add(AcpConfigValue.fromJson(option));
      }
    }
    return AcpSelectConfigOption(
      id: AcpJson.identifier(json, 'id') ?? '',
      name: AcpJson.string(json, 'name') ?? '',
      currentValue: AcpJson.identifier(json, 'currentValue') ?? '',
      options: List<AcpConfigValue>.unmodifiable(options),
      groups: List<AcpConfigValueGroup>.unmodifiable(groups),
      description: AcpJson.string(json, 'description'),
      category: AcpJson.string(json, 'category'),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'id',
        'name',
        'currentValue',
        'options',
        'description',
        'category',
        'type',
      ]),
    );
  }

  @override
  final String id;

  @override
  final String name;

  /// Currently selected value.
  final String currentValue;

  /// Ungrouped values.
  final List<AcpConfigValue> options;

  /// Grouped values.
  final List<AcpConfigValueGroup> groups;

  @override
  final String? description;

  @override
  final String? category;

  @override
  String get type => 'select';

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A boolean configuration option.
final class AcpBooleanConfigOption extends AcpSessionConfigOption {
  /// Creates a boolean configuration option.
  const AcpBooleanConfigOption({
    required this.id,
    required this.name,
    required this.currentValue,
    this.description,
    this.category,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a boolean configuration option.
  factory AcpBooleanConfigOption.fromJson(AcpJsonMap json) =>
      AcpBooleanConfigOption(
        id: AcpJson.identifier(json, 'id') ?? '',
        name: AcpJson.string(json, 'name') ?? '',
        currentValue: AcpJson.boolean(json, 'currentValue') ?? false,
        description: AcpJson.string(json, 'description'),
        category: AcpJson.string(json, 'category'),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'id',
          'name',
          'currentValue',
          'description',
          'category',
          'type',
        ]),
      );

  @override
  final String id;

  @override
  final String name;

  /// Current toggle value.
  final bool currentValue;

  @override
  final String? description;

  @override
  final String? category;

  @override
  String get type => 'boolean';

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Unknown configuration option retained for future protocol versions.
final class AcpUnknownConfigOption extends AcpSessionConfigOption {
  /// Creates an unknown configuration option.
  const AcpUnknownConfigOption({
    required this.id,
    required this.name,
    required this.type,
    required this.raw,
    this.description,
    this.category,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an unknown configuration option.
  factory AcpUnknownConfigOption.fromJson(AcpJsonMap json) =>
      AcpUnknownConfigOption(
        id: AcpJson.identifier(json, 'id') ?? '',
        name: AcpJson.string(json, 'name') ?? '',
        type: AcpJson.string(json, 'type') ?? 'unknown',
        raw: AcpJson.immutableObject(json),
        description: AcpJson.string(json, 'description'),
        category: AcpJson.string(json, 'category'),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'id',
          'name',
          'type',
          'description',
          'category',
        ]),
      );

  @override
  final String id;

  @override
  final String name;

  @override
  final String type;

  /// Complete unrecognized option.
  final AcpJsonMap raw;

  @override
  final String? description;

  @override
  final String? category;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

AcpSessionModeState? _modeStateFromProviderMeta(AcpJsonMap meta) {
  final config = AcpJson.objectField(meta, 'x.ai/sessionConfig');
  final rawOptions = config == null
      ? null
      : AcpJson.listField(config, 'options');
  if (rawOptions == null) {
    return null;
  }
  final modes = <AcpSessionMode>[];
  String? selectedId;
  for (final item in rawOptions) {
    final option = AcpJson.object(item);
    if (option == null || AcpJson.string(option, 'category') != 'mode') {
      continue;
    }
    final id = AcpJson.string(option, 'id')?.trim() ?? '';
    if (id.isEmpty) {
      continue;
    }
    modes.add(
      AcpSessionMode(
        id: id,
        name: AcpJson.string(option, 'label') ?? id,
        description: AcpJson.string(option, 'description'),
        meta: AcpJson.meta(option),
        extensions: AcpJson.extensions(option, const [
          'id',
          'category',
          'label',
          'description',
          'selected',
        ]),
      ),
    );
    if (AcpJson.boolean(option, 'selected') ?? false) {
      selectedId = id;
    }
  }
  if (modes.isEmpty) {
    return null;
  }
  return AcpSessionModeState(
    currentModeId: selectedId ?? modes.first.id,
    availableModes: List<AcpSessionMode>.unmodifiable(modes),
    meta: config == null ? const <String, Object?>{} : AcpJson.meta(config),
  );
}

/// Result of creating, loading, resuming, or forking a session.
final class AcpSessionSetupResult implements AcpExtensible {
  /// Creates a session setup result.
  const AcpSessionSetupResult({
    this.sessionId,
    this.modes,
    this.models,
    this.configOptions = const <AcpSessionConfigOption>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a session setup result.
  factory AcpSessionSetupResult.fromJson(AcpJsonMap json) {
    final modes = AcpJson.objectField(json, 'modes');
    final meta = AcpJson.meta(json);
    final models =
        AcpJson.objectField(json, 'models') ??
        AcpJson.objectField(json, 'modelState') ??
        (AcpJson.listField(json, 'models') == null ? null : json);
    return AcpSessionSetupResult(
      sessionId: AcpJson.identifier(json, 'sessionId'),
      modes: modes == null
          ? _modeStateFromProviderMeta(meta)
          : AcpSessionModeState.fromJson(modes),
      models: models == null ? null : AcpModelState.fromJson(models),
      configOptions: AcpJson.objectList(
        json['configOptions'],
        AcpSessionConfigOption.fromJson,
      ),
      meta: meta,
      extensions: AcpJson.extensions(json, const [
        'sessionId',
        'modes',
        'models',
        'modelState',
        'configOptions',
      ]),
    );
  }

  /// New session identifier, when the operation creates one.
  final String? sessionId;

  /// Legacy mode state.
  final AcpSessionModeState? modes;

  /// Legacy model state.
  final AcpModelState? models;

  /// Generic session configuration options.
  final List<AcpSessionConfigOption> configOptions;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// One page returned by `session/list`.
final class AcpSessionListResult implements AcpExtensible {
  /// Creates a session list result.
  const AcpSessionListResult({
    this.sessions = const <AcpSessionInfo>[],
    this.nextCursor,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a session list result.
  factory AcpSessionListResult.fromJson(AcpJsonMap json) {
    final sessions = <AcpSessionInfo>[];
    for (final item in AcpJson.listField(json, 'sessions') ?? const []) {
      final session = AcpJson.object(item);
      if (session == null) continue;
      final parsed = AcpSessionInfo.fromJson(session);
      if (parsed.sessionId.isNotEmpty) sessions.add(parsed);
    }
    return AcpSessionListResult(
      sessions: List<AcpSessionInfo>.unmodifiable(sessions),
      nextCursor: AcpJson.identifier(json, 'nextCursor'),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const ['sessions', 'nextCursor']),
    );
  }

  /// Sessions in this page.
  final List<AcpSessionInfo> sessions;

  /// Opaque cursor for the next page.
  final String? nextCursor;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Forward-compatible ACP prompt stop reason.
extension type const AcpStopReason(String value) {
  /// The turn completed normally.
  static const endTurn = AcpStopReason('end_turn');

  /// The agent reached its token limit.
  static const maxTokens = AcpStopReason('max_tokens');

  /// The agent refused the prompt.
  static const refusal = AcpStopReason('refusal');

  /// The client cancelled the turn.
  static const cancelled = AcpStopReason('cancelled');
}

/// Result of a prompt turn.
final class AcpPromptResult implements AcpExtensible {
  /// Creates a prompt result.
  const AcpPromptResult({
    required this.stopReason,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a prompt result.
  factory AcpPromptResult.fromJson(AcpJsonMap json) => AcpPromptResult(
    stopReason: AcpStopReason(AcpJson.string(json, 'stopReason') ?? 'unknown'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['stopReason']),
  );

  /// Why the prompt turn stopped.
  final AcpStopReason stopReason;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

bool _supportsCapability(AcpJsonMap json, String key) =>
    json.containsKey(key) && json[key] != null && json[key] != false;

Object? _timestampValue(Object? value) =>
    value is String || value is int ? value : null;
