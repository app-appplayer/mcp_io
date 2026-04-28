import 'package:mcp_bundle/mcp_bundle.dart';

/// Result of a Plan evaluation (dry-run) for Plan/Commit 2-phase execution.
class PlanResult {
  const PlanResult({
    required this.planId,
    this.riskAssessment,
    required this.expiry,
    required this.decision,
    required this.command,
    this.policyTrace,
  });

  /// Create from JSON.
  factory PlanResult.fromJson(Map<String, dynamic> json) {
    return PlanResult(
      planId: json['planId'] as String,
      riskAssessment: json['riskAssessment'] as Map<String, dynamic>?,
      expiry: DateTime.parse(json['expiry'] as String),
      decision: Decision.fromString(json['decision'] as String),
      command: Command.fromJson(json['command'] as Map<String, dynamic>),
      policyTrace: json['policyTrace'] != null
          ? PolicyTrace.fromJson(json['policyTrace'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Unique identifier for this plan.
  final String planId;

  /// Risk assessment generated during evaluation.
  final Map<String, dynamic>? riskAssessment;

  /// When this plan expires (must commit before this time).
  final DateTime expiry;

  /// Policy decision for the planned command.
  final Decision decision;

  /// The command that was evaluated.
  final Command command;

  /// Policy trace from evaluation.
  final PolicyTrace? policyTrace;

  /// Whether this plan has expired.
  bool get isExpired => DateTime.now().isAfter(expiry);

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        'planId': planId,
        if (riskAssessment != null) 'riskAssessment': riskAssessment,
        'expiry': expiry.toIso8601String(),
        'decision': decision.name,
        'command': command.toJson(),
        if (policyTrace != null) 'policyTrace': policyTrace!.toJson(),
      };
}
