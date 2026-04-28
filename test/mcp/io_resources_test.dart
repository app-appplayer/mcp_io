import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Stub adapter for testing resource browsing.
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

DeviceDescriptor _device(String id, {String model = 'Sensor-X'}) =>
    DeviceDescriptor(
      deviceId: id,
      manufacturer: 'TestCorp',
      model: model,
      transport: 'tcp',
      connectionState: IoConnectionState.connected,
    );

void main() {
  late IoRuntime runtime;
  late InMemoryIoPolicyPort policyPort;
  late InMemoryAuditPort auditPort;
  late IoResources resources;

  setUp(() async {
    policyPort = InMemoryIoPolicyPort();
    auditPort = InMemoryAuditPort();
    runtime = IoRuntime(policyPort: policyPort, auditPort: auditPort);
    await runtime.initialize();
    resources = IoResources(runtime: runtime);
  });

  tearDown(() async {
    await runtime.dispose();
  });

  // ---------------------------------------------------------------------------
  // Helper: register and discover a device.
  // ---------------------------------------------------------------------------
  Future<void> registerDevice(String id, {String model = 'Sensor-X'}) async {
    final adapter = _StubAdapter(descriptor: _device(id, model: model));
    await runtime.registry
        .registerAdapter(_manifest('adapter-$id'), adapter);
    await runtime.registry.discover();
  }

  // ---------------------------------------------------------------------------
  // TC-192~193: Templates
  // ---------------------------------------------------------------------------
  group('IoResources - Templates', () {
    test('TC-192 [normal] templates list has 3 entries', () {
      expect(resources.templates, hasLength(3));
    });

    test('TC-193 [normal] template URIs match expected patterns', () {
      final uris = resources.templates.map((t) => t.uri).toList();
      expect(uris, contains('io://'));
      expect(uris, contains('io://{deviceId}'));
      expect(uris, contains('io://{deviceId}/{path}'));
    });
  });

  // ---------------------------------------------------------------------------
  // TC-194~196: listResources
  // ---------------------------------------------------------------------------
  group('IoResources - listResources', () {
    test('TC-194 [normal] list returns empty when no devices', () async {
      final result = await resources.listResources();
      expect(result, isEmpty);
    });

    test('TC-195 [normal] list returns registered devices', () async {
      await registerDevice('dev-1');
      await registerDevice('dev-2', model: 'Actuator-Y');

      final result = await resources.listResources();
      expect(result, hasLength(2));

      final uris = result.map((r) => r.uri).toSet();
      expect(uris, contains('io://dev-1'));
      expect(uris, contains('io://dev-2'));
    });

    test('TC-196 [normal] list with specific device URI pattern', () async {
      await registerDevice('dev-1');

      final result =
          await resources.listResources(uriPattern: 'io://dev-1');
      expect(result, hasLength(1));
      expect(result.first.uri, 'io://dev-1');
      expect(result.first.name, 'TestCorp Sensor-X');
    });
  });

  // ---------------------------------------------------------------------------
  // TC-197~199: readResource
  // ---------------------------------------------------------------------------
  group('IoResources - readResource', () {
    test('TC-197 [normal] read device descriptor by URI', () async {
      await registerDevice('dev-1');

      final content = await resources.readResource('io://dev-1');
      expect(content.uri, 'io://dev-1');
      expect(content.mimeType, 'application/json');

      final decoded = jsonDecode(content.text!) as Map<String, dynamic>;
      expect(decoded['deviceId'], 'dev-1');
      expect(decoded['manufacturer'], 'TestCorp');
    });

    test('TC-198 [normal] read sub-resource path', () async {
      await registerDevice('dev-1');

      final content =
          await resources.readResource('io://dev-1/ch/1/voltage');
      expect(content.uri, 'io://dev-1/ch/1/voltage');
      expect(content.mimeType, 'application/json');

      final decoded = jsonDecode(content.text!) as Map<String, dynamic>;
      // Should contain read result (items list or error)
      expect(decoded, isNotNull);
    });

    test('TC-199 [error] read with invalid URI returns error', () async {
      final content = await resources.readResource('invalid-uri');
      expect(content.mimeType, 'application/json');

      final decoded = jsonDecode(content.text!) as Map<String, dynamic>;
      expect(decoded['error'], 'resource.not_found');
    });
  });

  // ---------------------------------------------------------------------------
  // Additional edge cases
  // ---------------------------------------------------------------------------
  group('IoResources - Edge Cases', () {
    test('read non-existent device returns error content', () async {
      final content = await resources.readResource('io://nonexistent');

      final decoded = jsonDecode(content.text!) as Map<String, dynamic>;
      expect(decoded['error'], 'resource.not_found');
      expect(decoded['message'], contains('nonexistent'));
    });

    test('listResources with null pattern returns all devices', () async {
      await registerDevice('dev-1');

      final result = await resources.listResources(uriPattern: null);
      expect(result, hasLength(1));
      expect(result.first.uri, 'io://dev-1');
    });

    test('listResources with unknown device returns empty', () async {
      final result =
          await resources.listResources(uriPattern: 'io://unknown');
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // IT-028: Browse and read flow
  // ---------------------------------------------------------------------------
  group('IoResources - Integration', () {
    test('IT-028 Browse and read flow: templates -> list -> read', () async {
      await registerDevice('dev-1');

      // Step 1: Check templates are available
      final templates = resources.templates;
      expect(templates, hasLength(3));

      // Step 2: List all devices
      final deviceList = await resources.listResources();
      expect(deviceList, hasLength(1));
      final deviceUri = deviceList.first.uri;
      expect(deviceUri, 'io://dev-1');

      // Step 3: Read device descriptor
      final descriptor = await resources.readResource(deviceUri);
      expect(descriptor.mimeType, 'application/json');

      final descData =
          jsonDecode(descriptor.text!) as Map<String, dynamic>;
      expect(descData['deviceId'], 'dev-1');
      expect(descData['manufacturer'], 'TestCorp');

      // Step 4: Read sub-resource
      final subResource =
          await resources.readResource('$deviceUri/ch/1');
      expect(subResource.mimeType, 'application/json');

      final subData =
          jsonDecode(subResource.text!) as Map<String, dynamic>;
      expect(subData, isNotNull);
    });
  });
}
