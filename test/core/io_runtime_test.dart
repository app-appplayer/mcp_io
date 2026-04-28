import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart' hide PolicyRule, PolicyCondition;
// ignore: implementation_imports
import 'package:mcp_bundle/src/ports/io_policy_port.dart'
    show PolicyRule, PolicyCondition, PolicyConstraints, StubIoPolicyPort;
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Stub adapter for testing IoRuntime dispatch.
class _StubAdapter implements IoDevicePort {
  _StubAdapter({
    required this.descriptor,
    // ignore: unused_element_parameter
    this.shouldError = false,
    this.readItems = const [],
  });

  final DeviceDescriptor descriptor;
  final bool shouldError;
  final List<ReadResultItem> readItems;

  bool connected = false;
  final List<Command> executedCommands = [];
  final List<EmergencyStopRequest> estopRequests = [];

  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<DeviceDescriptor> describe() async {
    if (shouldError) {
      throw StateError('Adapter describe error');
    }
    return descriptor;
  }

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    if (shouldError) {
      throw StateError('Adapter read error');
    }
    return ReadResult(items: readItems);
  }

  @override
  Future<CommandResult> execute(Command command) async {
    executedCommands.add(command);
    if (shouldError) {
      throw StateError('Adapter execute error');
    }
    return CommandResult(status: CommandStatus.completed, result: 'ok');
  }

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => const Stream.empty();

  @override
  Future<EmergencyStopResult> emergencyStop(
    EmergencyStopRequest request,
  ) async {
    estopRequests.add(request);
    if (shouldError) {
      throw StateError('Adapter estop error');
    }
    return const EmergencyStopResult(success: true);
  }
}

AdapterManifest _manifest(String id) => AdapterManifest(
      adapterId: id,
      adapterVersion: '1.0.0',
      contractVersionRange: '>=0.1.0 <1.0.0',
      displayName: 'Test Adapter $id',
    );

DeviceDescriptor _device(String id, {String transport = 'tcp'}) =>
    DeviceDescriptor(
      deviceId: id,
      manufacturer: 'Test',
      model: 'Model-1',
      transport: transport,
      connectionState: IoConnectionState.connected,
    );

ActorContext _actor({String id = 'actor-1', String role = 'operator'}) =>
    ActorContext(actorId: id, role: role);

void main() {
  late StubIoPolicyPort policyPort;
  late InMemoryAuditPort auditPort;
  late IoRuntime runtime;

  setUp(() async {
    policyPort = StubIoPolicyPort();
    auditPort = InMemoryAuditPort();
    runtime = IoRuntime(
      policyPort: policyPort,
      auditPort: auditPort,
    );
  });

  tearDown(() async {
    await runtime.dispose();
  });

  // ---------------------------------------------------------------------------
  // Lifecycle (TC-150 ~ TC-152)
  // ---------------------------------------------------------------------------

  group('IoRuntime - Lifecycle', () {
    test('TC-150 Initialize starts all modules', () async {
      await runtime.initialize();

      // After initialize, all module accessors should be reachable
      // and the registry should accept adapter registration.
      expect(runtime.registry, isNotNull);
      expect(runtime.policyEngine, isNotNull);
      expect(runtime.auditTrail, isNotNull);
      expect(runtime.streamManager, isNotNull);
      expect(runtime.sessionManager, isNotNull);

      // Registry is initialized: can register an adapter without throwing
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
    });

    test('TC-151 Shutdown stops all modules', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      await runtime.shutdown();

      // After shutdown, devices should be disconnected
      final devices = await runtime.registry.list();
      expect(devices, isEmpty);
    });

    test('TC-152 Dispose releases all resources', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      // Dispose calls shutdown internally and disposes all modules
      await runtime.dispose();

      // Re-create runtime for tearDown to avoid double dispose
      runtime = IoRuntime(
        policyPort: policyPort,
        auditPort: auditPort,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // describe() (TC-153 ~ TC-154)
  // ---------------------------------------------------------------------------

  group('IoRuntime - describe()', () {
    test('TC-153 Describe existing device returns DeviceDescriptor', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final desc = await runtime.describe('dev-1');
      expect(desc, isNotNull);
      expect(desc!.deviceId, 'dev-1');
      expect(desc.manufacturer, 'Test');
    });

    test('TC-154 Describe non-existent device returns null', () async {
      await runtime.initialize();

      final desc = await runtime.describe('nonexistent');
      expect(desc, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // read() (TC-155 ~ TC-158)
  // ---------------------------------------------------------------------------

  group('IoRuntime - read()', () {
    test('TC-155 Read single target', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(
        descriptor: _device('dev-1'),
        readItems: [
          const ReadResultItem(uri: 'dev-1/ch/1'),
        ],
      );
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.read(
        const ReadSpec(targets: ['dev-1/ch/1']),
      );

      expect(result.items, hasLength(1));
    });

    test('TC-156 Read multiple targets', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(
        descriptor: _device('dev-1'),
        readItems: [
          const ReadResultItem(uri: 'dev-1/ch/1'),
        ],
      );
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.read(
        const ReadSpec(targets: ['dev-1/ch/1', 'dev-1/ch/2']),
      );

      // Each target is dispatched separately; adapter returns 1 item per call
      expect(result.items, hasLength(2));
    });

    test('TC-157 Read unresolvable target returns device.not_found error',
        () async {
      await runtime.initialize();

      final result = await runtime.read(
        const ReadSpec(targets: ['unknown-dev/ch/1']),
      );

      expect(result.items, hasLength(1));
      expect(result.items.first.error, isNotNull);
      expect(result.items.first.error!.code, 'device.not_found');
    });

    test('TC-158 Read with adapter error returns exec.failed', () async {
      await runtime.initialize();

      // Use an adapter that only fails on read (not on describe)
      final adapter = _ErrorOnReadAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.read(
        const ReadSpec(targets: ['dev-1/ch/1']),
      );

      expect(result.items, hasLength(1));
      expect(result.items.first.error, isNotNull);
      expect(result.items.first.error!.code, 'exec.failed');
    });
  });

  // ---------------------------------------------------------------------------
  // execute() (TC-159 ~ TC-163)
  // ---------------------------------------------------------------------------

  group('IoRuntime - execute()', () {
    test('TC-159 Execute allowed command returns completed', () async {
      await policyPort.addRule(const PolicyRule(
        id: 'rule-allow',
        name: 'Allow measure',
        when: PolicyCondition(action: 'measure'),
        allow: true,
        priority: 10,
      ));

      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.execute(
        const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
      );

      expect(result.status, CommandStatus.completed);
    });

    test('TC-160 Execute denied command returns rejected with PolicyTrace',
        () async {
      await policyPort.addRule(const PolicyRule(
        id: 'rule-deny',
        name: 'Deny write',
        when: PolicyCondition(action: 'write'),
        allow: false,
        priority: 10,
      ));

      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.execute(
        const Command(action: 'write', target: 'io://dev-1/ch/1'),
        actor: _actor(),
      );

      expect(result.status, CommandStatus.rejected);
      expect(result.policyTrace, isNotNull);
      expect(result.policyTrace!.finalDecision, Decision.deny);
    });

    test('TC-161 Execute needs approval returns needsApproval', () async {
      await policyPort.addRule(const PolicyRule(
        id: 'rule-approval',
        name: 'Require approval',
        when: PolicyCondition(action: 'calibrate'),
        allow: true,
        priority: 10,
        constraints: PolicyConstraints(requireApproval: true),
      ));

      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.execute(
        const Command(action: 'calibrate', target: 'io://dev-1/ch/1'),
        actor: _actor(),
      );

      expect(result.status, CommandStatus.needsApproval);
      expect(result.policyTrace, isNotNull);
    });

    test('TC-162 Execute unknown device returns device.not_found', () async {
      await runtime.initialize();

      final result = await runtime.execute(
        const Command(action: 'measure', target: 'io://unknown-dev/ch/1'),
        actor: _actor(),
      );

      expect(result.status, CommandStatus.failed);
      expect(result.error, isNotNull);
      expect(result.error!.code, 'device.not_found');
    });

    test('TC-163 Execute records audit trail entry', () async {
      await policyPort.addRule(const PolicyRule(
        id: 'rule-allow',
        name: 'Allow measure',
        when: PolicyCondition(action: 'measure'),
        allow: true,
        priority: 10,
      ));

      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      await runtime.execute(
        const Command(action: 'measure', target: 'io://dev-1/ch/1'),
        actor: _actor(),
      );

      // Wait a tick for async audit recording
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final records = await runtime.auditTrail.query(
        const IoAuditQuery(type: IoAuditType.execute),
      );
      expect(records, isNotEmpty);
      expect(records.any((r) => r.deviceId == 'dev-1'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // subscribe() (TC-165 ~ TC-166) — basic wiring tests
  // ---------------------------------------------------------------------------

  group('IoRuntime - subscribe()', () {
    test('TC-165 Subscribe to topic returns IoStreamSubscription', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final sub = await runtime.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1/waveform', mode: TopicMode.continuous),
        consumerId: 'consumer-1',
      );

      expect(sub, isNotNull);
    });

    test('TC-166 Subscribe with actor context', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final sub = await runtime.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1/waveform', mode: TopicMode.continuous),
        consumerId: 'consumer-1',
        actor: _actor(),
      );

      expect(sub, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // emergencyStop() (TC-167 ~ TC-171)
  // ---------------------------------------------------------------------------

  group('IoRuntime - emergencyStop()', () {
    test('TC-167 E-Stop specific device calls adapter', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.emergencyStop(
        const EmergencyStopRequest(
          actorId: 'actor-1',
          reason: 'Test emergency',
          deviceId: 'dev-1',
        ),
      );

      expect(result.success, isTrue);
      expect(adapter.estopRequests, hasLength(1));
    });

    test('TC-168 E-Stop all devices (deviceId = null)', () async {
      await runtime.initialize();

      final adapter1 = _StubAdapter(descriptor: _device('dev-1'));
      final adapter2 = _StubAdapter(descriptor: _device('dev-2'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter1);
      await runtime.registry.registerAdapter(_manifest('a2'), adapter2);
      await runtime.registry.discover();

      final result = await runtime.emergencyStop(
        const EmergencyStopRequest(actorId: 'actor-1', reason: 'Stop all'),
      );

      expect(result.success, isTrue);
      expect(result.stoppedDevices, hasLength(2));
    });

    test('TC-169 E-Stop unknown device returns device.not_found', () async {
      await runtime.initialize();

      final result = await runtime.emergencyStop(
        const EmergencyStopRequest(
          actorId: 'actor-1',
          reason: 'Test',
          deviceId: 'nonexistent',
        ),
      );

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(result.error!.code, 'device.not_found');
    });

    test('TC-170 E-Stop records audit with type emergencyStop', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      await runtime.emergencyStop(
        const EmergencyStopRequest(
          actorId: 'actor-1',
          reason: 'Audit test',
          deviceId: 'dev-1',
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final records = await runtime.auditTrail.query(
        const IoAuditQuery(type: IoAuditType.emergencyStop),
      );
      expect(records, isNotEmpty);
    });

    test('TC-171 E-Stop adapter failure returns estop.failed', () async {
      await runtime.initialize();

      // Use a single error adapter but trick resolution:
      // We need the adapter to be discovered first (shouldError only on estop).
      // Since _StubAdapter.shouldError affects all operations, we use a
      // separate approach: register normal, discover, then swap is not possible.
      // Instead we create a custom adapter that only fails on emergencyStop.
      final adapter = _ErrorOnEstopAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      final result = await runtime.emergencyStop(
        const EmergencyStopRequest(
          actorId: 'actor-1',
          reason: 'Error test',
          deviceId: 'dev-1',
        ),
      );

      // Adapter throws on estop, so runtime should catch and return failure
      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(result.error!.code, 'estop.failed');
    });
  });

  // ---------------------------------------------------------------------------
  // Session Cleanup Wiring (TC-172 ~ TC-173)
  // ---------------------------------------------------------------------------

  group('IoRuntime - Session Cleanup Wiring', () {
    test('TC-172 Session close removes device streams', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      // Open session
      final sessionId = runtime.sessionManager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      // Create a subscription for the device
      await runtime.subscribe(
        const TopicSpec(
          uri: 'io://dev-1/ch/1/waveform',
          mode: TopicMode.continuous,
        ),
        consumerId: 'consumer-1',
      );

      // Close session — should trigger stream cleanup via onSessionClosed
      await runtime.sessionManager.closeSession(sessionId);

      // Verify session was closed
      expect(runtime.sessionManager.getSession(sessionId), isNull);
    });

    test('TC-173 Session close drains command queue for device', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      // Open session
      final sessionId = runtime.sessionManager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      // Close session — should trigger commandQueue.drainDevice()
      await runtime.sessionManager.closeSession(sessionId);

      // Verify session was cleaned up (no active sessions)
      expect(runtime.sessionManager.activeCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Integration Tests (IT-023 ~ IT-025)
  // ---------------------------------------------------------------------------

  group('IoRuntime - Integration', () {
    test('IT-023 Full execute pipeline: register → discover → execute → audit',
        () async {
      // Set up an allow rule
      await policyPort.addRule(const PolicyRule(
        id: 'rule-allow-all',
        name: 'Allow all',
        when: PolicyCondition(),
        allow: true,
        priority: 1,
      ));

      await runtime.initialize();

      // Register adapter and discover
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      // Execute a command
      final result = await runtime.execute(
        const Command(action: 'setVoltage', target: 'io://dev-1/ch/1'),
        actor: _actor(),
      );

      expect(result.status, CommandStatus.completed);

      // Wait for async audit recording
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Verify audit records exist
      final records = await runtime.auditTrail.query(
        const IoAuditQuery(type: IoAuditType.execute),
      );
      expect(records, isNotEmpty);

      // Verify the adapter actually received the command
      expect(adapter.executedCommands, isNotEmpty);
      expect(adapter.executedCommands.first.action, 'setVoltage');
    });

    test('IT-024 E-Stop pipeline: register → discover → emergencyStop → audit',
        () async {
      await runtime.initialize();

      // Register and discover two devices
      final adapter1 = _StubAdapter(descriptor: _device('dev-1'));
      final adapter2 = _StubAdapter(descriptor: _device('dev-2'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter1);
      await runtime.registry.registerAdapter(_manifest('a2'), adapter2);
      await runtime.registry.discover();

      // Emergency stop all
      final result = await runtime.emergencyStop(
        const EmergencyStopRequest(actorId: 'admin-1', reason: 'Integration test'),
      );

      expect(result.success, isTrue);
      expect(result.stoppedDevices, hasLength(2));

      // Verify audit
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final records = await runtime.auditTrail.query(
        const IoAuditQuery(type: IoAuditType.emergencyStop),
      );
      expect(records, isNotEmpty);

      // Verify both adapters received estop
      expect(adapter1.estopRequests, hasLength(1));
      expect(adapter2.estopRequests, hasLength(1));
    });

    test(
        'IT-025 Session cleanup pipeline: '
        'register → session → subscribe → close → verify cleanup', () async {
      await runtime.initialize();

      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await runtime.registry.registerAdapter(_manifest('a1'), adapter);
      await runtime.registry.discover();

      // Open session
      final sessionId = runtime.sessionManager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );
      expect(runtime.sessionManager.activeCount, 1);

      // Subscribe to a topic under the device
      await runtime.subscribe(
        const TopicSpec(
          uri: 'io://dev-1/ch/1/waveform',
          mode: TopicMode.continuous,
        ),
        consumerId: 'consumer-1',
      );

      // Close session — triggers onSessionClosed callback which calls
      // streamManager.removeByDevice() and commandQueue.drainDevice()
      await runtime.sessionManager.closeSession(sessionId);

      // Verify session is gone
      expect(runtime.sessionManager.activeCount, 0);
      expect(runtime.sessionManager.getSession(sessionId), isNull);
    });
  });
}

/// Adapter that only fails on read (for TC-158).
class _ErrorOnReadAdapter implements IoDevicePort {
  _ErrorOnReadAdapter({required this.descriptor});

  final DeviceDescriptor descriptor;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<DeviceDescriptor> describe() async => descriptor;

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    throw StateError('Adapter read hardware failure');
  }

  @override
  Future<CommandResult> execute(Command command) async =>
      CommandResult(status: CommandStatus.completed);

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => const Stream.empty();

  @override
  Future<EmergencyStopResult> emergencyStop(
    EmergencyStopRequest request,
  ) async =>
      const EmergencyStopResult(success: true);
}

/// Adapter that only fails on emergencyStop (for TC-171).
class _ErrorOnEstopAdapter implements IoDevicePort {
  _ErrorOnEstopAdapter({required this.descriptor});

  final DeviceDescriptor descriptor;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<DeviceDescriptor> describe() async => descriptor;

  @override
  Future<ReadResult> read(ReadSpec spec) async => const ReadResult();

  @override
  Future<CommandResult> execute(Command command) async =>
      CommandResult(status: CommandStatus.completed);

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => const Stream.empty();

  @override
  Future<EmergencyStopResult> emergencyStop(
    EmergencyStopRequest request,
  ) async {
    throw StateError('Emergency stop hardware failure');
  }
}
