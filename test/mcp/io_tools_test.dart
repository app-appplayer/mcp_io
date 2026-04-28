import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart' hide PolicyRule, PolicyCondition;
// ignore: implementation_imports
import 'package:mcp_bundle/src/ports/io_policy_port.dart'
    show PolicyRule, PolicyCondition;
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Stub adapter for testing tool dispatch.
class _StubAdapter implements IoDevicePort {
  _StubAdapter({required this.descriptor});

  final DeviceDescriptor descriptor;
  bool connected = false;

  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<DeviceDescriptor> describe() async => descriptor;

  @override
  Future<ReadResult> read(ReadSpec spec) async => ReadResult(
        items: spec.targets
            .map((t) => ReadResultItem(uri: t))
            .toList(),
      );

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

AdapterManifest _manifest(String id) => AdapterManifest(
      adapterId: id,
      adapterVersion: '1.0.0',
      contractVersionRange: '>=0.1.0 <1.0.0',
      displayName: 'Test Adapter $id',
    );

DeviceDescriptor _device(String id) => DeviceDescriptor(
      deviceId: id,
      manufacturer: 'TestCorp',
      model: 'Sensor-X',
      transport: 'tcp',
      connectionState: IoConnectionState.connected,
    );

void main() {
  late IoRuntime runtime;
  late InMemoryIoPolicyPort policyPort;
  late InMemoryAuditPort auditPort;
  late IoTools tools;

  setUp(() async {
    policyPort = InMemoryIoPolicyPort();
    auditPort = InMemoryAuditPort();
    runtime = IoRuntime(policyPort: policyPort, auditPort: auditPort);
    await runtime.initialize();
    tools = IoTools(runtime: runtime);
  });

  tearDown(() async {
    await runtime.dispose();
  });

  // ---------------------------------------------------------------------------
  // Helper: register and discover a device.
  // ---------------------------------------------------------------------------
  Future<void> registerDevice(String id) async {
    final adapter = _StubAdapter(descriptor: _device(id));
    await runtime.registry
        .registerAdapter(_manifest('adapter-$id'), adapter);
    await runtime.registry.discover();
  }

  // ---------------------------------------------------------------------------
  // TC-174~175: Tool registration
  // ---------------------------------------------------------------------------
  group('IoTools - Tool Registration', () {
    test('TC-174 [normal] tools list has 8 entries', () {
      expect(tools.tools, hasLength(8));
    });

    test('TC-175 [normal] tool names match expected set', () {
      final names = tools.tools.map((t) => t.name).toSet();
      expect(
        names,
        containsAll(<String>[
          'io.list_devices',
          'io.describe_device',
          'io.read',
          'io.execute',
          'io.emergency_stop',
          'io.subscribe',
          'io.plan_execute',
          'io.commit_execute',
        ]),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // TC-176~177: listDevices
  // ---------------------------------------------------------------------------
  group('IoTools - listDevices', () {
    test('TC-176 [normal] returns empty list when no devices', () async {
      final result = await tools.listDevices(<String, dynamic>{});
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as List;
      expect(decoded, isEmpty);
    });

    test('TC-177 [normal] returns registered device', () async {
      await registerDevice('dev-1');

      final result = await tools.listDevices(<String, dynamic>{});
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as List;
      expect(decoded, hasLength(1));
      expect(decoded.first['deviceId'], 'dev-1');
    });
  });

  // ---------------------------------------------------------------------------
  // TC-178~179: describeDevice
  // ---------------------------------------------------------------------------
  group('IoTools - describeDevice', () {
    test('TC-178 [normal] returns descriptor for known device', () async {
      await registerDevice('dev-1');

      final result = await tools.describeDevice(
        <String, dynamic>{'deviceId': 'dev-1'},
      );
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded['deviceId'], 'dev-1');
      expect(decoded['manufacturer'], 'TestCorp');
    });

    test('TC-179 [error] returns error for unknown device', () async {
      final result = await tools.describeDevice(
        <String, dynamic>{'deviceId': 'nonexistent'},
      );
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('device.not_found'));
    });
  });

  // ---------------------------------------------------------------------------
  // TC-180~181: readResource
  // ---------------------------------------------------------------------------
  group('IoTools - readResource', () {
    test('TC-180 [normal] reads resource from registered device', () async {
      await registerDevice('dev-1');

      final result = await tools.readResource(<String, dynamic>{
        'targets': ['dev-1/ch/1'],
      });
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded, isNotNull);
    });

    test('TC-181 [error] returns error when targets missing', () async {
      final result = await tools.readResource(<String, dynamic>{});
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('tool.invalid_args'));
    });
  });

  // ---------------------------------------------------------------------------
  // TC-182~184: executeCommand
  // ---------------------------------------------------------------------------
  group('IoTools - executeCommand', () {
    test('TC-182 [normal] execute allowed command', () async {
      await registerDevice('dev-1');

      // Add an allow-all rule so the command passes policy
      await policyPort.addRule(const PolicyRule(
        id: 'allow-all',
        name: 'Allow all',
        when: PolicyCondition(),
        allow: true,
      ));

      final result = await tools.executeCommand(<String, dynamic>{
        'target': 'dev-1/ch/1',
        'action': 'measure',
        'actorId': 'user-1',
        'role': 'operator',
      });
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded['status'], isNotNull);
    });

    test('TC-183 [normal] execute denied command', () async {
      await registerDevice('dev-1');

      // Add a deny rule
      await policyPort.addRule(const PolicyRule(
        id: 'deny-all',
        name: 'Deny all',
        when: PolicyCondition(),
        allow: false,
      ));

      final result = await tools.executeCommand(<String, dynamic>{
        'target': 'dev-1/ch/1',
        'action': 'measure',
        'actorId': 'user-1',
        'role': 'operator',
      });
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded['status'], 'rejected');
    });

    test('TC-184 [error] execute with missing args', () async {
      final result = await tools.executeCommand(<String, dynamic>{
        'target': 'dev-1/ch/1',
        // Missing action, actorId, role
      });
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('tool.invalid_args'));
    });
  });

  // ---------------------------------------------------------------------------
  // TC-185~186: emergencyStop
  // ---------------------------------------------------------------------------
  group('IoTools - emergencyStop', () {
    test('TC-185 [normal] emergency stop with actorId', () async {
      await registerDevice('dev-1');

      final result = await tools.emergencyStop(<String, dynamic>{
        'actorId': 'user-1',
        'deviceId': 'dev-1',
      });
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded['success'], isTrue);
    });

    test('TC-186 [error] emergency stop without actorId', () async {
      final result = await tools.emergencyStop(<String, dynamic>{});
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('tool.invalid_args'));
    });
  });

  // ---------------------------------------------------------------------------
  // TC-187~188: subscribe
  // ---------------------------------------------------------------------------
  group('IoTools - subscribe', () {
    test('TC-187 [normal] subscribe with valid args', () async {
      await registerDevice('dev-1');

      final result = await tools.subscribe(<String, dynamic>{
        'uri': 'io://dev-1/ch/1',
        'consumerId': 'consumer-1',
      });
      expect(result.isError, isFalse);

      final decoded = jsonDecode(result.content as String) as Map<String, dynamic>;
      expect(decoded['subscriptionId'], isNotNull);
      expect(decoded['topic'], isNotNull);
    });

    test('TC-188 [error] subscribe without required args', () async {
      final result = await tools.subscribe(<String, dynamic>{
        'uri': 'io://dev-1/ch/1',
        // Missing consumerId
      });
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('tool.invalid_args'));
    });
  });

  // ---------------------------------------------------------------------------
  // Dispatch via call()
  // ---------------------------------------------------------------------------
  group('IoTools - call dispatch', () {
    test('dispatches to correct handler by name', () async {
      final result = await tools.call(
        'io.list_devices',
        <String, dynamic>{},
      );
      expect(result.isError, isFalse);
    });

    test('returns error for unknown tool name', () async {
      final result = await tools.call(
        'io.unknown_tool',
        <String, dynamic>{},
      );
      expect(result.isError, isTrue);
      expect(result.errorMessage, contains('tool.not_found'));
    });
  });

  // ---------------------------------------------------------------------------
  // IT-026: Full tool pipeline
  // ---------------------------------------------------------------------------
  group('IoTools - Integration', () {
    test('IT-026 Full tool pipeline: list -> describe -> read -> execute',
        () async {
      await registerDevice('dev-1');

      // Add an allow-all rule
      await policyPort.addRule(const PolicyRule(
        id: 'allow-all',
        name: 'Allow all',
        when: PolicyCondition(),
        allow: true,
      ));

      // Step 1: list devices via call()
      final listResult = await tools.call(
        'io.list_devices',
        <String, dynamic>{},
      );
      expect(listResult.isError, isFalse);
      final devices = jsonDecode(listResult.content as String) as List;
      expect(devices, hasLength(1));
      final deviceId = devices.first['deviceId'] as String;

      // Step 2: describe device
      final descResult = await tools.call(
        'io.describe_device',
        <String, dynamic>{'deviceId': deviceId},
      );
      expect(descResult.isError, isFalse);
      final desc = jsonDecode(descResult.content as String) as Map<String, dynamic>;
      expect(desc['manufacturer'], 'TestCorp');

      // Step 3: read resource
      final readResult = await tools.call(
        'io.read',
        <String, dynamic>{
          'targets': ['$deviceId/ch/1'],
        },
      );
      expect(readResult.isError, isFalse);

      // Step 4: execute command
      final execResult = await tools.call(
        'io.execute',
        <String, dynamic>{
          'target': '$deviceId/ch/1',
          'action': 'measure',
          'actorId': 'user-1',
          'role': 'operator',
        },
      );
      expect(execResult.isError, isFalse);
    });
  });
}
