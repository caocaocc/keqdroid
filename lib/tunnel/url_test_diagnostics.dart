/// Optional desktop probe details; older native backends may omit them.
class UrlTestDiagnostics {
  final String stage;
  final int elapsedMs;
  final int budgetMs;
  final String timingKind;
  final int completedRequests;
  final String? warning;

  /// Individual network phases, plus coreStartup when a temporary core is used.
  /// [elapsedMs] and [budgetMs] describe only the active measurement budget.
  final Map<String, int> stageDurationsMs;
  final int? coreStartupBudgetMs;

  const UrlTestDiagnostics({
    required this.stage,
    required this.elapsedMs,
    required this.budgetMs,
    this.timingKind = 'cold',
    this.completedRequests = 0,
    this.warning,
    this.stageDurationsMs = const {},
    this.coreStartupBudgetMs,
  });

  UrlTestDiagnostics withCoreStartup({
    required int elapsedMs,
    required int budgetMs,
  }) => UrlTestDiagnostics(
    stage: stage,
    elapsedMs: this.elapsedMs,
    budgetMs: this.budgetMs,
    timingKind: timingKind,
    completedRequests: completedRequests,
    warning: warning,
    stageDurationsMs: {'coreStartup': elapsedMs, ...stageDurationsMs},
    coreStartupBudgetMs: budgetMs,
  );

  Map<String, Object?> toMap() => {
    'stage': stage,
    'elapsedMs': elapsedMs,
    'budgetMs': budgetMs,
    'timingKind': timingKind,
    'completedRequests': completedRequests,
    if (warning != null) 'warning': warning,
    if (stageDurationsMs.isNotEmpty) 'stageDurationsMs': stageDurationsMs,
    if (coreStartupBudgetMs != null) 'coreStartupBudgetMs': coreStartupBudgetMs,
  };

  static UrlTestDiagnostics? fromMap(Object? value) {
    if (value is! Map || value['stage'] is! String) return null;
    return UrlTestDiagnostics(
      stage: value['stage'] as String,
      elapsedMs: (value['elapsedMs'] as num?)?.toInt() ?? 0,
      budgetMs: (value['budgetMs'] as num?)?.toInt() ?? 0,
      timingKind: value['timingKind'] as String? ?? 'cold',
      completedRequests: (value['completedRequests'] as num?)?.toInt() ?? 0,
      warning: value['warning'] as String?,
      stageDurationsMs: value['stageDurationsMs'] is Map
          ? {
              for (final entry in (value['stageDurationsMs'] as Map).entries)
                if (entry.key is String &&
                    entry.value is num &&
                    (entry.value as num).isFinite &&
                    entry.value >= 0)
                  entry.key as String: (entry.value as num).toInt(),
            }
          : const {},
      coreStartupBudgetMs: (value['coreStartupBudgetMs'] as num?)?.toInt(),
    );
  }
}

typedef UrlTestResult = ({
  bool success,
  int? latencyMs,
  String error,
  int? httpStatus,
  UrlTestDiagnostics? diagnostics,
});

typedef UrlTestBatchResult = ({
  String id,
  bool success,
  int? latencyMs,
  String error,
  int? httpStatus,
  UrlTestDiagnostics? diagnostics,
});
