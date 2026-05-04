import 'package:mcp_bundle/mcp_bundle.dart' hide PolicyRule, PolicyCondition;
// ignore: implementation_imports
import 'package:mcp_bundle/src/ports/io_policy_port.dart'
    show PolicyRule, PolicyCondition, PolicyConstraints, Bound, RateLimit,
    StubIoPolicyPort;
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

DeviceDescriptor _device({
  String id = 'dev-1',
  String transport = 'tcp',
  List<CapabilityDescriptor> capabilities = const [],
}) =>
    DeviceDescriptor(
      deviceId: id,
      manufacturer: 'Test',
      model: 'M',
      transport: transport,
      capabilities: capabilities,
    );

ActorContext _actor({String id = 'actor-1', String role = 'operator'}) =>
    ActorContext(actorId: id, role: role);

void main() {
  late StubIoPolicyPort ruleStore;
  late PolicyEngine engine;
  late DateTime currentTime;

  DateTime clock() => currentTime;

  setUp(() async {
    currentTime = DateTime(2025, 1, 1, 12, 0);
    ruleStore = StubIoPolicyPort();
    engine = PolicyEngine(
      ruleStore: ruleStore,
      config: const PolicyEngineConfig(
        defaultDecision: Decision.deny,
        planExpiry: Duration(minutes: 5),
      ),
      clock: clock,
    );
  });

  tearDown(() async {
    await engine.dispose();
  });

  group('PolicyEngine - Rule Matching', () {
    test('TC-023 [normal] Allow safe action by rule', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-1',
        name: 'Allow read',
        when: PolicyCondition(action: 'read'),
        allow: true,
        priority: 10,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
      expect(decision.ruleId, 'rule-1');
    });

    test('TC-024 [normal] Deny action by rule', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-deny',
        name: 'Deny write',
        when: PolicyCondition(action: 'write'),
        allow: false,
        priority: 10,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'write', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
    });

    test('TC-025 [normal] No matching rule uses default decision', () async {
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'unknown', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('No matching rule'));
    });

    test('TC-026 [normal] Wildcard action matching', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-wild',
        name: 'Allow set*',
        when: PolicyCondition(action: 'set*'),
        allow: true,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command:
            const Command(action: 'setVoltage', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-027 [normal] Target prefix matching', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-prefix',
        name: 'Allow dev-1',
        when: PolicyCondition(targetPrefix: 'io://dev-1'),
        allow: true,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-028 [normal] Actor role matching', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-role',
        name: 'Allow operators',
        when: PolicyCondition(actorRoleIn: ['operator', 'admin']),
        allow: true,
      ));
      await engine.initialize();

      final allowed = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(role: 'operator'),
        device: _device(),
      );
      expect(allowed.decision, Decision.allow);

      final denied = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(role: 'viewer'),
        device: _device(),
      );
      expect(denied.decision, Decision.deny);
    });

    test('TC-029 [normal] Higher priority rules evaluated first', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-low',
        name: 'Deny all',
        when: PolicyCondition(action: 'read'),
        allow: false,
        priority: 1,
      ));
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-high',
        name: 'Allow all',
        when: PolicyCondition(action: 'read'),
        allow: true,
        priority: 100,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
      expect(decision.ruleId, 'rule-high');
    });

    test('TC-030 [boundary] Disabled rule is skipped', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-disabled',
        name: 'Disabled rule',
        when: PolicyCondition(action: 'read'),
        allow: true,
        enabled: false,
        priority: 100,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
    });
  });

  group('PolicyEngine - Bounds Validation', () {
    test('TC-031 [normal] Allow within bounds', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-bounds',
        name: 'Bounded set',
        when: PolicyCondition(action: 'setVoltage'),
        allow: true,
        constraints: PolicyConstraints(
          bounds: {'value': Bound(min: 0.0, max: 10.0)},
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'setVoltage',
          target: 'io://dev-1/ch/1',
          args: {'value': 5.0},
        ),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-032 [error] Deny below minimum bound', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-bounds',
        name: 'Bounded set',
        when: PolicyCondition(action: 'setVoltage'),
        allow: true,
        constraints: PolicyConstraints(
          bounds: {'value': Bound(min: 0.0, max: 10.0)},
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'setVoltage',
          target: 'io://dev-1/ch/1',
          args: {'value': -1.0},
        ),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('below minimum'));
    });

    test('TC-033 [error] Deny above maximum bound', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-bounds',
        name: 'Bounded set',
        when: PolicyCondition(action: 'setVoltage'),
        allow: true,
        constraints: PolicyConstraints(
          bounds: {'value': Bound(min: 0.0, max: 10.0)},
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'setVoltage',
          target: 'io://dev-1/ch/1',
          args: {'value': 15.0},
        ),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('above maximum'));
    });
  });

  group('PolicyEngine - Rate Limiting', () {
    test('TC-034 [normal] Allow under rate limit', () async {
      await ruleStore.addRule(PolicyRule(
        id: 'rule-rate',
        name: 'Rate limited',
        when: const PolicyCondition(action: 'measure'),
        allow: true,
        constraints: PolicyConstraints(
          rateLimit: RateLimit(maxCalls: 3, window: const Duration(seconds: 60)),
        ),
      ));
      await engine.initialize();

      for (var i = 0; i < 3; i++) {
        final decision = await engine.evaluate(
          command: const Command(
            action: 'measure',
            target: 'io://dev-1/ch/1',
          ),
          actor: _actor(),
          device: _device(),
        );
        expect(decision.decision, Decision.allow);
      }
    });

    test('TC-035 [error] Deny when rate limit exceeded', () async {
      await ruleStore.addRule(PolicyRule(
        id: 'rule-rate',
        name: 'Rate limited',
        when: const PolicyCondition(action: 'measure'),
        allow: true,
        constraints: PolicyConstraints(
          rateLimit: RateLimit(maxCalls: 2, window: const Duration(seconds: 60)),
        ),
      ));
      await engine.initialize();

      // Exhaust rate limit
      await engine.evaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );
      await engine.evaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      // Third should be denied
      final decision = await engine.evaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('Rate limited'));
    });
  });

  group('PolicyEngine - Approval', () {
    test('TC-036 [normal] RequireApproval returns needsApproval', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-approval',
        name: 'Needs approval',
        when: PolicyCondition(action: 'dangerousOp'),
        allow: true,
        constraints: PolicyConstraints(requireApproval: true),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command:
            const Command(action: 'dangerousOp', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.needsApproval);
    });
  });

  group('PolicyEngine - Plan/Commit', () {
    test('TC-037 [normal] PlanEvaluate creates plan', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(plan.planId, isNotEmpty);
      expect(plan.decision, Decision.allow);
      expect(plan.command.action, 'measure');
      expect(plan.policyTrace, isNotNull);
    });

    test('TC-038 [error] CommitExecute with non-existent plan throws',
        () async {
      await engine.initialize();

      expect(
        () => engine.commitExecute(
          planId: 'nonexistent',
          actorId: 'actor-1',
          adapter: _StubDevicePort(),
        ),
        throwsStateError,
      );
    });

    test('TC-039 [error] CommitExecute with expired plan throws', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      // Advance past expiry
      currentTime = currentTime.add(const Duration(minutes: 10));

      expect(
        () => engine.commitExecute(
          planId: plan.planId,
          actorId: 'actor-1',
          adapter: _StubDevicePort(),
        ),
        throwsStateError,
      );
    });

    test('TC-040 [error] CommitExecute with wrong actor throws', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(id: 'actor-1'),
        device: _device(),
      );

      expect(
        () => engine.commitExecute(
          planId: plan.planId,
          actorId: 'wrong-actor',
          adapter: _StubDevicePort(),
        ),
        throwsStateError,
      );
    });
  });

  group('PolicyEngine - Interlock Evaluator', () {
    test('TC-INT-001 [normal] Evaluator triggered → deny', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow with interlock',
        when: PolicyCondition(action: 'write_register'),
        allow: true,
        constraints: PolicyConstraints(
          interlocks: [
            Interlock(
              uri: 'io://dev-1/coil/1/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.deny,
            ),
          ],
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'write_register',
          target: 'io://dev-1/reg/holding/40010/value',
        ),
        actor: _actor(),
        device: _device(),
        interlockEvaluator: (_) async => true, // 조건 매칭
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('Interlock blocked'));
      expect(decision.notes, contains('isTrue'));
    });

    test('TC-INT-002 [normal] Evaluator not triggered → allow', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow with interlock',
        when: PolicyCondition(action: 'write_register'),
        allow: true,
        constraints: PolicyConstraints(
          interlocks: [
            Interlock(
              uri: 'io://dev-1/coil/1/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.deny,
            ),
          ],
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'write_register',
          target: 'io://dev-1/reg/holding/40010/value',
        ),
        actor: _actor(),
        device: _device(),
        interlockEvaluator: (_) async => false, // 조건 미충족
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-INT-003 [legacy] No evaluator → needsApproval', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow with interlock',
        when: PolicyCondition(action: 'write_register'),
        allow: true,
        constraints: PolicyConstraints(
          interlocks: [
            Interlock(
              uri: 'io://dev-1/coil/1/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.deny,
            ),
          ],
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'write_register',
          target: 'io://dev-1/reg/holding/40010/value',
        ),
        actor: _actor(),
        device: _device(),
        // evaluator 미주입 — legacy 동작
      );

      expect(decision.decision, Decision.needsApproval);
      expect(decision.notes, contains('Interlock check required'));
    });

    test('TC-INT-004 [normal] Warn action 가 통과 시키되 계속 평가', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow with warn interlock',
        when: PolicyCondition(action: 'write_register'),
        allow: true,
        constraints: PolicyConstraints(
          interlocks: [
            Interlock(
              uri: 'io://dev-1/coil/1/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.warn,
            ),
          ],
        ),
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'write_register',
          target: 'io://dev-1/reg/holding/40010/value',
        ),
        actor: _actor(),
        device: _device(),
        interlockEvaluator: (_) async => true,
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-INT-005 [normal] 다중 interlock 중 하나만 trigger 면 deny',
        () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow with multi interlock',
        when: PolicyCondition(action: 'write_register'),
        allow: true,
        constraints: PolicyConstraints(
          interlocks: [
            Interlock(
              uri: 'io://dev-1/coil/1/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.deny,
            ),
            Interlock(
              uri: 'io://dev-1/coil/2/value',
              condition: InterlockCondition.isTrue,
              action: InterlockAction.deny,
            ),
          ],
        ),
      ));
      await engine.initialize();

      var callCount = 0;
      final decision = await engine.evaluate(
        command: const Command(
          action: 'write_register',
          target: 'io://dev-1/reg/holding/40010/value',
        ),
        actor: _actor(),
        device: _device(),
        interlockEvaluator: (interlock) async {
          callCount++;
          // 두 번째 interlock 만 trigger
          return interlock.uri.endsWith('/coil/2/value');
        },
      );

      expect(decision.decision, Decision.deny);
      expect(decision.notes, contains('coil/2'));
      // 첫 interlock 통과 후 두 번째에서 멈춤
      expect(callCount, 2);
    });
  });

  group('PolicyEngine - Adapter Routing (Plan/Commit)', () {
    test('TC-ROUTE-001 [normal] PlanEvaluate 가 adapter 캡처 → CommitExecute 자동 사용',
        () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final adapter = _StubDevicePort();
      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
        adapter: adapter,
      );

      // adapter 안 줘도 OK — pending plan 의 것 사용
      final result = await engine.commitExecute(
        planId: plan.planId,
        actorId: 'actor-1',
      );

      expect(result.status, CommandStatus.completed);
    });

    test('TC-ROUTE-002 [normal] CommitExecute 의 explicit adapter 가 override',
        () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final original = _StubDevicePort();
      final override = _CountingDevicePort();

      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
        adapter: original,
      );

      final result = await engine.commitExecute(
        planId: plan.planId,
        actorId: 'actor-1',
        adapter: override,
      );

      expect(result.status, CommandStatus.completed);
      expect(override.executeCalls, 1);
    });

    test('TC-ROUTE-003 [error] adapter 없으면 throw', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      final plan = await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
        // adapter 미주입
      );

      expect(
        () => engine.commitExecute(
          planId: plan.planId,
          actorId: 'actor-1',
        ),
        throwsStateError,
      );
    });
  });

  group('PolicyEngine - Reload & Cleanup', () {
    test('TC-041 [normal] ReloadRules updates rule cache', () async {
      await engine.initialize();

      await ruleStore.addRule(const PolicyRule(
        id: 'new-rule',
        name: 'New rule',
        when: PolicyCondition(action: 'newAction'),
        allow: true,
      ));
      await engine.reloadRules();

      final decision = await engine.evaluate(
        command:
            const Command(action: 'newAction', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
    });

    test('TC-042 [normal] Cleanup removes expired plans', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'measure'),
        allow: true,
      ));
      await engine.initialize();

      await engine.planEvaluate(
        command: const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      // Advance time and cleanup
      currentTime = currentTime.add(const Duration(minutes: 10));
      engine.cleanup();

      // Plan should be gone — no error on cleanup
    });
  });

  group('PolicyEngine - Integration', () {
    test('IT-004 Full 6-stage pipeline evaluation', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'rule-1',
        name: 'Allow bounded measure',
        when: PolicyCondition(
          action: 'measure',
          actorRoleIn: ['operator'],
        ),
        allow: true,
        constraints: PolicyConstraints(
          bounds: {'frequency': Bound(min: 1.0, max: 1000.0)},
        ),
        priority: 10,
      ));
      await engine.initialize();

      final decision = await engine.evaluate(
        command: const Command(
          action: 'measure',
          target: 'io://dev-1/ch/1',
          args: {'frequency': 500.0},
        ),
        actor: _actor(role: 'operator'),
        device: _device(),
      );

      expect(decision.decision, Decision.allow);
    });

    test('IT-005 Plan → commit flow', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'r1',
        name: 'Allow',
        when: PolicyCondition(action: 'calibrate'),
        allow: true,
      ));
      await engine.initialize();

      final plan = await engine.planEvaluate(
        command:
            const Command(action: 'calibrate', target: 'io://dev-1/ch/1'),
        actor: _actor(),
        device: _device(),
      );

      expect(plan.decision, Decision.allow);
      expect(plan.riskAssessment, isNotNull);

      final result = await engine.commitExecute(
        planId: plan.planId,
        actorId: 'actor-1',
        adapter: _StubDevicePort(),
      );

      expect(result.status, CommandStatus.completed);
    });

    test('IT-006 Priority ordering with multiple rules', () async {
      await ruleStore.addRule(const PolicyRule(
        id: 'deny-all',
        name: 'Deny all',
        when: PolicyCondition(action: 'read'),
        allow: false,
        priority: 1,
      ));
      await ruleStore.addRule(const PolicyRule(
        id: 'allow-operators',
        name: 'Allow operators',
        when: PolicyCondition(
          action: 'read',
          actorRoleIn: ['operator'],
        ),
        allow: true,
        priority: 50,
      ));
      await engine.initialize();

      final opDecision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(role: 'operator'),
        device: _device(),
      );
      expect(opDecision.decision, Decision.allow);

      final viewerDecision = await engine.evaluate(
        command: const Command(action: 'read', target: 'io://dev-1/ch/1'),
        actor: _actor(role: 'viewer'),
        device: _device(),
      );
      expect(viewerDecision.decision, Decision.deny);
    });
  });
}

/// Stub device port for plan commit tests.
class _StubDevicePort implements IoDevicePort {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<DeviceDescriptor> describe() async => const DeviceDescriptor(
        deviceId: 'dev-1',
        manufacturer: 'T',
        model: 'M',
        transport: 'tcp',
      );
  @override
  Future<ReadResult> read(ReadSpec spec) async => const ReadResult();
  @override
  Future<CommandResult> execute(Command command) async =>
      CommandResult(status: CommandStatus.completed);
  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => const Stream.empty();
  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async =>
      const EmergencyStopResult(success: true);
}

/// Counting variant — used to verify which adapter actually executed.
class _CountingDevicePort implements IoDevicePort {
  int executeCalls = 0;

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<DeviceDescriptor> describe() async => const DeviceDescriptor(
        deviceId: 'dev-1',
        manufacturer: 'T',
        model: 'M',
        transport: 'tcp',
      );
  @override
  Future<ReadResult> read(ReadSpec spec) async => const ReadResult();
  @override
  Future<CommandResult> execute(Command command) async {
    executeCalls++;
    return CommandResult(status: CommandStatus.completed);
  }
  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => const Stream.empty();
  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async =>
      const EmergencyStopResult(success: true);
}
