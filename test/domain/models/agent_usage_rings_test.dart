import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/agent_usage_rings.dart';
import 'package:monkeyssh/domain/services/agent_usage_parser.dart';

void main() {
  final now = DateTime.utc(2026, 9, 8, 12);
  AgentUsage snapshot(List<AgentUsageWindow> windows, {DateTime? checkedAt}) =>
      AgentUsage(
        status: AgentUsageStatus.available,
        windows: windows,
        checkedAt: checkedAt ?? now,
      );
  AgentUsageRings? project(
    AgentUsage usage, {
    AgentLaunchTool tool = AgentLaunchTool.claudeCode,
  }) => resolveAgentUsageRings(tool, usage, now: now);

  group('Pi selected provider', () {
    AcpSessionState session({
      String? model,
      String? selection,
      String providerId = AcpBuiltinProviderIds.pi,
    }) => AcpSessionState(
      key: AcpSessionKey.of(
        hostId: 1,
        providerId: providerId,
        bridgeId: 'bridge',
        acpSessionId: 'session',
      ),
      providerLabel: 'Pi',
      cwd: '/workspace',
      status: AcpConnectionStatus.ready,
      createdAt: now,
      lastActivityAt: now,
      modelState: model == null ? null : AcpModelState(currentModelId: model),
      configOptions: [
        if (selection != null)
          AcpSelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            currentValue: selection,
          ),
      ],
    );

    test('uses live selection before legacy model and rejects unknowns', () {
      expect(
        piUsageModelProvider(session(model: 'anthropic/claude')),
        'anthropic',
      );
      expect(
        piUsageModelProvider(
          session(model: 'anthropic/claude', selection: 'openai-codex/gpt'),
        ),
        'openai-codex',
      );
      expect(
        piUsageModelProvider(session(model: 'openrouter/vendor/model')),
        'openrouter',
      );
      for (final model in [
        '',
        'claude',
        'anthropic/',
        '/claude',
        'custom/claude',
      ]) {
        expect(
          piUsageModelProvider(
            session(model: 'anthropic/claude', selection: model),
          ),
          isNull,
        );
      }
      expect(
        piUsageModelProvider(
          session(
            model: 'anthropic/claude',
            providerId: AcpBuiltinProviderIds.openCode,
          ),
        ),
        isNull,
      );
      expect(piUsageModelProvider(null), isNull);
    });

    AgentUsageRings? pi(AgentUsage usage, String? provider) =>
        resolveAgentUsageRings(
          AgentLaunchTool.pi,
          usage,
          now: now,
          modelProvider: provider,
        );

    test(
      'selects Pi account quotas and excludes other providers and model caps',
      () {
        final usage = snapshot(const [
          AgentUsageWindow(label: 'Anthropic · 5 hours', usedPercent: 25),
          AgentUsageWindow(label: 'Anthropic · Weekly', usedPercent: 40),
          AgentUsageWindow(
            label: 'Anthropic · Weekly · Sonnet',
            usedPercent: 99,
          ),
          AgentUsageWindow(label: 'OpenAI Codex · 5 hours', usedPercent: 80),
          AgentUsageWindow(
            label: 'OpenAI Codex · scoped · Weekly',
            usedPercent: 0,
          ),
          AgentUsageWindow(label: 'Weekly', usedPercent: 0),
        ]);
        expect(pi(usage, 'anthropic')!.segments, [
          (label: '5-hour', remaining: 75.0),
          (label: 'weekly', remaining: 60.0),
        ]);
        expect(pi(usage, 'openai-codex')!.segments, [
          (label: '5-hour', remaining: 20.0),
        ]);
        expect(pi(usage, null), isNull);
        expect(pi(usage, 'custom'), isNull);
        expect(pi(usage, 'openai'), isNull);
      },
    );

    test('unrelated failures do not hide the selected provider', () {
      for (final provider in ['OpenAI Codex', 'Anthropic']) {
        final rings = pi(
          AgentUsage(
            status: AgentUsageStatus.available,
            checkedAt: now,
            windows: const [
              AgentUsageWindow(label: 'Anthropic · Weekly', usedPercent: 20),
            ],
            notices: [
              AgentUsageNotice(
                provider: provider,
                status: AgentUsageStatus.unavailable,
              ),
            ],
          ),
          'anthropic',
        );
        expect(rings?.weekly, provider == 'Anthropic' ? isNull : 80);
      }
    });

    test('only numerical selected-provider windows get segments', () {
      final usage = snapshot(const [
        AgentUsageWindow(label: 'Google Antigravity · Pro', usedPercent: 35),
        AgentUsageWindow(
          label: 'GitHub Copilot · Premium requests',
          usedPercent: 10,
        ),
        AgentUsageWindow(
          label: 'GitHub Copilot · Chat',
          usedPercent: 0,
          unlimited: true,
        ),
        AgentUsageWindow(
          label: 'OpenRouter · Key balance',
          remaining: 50,
          unit: 'USD',
        ),
      ]);
      expect(pi(usage, 'google-antigravity')!.segments, [
        (label: 'Google Antigravity · Pro', remaining: 65.0),
      ]);
      expect(pi(usage, 'github-copilot')!.segments, [
        (label: 'GitHub Copilot · Premium requests', remaining: 90.0),
      ]);
      expect(pi(usage, 'openrouter'), isNull);
    });

    test('selected reset and snapshot expiry never imply replenishment', () {
      final usage = snapshot([
        AgentUsageWindow(
          label: 'Anthropic · 5 hours',
          usedPercent: 80,
          resetsAt: now,
        ),
        const AgentUsageWindow(label: 'Anthropic · Weekly', usedPercent: 20),
      ]);
      expect(pi(usage, 'anthropic')!.segments, [
        (label: 'weekly', remaining: 80.0),
      ]);
      expect(
        isAgentUsageRingWindow(
          AgentLaunchTool.pi,
          usage.windows.first,
          modelProvider: 'anthropic',
        ),
        isTrue,
      );
      expect(
        isAgentUsageRingWindow(
          AgentLaunchTool.pi,
          usage.windows.first,
          modelProvider: 'openai-codex',
        ),
        isFalse,
      );
      expect(
        pi(
          snapshot(
            usage.windows,
            checkedAt: now.subtract(const Duration(minutes: 6)),
          ),
          'anthropic',
        ),
        isNull,
      );
      expect(
        agentUsageRefreshInterval(AgentLaunchTool.pi),
        const Duration(minutes: 5),
      );
    });
  });

  test('reported Codex weekly 77 percent is not inverted or replaced by scoped 100 percent', () {
    final usage = parseAgentUsageOutput(
      '__monkeyssh_usage__={"id":"codex","status":"available","windows":[ '
      '{"label":"Weekly","usedPercent":23}, '
      '{"label":"codex_bengalfox · 5 hours","usedPercent":0}, '
      '{"label":"codex_bengalfox · Weekly","usedPercent":0}]}',
      checkedAt: now,
    )['codex']!;
    final rings = project(usage, tool: AgentLaunchTool.codex)!;
    expect(rings.weekly, 77);
    expect(rings.shortTerm, isNull);
  });

  test('reported usage drains from full to empty rather than filling up', () {
    for (final used in [0.0, 23.0, 75.0, 100.0]) {
      final rings = project(
        snapshot([AgentUsageWindow(label: 'Weekly', usedPercent: used)]),
      )!;
      expect(rings.segments, [(label: 'weekly', remaining: 100 - used)]);
    }
  });

  test('Grok included credits get a meter, paid spending and prepaid balances do not', () {
    final rings = project(
      snapshot(const [
        AgentUsageWindow(
          label: 'Included credits',
          usedPercent: 0,
          unit: 'USD',
        ),
        AgentUsageWindow(
          label: 'On-demand spending',
          usedPercent: 80,
          unit: 'USD',
        ),
        AgentUsageWindow(label: 'Prepaid balance', remaining: 25, unit: 'USD'),
      ]),
      tool: AgentLaunchTool.grokBuild,
    )!;
    expect(rings.segments, [(label: 'Included credits', remaining: 100.0)]);
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(
            label: 'Prepaid balance',
            remaining: 25,
            unit: 'USD',
          ),
        ]),
        tool: AgentLaunchTool.grokBuild,
      ),
      isNull,
    );
    final partlyUsed = project(
      snapshot(const [
        AgentUsageWindow(label: 'Included credits', usedPercent: 25),
      ]),
      tool: AgentLaunchTool.grokBuild,
    )!;
    expect(partlyUsed.segments.single.remaining, 75);
  });

  test('Antigravity reports its numerical groups in stable order without guessing an active model', () {
    const windows = [
      AgentUsageWindow(label: 'Thinking · Pro', usedPercent: 25),
      AgentUsageWindow(label: 'Fast · Basic', usedPercent: 0),
      AgentUsageWindow(label: 'Unknown group', remaining: 15),
    ];
    final a = project(snapshot(windows), tool: AgentLaunchTool.antigravity)!;
    final b = project(
      snapshot(windows.reversed.toList()),
      tool: AgentLaunchTool.antigravity,
    )!;
    expect(a.segments, [
      (label: 'Fast · Basic', remaining: 100.0),
      (label: 'Thinking · Pro', remaining: 75.0),
    ]);
    expect(b.segments, a.segments);
  });

  test(
    'Antigravity omits duplicate, expired, and unlimited group percentages',
    () {
      final usage = snapshot([
        const AgentUsageWindow(label: 'Duplicate', usedPercent: 10),
        const AgentUsageWindow(label: 'Duplicate', usedPercent: 20),
        AgentUsageWindow(label: 'Expired', usedPercent: 100, resetsAt: now),
        const AgentUsageWindow(label: 'Unlimited', unlimited: true),
        const AgentUsageWindow(label: 'Pro', usedPercent: 100),
      ]);
      expect(project(usage, tool: AgentLaunchTool.antigravity)!.segments, [
        (label: 'Pro', remaining: 0.0),
      ]);
    },
  );

  test('provider quota categories are registered for reset scheduling', () {
    expect(supportsAgentUsageRings(AgentLaunchTool.antigravity), isTrue);
    expect(supportsAgentUsageRings(AgentLaunchTool.grokBuild), isTrue);
    expect(
      isAgentUsageRingWindow(
        AgentLaunchTool.antigravity,
        const AgentUsageWindow(label: 'Pro', usedPercent: 25),
      ),
      isTrue,
    );
    expect(
      isAgentUsageRingWindow(
        AgentLaunchTool.grokBuild,
        const AgentUsageWindow(label: 'Included credits', usedPercent: 25),
      ),
      isTrue,
    );
    expect(
      isAgentUsageRingWindow(
        AgentLaunchTool.grokBuild,
        const AgentUsageWindow(label: 'On-demand spending', usedPercent: 25),
      ),
      isFalse,
    );
  });

  test('projects account-wide windows and ignores scoped model caps', () {
    final usage = snapshot(const [
      AgentUsageWindow(label: '5 hours', usedPercent: 42),
      AgentUsageWindow(label: 'Weekly', usedPercent: 18),
      AgentUsageWindow(label: 'Weekly · Fable', usedPercent: 99),
    ]);
    for (final tool in [AgentLaunchTool.claudeCode, AgentLaunchTool.codex]) {
      final rings = project(usage, tool: tool)!;
      expect(rings.shortTerm, 58);
      expect(rings.weekly, 82);
    }
  });
  test('duplicate or model/account-prefixed categories are not guessed', () {
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: '5 hours', usedPercent: 42),
          AgentUsageWindow(label: '5 hours', usedPercent: 72),
          AgentUsageWindow(label: 'Other account · Weekly', usedPercent: 18),
        ]),
      ),
      isNull,
    );
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: 'Weekly · Fable', usedPercent: 99),
        ]),
      ),
      isNull,
    );
  });
  test('multi-provider agents remain unknown rather than selecting a saved account', () {
    final usage = snapshot(const [
      AgentUsageWindow(label: 'Weekly', usedPercent: 25),
    ]);
    for (final tool in AgentLaunchTool.values.where(
      (tool) => !supportsAgentUsageRings(tool),
    )) {
      expect(project(usage, tool: tool), isNull);
    }
  });
  test('zero and overage are empty, missing and unlimited are absent', () {
    final rings = project(
      snapshot(const [
        AgentUsageWindow(
          label: '5 hours',
          usedPercent: 125,
          overageAllowed: true,
        ),
        AgentUsageWindow(label: 'Weekly', unlimited: true),
      ]),
    )!;
    expect(rings.shortTerm, 0);
    expect(rings.weekly, isNull);
    expect(
      project(
        snapshot(const [
          AgentUsageWindow(label: '5 hours', remaining: 20, unit: 'USD'),
        ]),
      ),
      isNull,
    );
  });
  test('an elapsed reset hides only that half and never replenishes it', () {
    final rings = project(
      snapshot([
        AgentUsageWindow(label: '5 hours', usedPercent: 100, resetsAt: now),
        AgentUsageWindow(
          label: 'Weekly',
          usedPercent: 36,
          resetsAt: now.add(const Duration(days: 1)),
        ),
      ]),
    )!;
    expect(rings.shortTerm, isNull);
    expect(rings.weekly, 64);
  });
  test(
    'stale, failed, partial, and nonfinite snapshots do not imply capacity',
    () {
      const windows = [AgentUsageWindow(label: '5 hours', usedPercent: 25)];
      expect(
        project(
          snapshot(
            windows,
            checkedAt: now.subtract(const Duration(minutes: 6)),
          ),
        ),
        isNull,
      );
      expect(
        project(
          const AgentUsage(
            status: AgentUsageStatus.available,
            windows: windows,
          ),
        ),
        isNull,
      );
      for (final status in AgentUsageStatus.values.where(
        (s) => s != AgentUsageStatus.available,
      )) {
        expect(
          project(AgentUsage(status: status, checkedAt: now, windows: windows)),
          isNull,
        );
      }
      expect(
        project(
          AgentUsage(
            status: AgentUsageStatus.available,
            checkedAt: now,
            windows: windows,
            notices: const [
              AgentUsageNotice(
                provider: 'Other',
                status: AgentUsageStatus.unavailable,
              ),
            ],
          ),
        ),
        isNull,
      );
      for (final value in [double.nan, double.infinity, -1.0]) {
        expect(
          project(
            snapshot([AgentUsageWindow(label: '5 hours', usedPercent: value)]),
          ),
          isNull,
        );
      }
    },
  );
}
