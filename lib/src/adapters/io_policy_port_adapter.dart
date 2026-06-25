/// IoPolicyPortAdapter - In-memory implementation of mcp_bundle's IoPolicyPort.
///
/// Provides a fully functional rule store for PolicyEngine.
library;

import 'package:mcp_bundle/ports.dart';

/// In-memory implementation of [IoPolicyPort].
///
/// Stores policy rules in a [List] for [PolicyEngine] to consume.
class InMemoryIoPolicyPort implements IoPolicyPort {
  /// Create with optional initial rules.
  InMemoryIoPolicyPort({List<PolicyRule>? initialRules})
      : _rules = initialRules != null ? List.from(initialRules) : [];

  final List<PolicyRule> _rules;

  @override
  Future<List<PolicyRule>> listRules({
    String? deviceIdFilter,
    String? actionFilter,
  }) async {
    return _rules.where((rule) {
      if (deviceIdFilter != null &&
          rule.when.targetPrefix != null &&
          !rule.when.targetPrefix!.startsWith(deviceIdFilter)) {
        return false;
      }
      if (actionFilter != null &&
          rule.when.action != null &&
          !rule.when.action!.startsWith(actionFilter)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Future<void> addRule(PolicyRule rule) async {
    _rules.add(rule);
  }

  @override
  Future<void> updateRule(PolicyRule rule) async {
    final index = _rules.indexWhere((r) => r.id == rule.id);
    if (index >= 0) {
      _rules[index] = rule;
    } else {
      throw StateError('Rule not found: ${rule.id}');
    }
  }

  @override
  Future<void> removeRule(String ruleId) async {
    _rules.removeWhere((r) => r.id == ruleId);
  }
}
