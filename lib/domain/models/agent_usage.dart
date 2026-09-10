/// Availability of account quota information on the remote host.
enum AgentUsageStatus {
  /// A quota snapshot was returned.
  available,

  /// This agent has no supported account quota reader.
  unsupported,

  /// The provider does not expose a quota for this authentication method.
  notReported,

  /// No accounts were found in this agent's supported credential stores.
  noAccounts,

  /// The agent must be running to expose its local usage interface.
  needsRunning,

  /// Authentication is missing or expired.
  signInRequired,

  /// The provider temporarily throttled usage checks.
  rateLimited,

  /// The host or provider could not report usage.
  unavailable,
}

/// One account quota window. Values are snapshots, never estimates.
class AgentUsageWindow {
  /// Creates a quota window.
  const AgentUsageWindow({
    required this.label,
    this.usedPercent,
    this.resetsAt,
    this.unlimited = false,
    this.used,
    this.limit,
    this.overageAllowed = false,
    this.restricted,
    this.remaining,
    this.unit,
  });

  /// Provider quota category.
  final String label;

  /// Percentage consumed, possibly above 100 when overage is allowed.
  final double? usedPercent;

  /// Next provider-reported reset in UTC.
  final DateTime? resetsAt;

  /// Whether this particular quota has no limit.
  final bool unlimited;

  /// Units consumed when reported.
  final double? used;

  /// Included units when reported.
  final double? limit;

  /// Whether additional paid usage is allowed.
  final bool overageAllowed;

  /// Explicit account restriction when the provider does not report amounts.
  final bool? restricted;

  /// Remaining balance when the provider reports no total allowance.
  final double? remaining;

  /// Unit for monetary figures, currently USD only.
  final String? unit;
}

/// In-memory account usage snapshot, shared by an agent's CLI and adapters.
class AgentUsage {
  /// Creates a usage snapshot.
  const AgentUsage({
    required this.status,
    this.windows = const [],
    this.checkedAt,
    this.resetCredits,
    this.notices = const [],
  });

  /// Availability of usage data.
  final AgentUsageStatus status;

  /// Independently metered quotas.
  final List<AgentUsageWindow> windows;

  /// Time this check completed.
  final DateTime? checkedAt;

  /// Available earned resets, when the provider reports them.
  final int? resetCredits;

  /// Accounts whose quota is missing, including partial check failures.
  final List<AgentUsageNotice> notices;
}

/// Availability for one provider within a multi-provider agent.
class AgentUsageNotice {
  /// Creates a provider notice without including account identifiers.
  const AgentUsageNotice({required this.provider, required this.status});

  /// Provider name, optionally with an anonymous account number.
  final String provider;

  /// Reason this account has no quota figures.
  final AgentUsageStatus status;
}
