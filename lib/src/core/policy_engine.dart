import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart' hide PolicyRule, PolicyCondition;
// PolicyRule and PolicyCondition from io_policy_port conflict with
// names in models/policy.dart. Hide from barrel and import directly.
// ignore: implementation_imports
import 'package:mcp_bundle/src/ports/io_policy_port.dart'
    show PolicyRule, PolicyCondition;
import 'package:uuid/uuid.dart';

import '../models/actor_context.dart';
import '../models/configs.dart';
import '../models/plan_result.dart';

/// Internal rate limit tracker per scope.
class _RateLimitTracker {
  _RateLimitTracker({required this.maxCalls, required this.window});

  final int maxCalls;
  final Duration window;
  final List<DateTime> _callTimestamps = [];

  /// Check if the rate limit is exceeded.
  bool isExceeded(DateTime now) {
    _cleanup(now);
    return _callTimestamps.length >= maxCalls;
  }

  /// Record a call.
  void record(DateTime now) {
    _cleanup(now);
    _callTimestamps.add(now);
  }

  /// Remaining time until the rate limit window resets.
  Duration? remainingWindow(DateTime now) {
    _cleanup(now);
    if (_callTimestamps.isEmpty) return null;
    final oldest = _callTimestamps.first;
    final windowEnd = oldest.add(window);
    if (windowEnd.isAfter(now)) {
      return windowEnd.difference(now);
    }
    return null;
  }

  void _cleanup(DateTime now) {
    _callTimestamps.removeWhere(
      (ts) => now.difference(ts) > window,
    );
  }
}

/// Internal pending plan for Plan→Commit 2-phase execution.
class _PendingPlan {
  _PendingPlan({
    required this.planResult,
    required this.command,
    required this.actor,
    this.adapter,
  });

  final PlanResult planResult;
  final Command command;
  final ActorContext actor;

  /// Adapter captured at plan time so that `commitExecute` does not
  /// require the caller to re-resolve it.
  final IoDevicePort? adapter;
}

/// Function that evaluates an interlock rule against live device state.
///
/// Returns `true` when the interlock condition is satisfied (i.e. the
/// configured `action` should be applied — typically `deny`).
/// Returns `false` when the condition is not met, so execution may proceed.
///
/// IoRuntime is the canonical provider — it reads the interlock URI via
/// the adapter responsible for that resource and compares against the
/// condition operator.
typedef InterlockEvaluator = Future<bool> Function(Interlock interlock);

/// 6-stage policy evaluation engine.
///
/// Evaluates commands against policy rules through a pipeline:
/// 1. Rule Matching
/// 2. Authority Check
/// 3. Bounds Validation
/// 4. Rate Limit Check
/// 5. Interlock Evaluation
/// 6. Approval Check
///
/// Supports Plan→Commit 2-phase execution for dangerous commands.
class PolicyEngine {
  PolicyEngine({
    required IoPolicyPort ruleStore,
    PolicyEngineConfig? config,
    DateTime Function()? clock,
  })  : _ruleStore = ruleStore,
        _config = config ?? const PolicyEngineConfig.defaults(),
        _clock = clock ?? DateTime.now;

  /// Factory: create with default configuration.
  factory PolicyEngine.withDefaults({required IoPolicyPort ruleStore}) =>
      PolicyEngine(ruleStore: ruleStore);

  final IoPolicyPort _ruleStore;
  final PolicyEngineConfig _config;
  final DateTime Function() _clock;
  final Uuid _uuid = const Uuid();

  List<PolicyRule> _rules = [];
  final Map<String, _RateLimitTracker> _rateLimitTrackers = {};
  final Map<String, _PendingPlan> _pendingPlans = {};

  /// Initialize: load rules from rule store and sort by priority descending.
  Future<void> initialize() async {
    _rules = await _ruleStore.listRules();
    _rules.sort((a, b) {
      final aPriority = a.priority ?? 0;
      final bPriority = b.priority ?? 0;
      return bPriority.compareTo(aPriority);
    });
  }

  /// Reload rules from the rule store.
  Future<void> reloadRules() async {
    await initialize();
  }

  /// Evaluate a command against the policy rules.
  ///
  /// Returns a [PolicyDecision] indicating whether the command is
  /// allowed, denied, needs approval, or needs a plan.
  ///
  /// When [interlockEvaluator] is provided, Stage 5 reads the live device
  /// state through the evaluator and decides allow vs deny. When omitted,
  /// the engine falls back to the legacy behaviour of returning
  /// `needsApproval` so that the caller can perform out-of-band checks.
  Future<PolicyDecision> evaluate({
    required Command command,
    required ActorContext actor,
    required DeviceDescriptor device,
    InterlockEvaluator? interlockEvaluator,
  }) async {
    final now = _clock();
    final conditions = <ConditionEvaluation>[];

    // Stage 1: Rule Matching
    PolicyRule? matchedRule;
    for (final rule in _rules) {
      if (!rule.enabled) continue;

      final matches = _matchCondition(rule.when, command, actor, device);
      conditions.add(ConditionEvaluation(
        ruleId: rule.id,
        matched: matches,
        decision: matches ? (rule.allow ? Decision.allow : Decision.deny) : null,
      ));

      if (matches) {
        matchedRule = rule;
        break;
      }
    }

    // No matching rule: use default decision
    if (matchedRule == null) {
      return PolicyDecision(
        decision: _config.defaultDecision,
        notes: 'No matching rule found, using default decision',
      );
    }

    // Rule explicitly denies
    if (!matchedRule.allow) {
      return PolicyDecision(
        decision: Decision.deny,
        ruleId: matchedRule.id,
        notes: 'Denied by rule: ${matchedRule.name}',
      );
    }

    final constraints = matchedRule.constraints;
    if (constraints == null) {
      return PolicyDecision(
        decision: Decision.allow,
        ruleId: matchedRule.id,
        notes: 'Allowed by rule: ${matchedRule.name}',
      );
    }

    // Stage 3: Bounds Validation
    if (constraints.bounds != null) {
      for (final entry in constraints.bounds!.entries) {
        final argValue = command.args[entry.key];
        if (argValue is num) {
          final bound = entry.value;
          if (bound.min != null && argValue < bound.min!) {
            return PolicyDecision(
              decision: Decision.deny,
              ruleId: matchedRule.id,
              notes: 'Argument ${entry.key}=$argValue below minimum ${bound.min}',
            );
          }
          if (bound.max != null && argValue > bound.max!) {
            return PolicyDecision(
              decision: Decision.deny,
              ruleId: matchedRule.id,
              notes: 'Argument ${entry.key}=$argValue above maximum ${bound.max}',
            );
          }
        }
      }
    }

    // Stage 4: Rate Limit Check
    if (constraints.rateLimit != null) {
      final rateLimit = constraints.rateLimit!;
      final scope = '${matchedRule.id}:${command.action}:${command.target}';
      final tracker = _rateLimitTrackers.putIfAbsent(
        scope,
        () => _RateLimitTracker(
          maxCalls: rateLimit.maxCalls,
          window: rateLimit.window,
        ),
      );

      if (tracker.isExceeded(now)) {
        final remaining = tracker.remainingWindow(now);
        return PolicyDecision(
          decision: Decision.deny,
          ruleId: matchedRule.id,
          notes: 'Rate limited: max ${rateLimit.maxCalls} calls per '
              '${rateLimit.window.inSeconds}s. '
              '${remaining != null ? "Retry after ${remaining.inSeconds}s" : ""}',
        );
      }

      tracker.record(now);
    }

    // Stage 5: Interlock Evaluation
    if (constraints.interlocks != null) {
      for (final interlock in constraints.interlocks!) {
        if (interlockEvaluator != null) {
          final triggered = await interlockEvaluator(interlock);
          if (triggered) {
            if (interlock.action == InterlockAction.deny) {
              return PolicyDecision(
                decision: Decision.deny,
                ruleId: matchedRule.id,
                notes: 'Interlock blocked: ${interlock.uri} '
                    '(${interlock.condition.name})',
              );
            }
            // InterlockAction.warn: condition met but execution allowed.
            // Trace is captured in PolicyDecision.notes for audit purposes.
            // Continue evaluating remaining interlocks.
          }
        } else {
          // No evaluator wired — fall back to legacy behaviour so that
          // out-of-band approval flows still work.
          if (interlock.action == InterlockAction.deny) {
            return PolicyDecision(
              decision: Decision.needsApproval,
              ruleId: matchedRule.id,
              notes: 'Interlock check required for ${interlock.uri}',
            );
          }
        }
      }
    }

    // Stage 6: Approval Check
    if (constraints.requireApproval == true) {
      return PolicyDecision(
        decision: Decision.needsApproval,
        ruleId: matchedRule.id,
        notes: 'Explicit approval required by rule: ${matchedRule.name}',
      );
    }

    return PolicyDecision(
      decision: Decision.allow,
      ruleId: matchedRule.id,
      notes: 'Allowed by rule: ${matchedRule.name}',
    );
  }

  /// Plan evaluation (dry-run).
  ///
  /// Performs normal evaluation and stores a pending plan with expiry.
  /// When [adapter] is supplied it is captured in the pending plan so
  /// that `commitExecute` can route to the same adapter without the
  /// caller re-resolving it.
  Future<PlanResult> planEvaluate({
    required Command command,
    required ActorContext actor,
    required DeviceDescriptor device,
    InterlockEvaluator? interlockEvaluator,
    IoDevicePort? adapter,
  }) async {
    final decision = await evaluate(
      command: command,
      actor: actor,
      device: device,
      interlockEvaluator: interlockEvaluator,
    );

    final planId = _uuid.v4();
    final now = _clock();
    final expiry = now.add(_config.planExpiry);

    final riskLevel = _assessRisk(command, device);

    final planResult = PlanResult(
      planId: planId,
      riskAssessment: riskLevel,
      expiry: expiry,
      decision: decision.decision,
      command: command,
      policyTrace: PolicyTrace(
        commandId: '${command.action}:${command.target}',
        ruleId: decision.ruleId,
        evaluatedAt: now,
        finalDecision: decision.decision,
        finalNotes: decision.notes,
      ),
    );

    _pendingPlans[planId] = _PendingPlan(
      planResult: planResult,
      command: command,
      actor: actor,
      adapter: adapter,
    );

    return planResult;
  }

  /// Commit a previously planned execution.
  ///
  /// When the pending plan was created with an `adapter`, that adapter is
  /// used by default. Callers may still pass an explicit [adapter]
  /// override (e.g. wrapped/instrumented variants); when both are
  /// available, the explicit argument wins. When neither is provided a
  /// [StateError] is thrown.
  ///
  /// Throws [StateError] if plan is not found, expired, or no adapter
  /// is available.
  Future<CommandResult> commitExecute({
    required String planId,
    required String actorId,
    String? acknowledgment,
    IoDevicePort? adapter,
  }) async {
    final pending = _pendingPlans.remove(planId);
    if (pending == null) {
      throw StateError('policy.plan_not_found: plan $planId not found');
    }

    if (_clock().isAfter(pending.planResult.expiry)) {
      throw StateError(
        'policy.plan_expired: plan $planId has expired, re-planning required',
      );
    }

    // Verify actor authority
    if (pending.actor.actorId != actorId) {
      throw StateError(
        'policy.unauthorized: actor $actorId is not authorized for plan $planId',
      );
    }

    final resolvedAdapter = adapter ?? pending.adapter;
    if (resolvedAdapter == null) {
      throw StateError(
        'policy.adapter_unresolved: plan $planId has no adapter; supply '
        'one to planEvaluate or commitExecute',
      );
    }

    // Execute the command
    try {
      return await resolvedAdapter.execute(pending.command);
    } on Object catch (error) {
      return CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'exec.failed',
          message: 'Plan commit execution failed: $error',
          timestamp: _clock(),
        ),
      );
    }
  }

  /// Clean up expired plans and rate limit trackers.
  void cleanup() {
    // Remove expired plans
    _pendingPlans.removeWhere(
      (_, plan) => plan.planResult.isExpired,
    );

    // Cleanup rate limit trackers
    _rateLimitTrackers.removeWhere((_, tracker) {
      return tracker._callTimestamps.isEmpty;
    });
  }

  /// Match a policy condition against the command context.
  bool _matchCondition(
    PolicyCondition condition,
    Command command,
    ActorContext actor,
    DeviceDescriptor device,
  ) {
    // Action match
    if (condition.action != null) {
      final pattern = condition.action!;
      if (pattern.endsWith('*')) {
        final prefix = pattern.substring(0, pattern.length - 1);
        if (!command.action.startsWith(prefix)) return false;
      } else {
        if (command.action != pattern) return false;
      }
    }

    // Target prefix match
    if (condition.targetPrefix != null) {
      if (!command.target.startsWith(condition.targetPrefix!)) return false;
    }

    // Actor role match
    if (condition.actorRoleIn != null && condition.actorRoleIn!.isNotEmpty) {
      if (!condition.actorRoleIn!.contains(actor.role)) return false;
    }

    // Safety class match
    if (condition.safetyClass != null) {
      // Find the capability matching the command action
      final capability = device.capabilities.where(
        (c) => c.action == command.action,
      );
      if (capability.isNotEmpty &&
          capability.first.safetyClass != condition.safetyClass) {
        return false;
      }
    }

    // Transport match
    if (condition.transport != null) {
      if (device.transport != condition.transport) return false;
    }

    return true;
  }

  /// Assess risk level based on command and device context.
  Map<String, dynamic> _assessRisk(Command command, DeviceDescriptor device) {
    final capability = device.capabilities.where(
      (CapabilityDescriptor c) => c.action == command.action,
    );

    var level = 'UNKNOWN';
    if (capability.isNotEmpty) {
      switch (capability.first.safetyClass) {
        case SafetyClass.dangerous:
          level = 'HIGH';
        case SafetyClass.guarded:
          level = 'MEDIUM';
        case SafetyClass.safe:
          level = 'LOW';
      }
    }

    return <String, dynamic>{
      'level': level,
      'action': command.action,
      'target': command.target,
    };
  }

  /// Dispose resources.
  Future<void> dispose() async {
    _pendingPlans.clear();
    _rateLimitTrackers.clear();
  }
}
