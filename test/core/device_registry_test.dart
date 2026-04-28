import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Stub adapter for testing.
class _StubAdapter implements IoDevicePort {
  _StubAdapter({
    required this.descriptor,
    this.shouldTimeout = false,
    this.shouldError = false,
  });

  final DeviceDescriptor descriptor;
  final bool shouldTimeout;
  final bool shouldError;
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
  Future<DeviceDescriptor> describe() async {
    if (shouldTimeout) {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    if (shouldError) {
      throw StateError('Adapter error');
    }
    return descriptor;
  }

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

void main() {
  late DeviceRegistry registry;

  setUp(() async {
    registry = DeviceRegistry.withDefaults();
    await registry.initialize();
  });

  tearDown(() async {
    await registry.dispose();
  });

  group('DeviceRegistry - Registration', () {
    test('TC-001 [normal] Register adapter successfully', () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await registry.registerAdapter(_manifest('scpi-adapter'), adapter);

      final devices = await registry.list();
      expect(devices, isEmpty);
    });

    test('TC-002 [normal] Register multiple adapters', () async {
      final a1 = _StubAdapter(descriptor: _device('dev-1'));
      final a2 = _StubAdapter(descriptor: _device('dev-2'));

      await registry.registerAdapter(_manifest('adapter-1'), a1);
      await registry.registerAdapter(_manifest('adapter-2'), a2);
    });

    test('TC-003 [error] Register duplicate adapter throws', () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await registry.registerAdapter(_manifest('scpi-adapter'), adapter);

      expect(
        () => registry.registerAdapter(
          _manifest('scpi-adapter'),
          _StubAdapter(descriptor: _device('dev-2')),
        ),
        throwsStateError,
      );
    });

    test('TC-004 [boundary] Register max adapters then overflow', () async {
      final reg = DeviceRegistry(
        config: const RegistryConfig(maxAdapters: 2, maxDevices: 256),
        reconnectionConfig: const ReconnectionConfig.defaults(),
      );
      await reg.initialize();

      await reg.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await reg.registerAdapter(
          _manifest('a2'), _StubAdapter(descriptor: _device('d2')));

      expect(
        () => reg.registerAdapter(
          _manifest('a3'),
          _StubAdapter(descriptor: _device('d3')),
        ),
        throwsStateError,
      );

      await reg.dispose();
    });

    test('TC-005 [normal] Unregister adapter removes devices', () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await registry.registerAdapter(_manifest('adapter-1'), adapter);
      await registry.discover();

      var devices = await registry.list();
      expect(devices, hasLength(1));

      await registry.unregisterAdapter('adapter-1');
      devices = await registry.list();
      expect(devices, isEmpty);
    });

    test('TC-006 [boundary] Unregister non-existent adapter does nothing',
        () async {
      await registry.unregisterAdapter('nonexistent');
    });
  });

  group('DeviceRegistry - Discovery', () {
    test('TC-007 [normal] Discover devices from registered adapters', () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await registry.registerAdapter(_manifest('adapter-1'), adapter);

      final discovered = await registry.discover();
      expect(discovered, hasLength(1));
      expect(discovered.first.deviceId, 'dev-1');
    });

    test('TC-008 [normal] Discover with transport filter', () async {
      final tcpAdapter =
          _StubAdapter(descriptor: _device('dev-tcp', transport: 'tcp'));
      final serialAdapter =
          _StubAdapter(descriptor: _device('dev-serial', transport: 'serial'));

      await registry.registerAdapter(_manifest('tcp-adapter'), tcpAdapter);
      await registry.registerAdapter(
          _manifest('serial-adapter'), serialAdapter);

      final discovered = await registry.discover(transportFilter: 'tcp');
      expect(discovered, hasLength(1));
      expect(discovered.first.transport, 'tcp');
    });

    test('TC-009 [error] Discover handles adapter timeout', () async {
      final slowAdapter =
          _StubAdapter(descriptor: _device('slow'), shouldTimeout: true);
      await registry.registerAdapter(_manifest('slow-adapter'), slowAdapter);

      final discovered = await registry.discover(
        timeout: const Duration(milliseconds: 100),
      );
      expect(discovered, isEmpty);
    });

    test('TC-010 [error] Discover handles adapter error gracefully', () async {
      final errorAdapter =
          _StubAdapter(descriptor: _device('err'), shouldError: true);
      await registry.registerAdapter(_manifest('error-adapter'), errorAdapter);

      final discovered = await registry.discover();
      expect(discovered, isEmpty);
    });

    test('TC-011 [boundary] Discover max devices overflow', () async {
      final reg = DeviceRegistry(
        config: const RegistryConfig(maxAdapters: 32, maxDevices: 1),
        reconnectionConfig: const ReconnectionConfig.defaults(),
      );
      await reg.initialize();

      await reg.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await reg.discover();

      await reg.registerAdapter(
          _manifest('a2'), _StubAdapter(descriptor: _device('d2')));

      expect(reg.discover, throwsStateError);
      await reg.dispose();
    });

    test('TC-012 [normal] Auto-discover on registration', () async {
      final reg = DeviceRegistry(
        config: const RegistryConfig(autoDiscover: true),
        reconnectionConfig: const ReconnectionConfig.defaults(),
      );
      await reg.initialize();

      await reg.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));

      final devices = await reg.list();
      expect(devices, hasLength(1));
      await reg.dispose();
    });
  });

  group('DeviceRegistry - Get & List', () {
    test('TC-013 [normal] Get device by ID', () async {
      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('dev-1')));
      await registry.discover();

      final device = await registry.get('dev-1');
      expect(device, isNotNull);
      expect(device!.deviceId, 'dev-1');
    });

    test('TC-014 [boundary] Get non-existent device returns null', () async {
      final device = await registry.get('nonexistent');
      expect(device, isNull);
    });

    test('TC-015 [normal] List all devices', () async {
      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await registry.registerAdapter(
          _manifest('a2'), _StubAdapter(descriptor: _device('d2')));
      await registry.discover();

      final devices = await registry.list();
      expect(devices, hasLength(2));
    });

    test('TC-016 [normal] List devices with state filter', () async {
      await registry.registerAdapter(
          _manifest('a1'),
          _StubAdapter(
              descriptor: _device('d1')));
      await registry.discover();

      final connected =
          await registry.list(stateFilter: IoConnectionState.connected);
      expect(connected, hasLength(1));

      final disconnected =
          await registry.list(stateFilter: IoConnectionState.disconnected);
      expect(disconnected, isEmpty);
    });
  });

  group('DeviceRegistry - URI Resolution', () {
    test('TC-017 [normal] Resolve adapter from URI', () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));
      await registry.registerAdapter(_manifest('a1'), adapter);
      await registry.discover();

      final resolved = await registry.resolveAdapter('io://dev-1/ch/1');
      expect(resolved, isNotNull);
    });

    test('TC-018 [boundary] Resolve with unknown device returns null',
        () async {
      final resolved = await registry.resolveAdapter('io://unknown/ch/1');
      expect(resolved, isNull);
    });

    test('TC-019 [error] Resolve with invalid URI returns null', () async {
      final resolved = await registry.resolveAdapter('invalid-uri');
      expect(resolved, isNull);
    });
  });

  group('DeviceRegistry - Events', () {
    test('TC-020 [normal] Emit adapter registered event', () async {
      final events = <RegistryEvent>[];
      registry.events.listen(events.add);

      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, isNotEmpty);
      expect(events.first.type, RegistryEventType.adapterRegistered);
    });

    test('TC-021 [normal] Emit device registered event on discover', () async {
      final events = <RegistryEvent>[];
      registry.events.listen(events.add);

      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await registry.discover();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final deviceEvents = events
          .where((e) => e.type == RegistryEventType.deviceRegistered)
          .toList();
      expect(deviceEvents, hasLength(1));
    });

    test('TC-022 [normal] Emit device unregistered event', () async {
      final events = <RegistryEvent>[];
      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await registry.discover();

      registry.events.listen(events.add);
      await registry.unregisterAdapter('a1');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final unregEvents = events
          .where((e) => e.type == RegistryEventType.deviceUnregistered)
          .toList();
      expect(unregEvents, hasLength(1));
    });
  });

  group('DeviceRegistry - Lifecycle', () {
    test('TC-extra [error] Operations before initialize throw', () async {
      final uninitReg = DeviceRegistry.withDefaults();
      expect(
        () => uninitReg.registerAdapter(
          _manifest('a1'),
          _StubAdapter(descriptor: _device('d1')),
        ),
        throwsStateError,
      );
    });

    test('TC-extra [normal] DisconnectAll closes all devices', () async {
      final adapter = _StubAdapter(descriptor: _device('d1'));
      await registry.registerAdapter(_manifest('a1'), adapter);
      await registry.discover();

      await registry.disconnectAll();
      final devices = await registry.list();
      expect(devices, isEmpty);
    });
  });

  group('DeviceRegistry - Integration', () {
    test('IT-001 Register adapter → discover → resolve → unregister flow',
        () async {
      final adapter = _StubAdapter(descriptor: _device('dev-1'));

      // Register
      await registry.registerAdapter(_manifest('a1'), adapter);

      // Discover
      final discovered = await registry.discover();
      expect(discovered, hasLength(1));

      // Resolve
      final resolved = await registry.resolveAdapter('io://dev-1/measure/v1');
      expect(resolved, isNotNull);

      // Unregister
      await registry.unregisterAdapter('a1');
      final afterUnreg =
          await registry.resolveAdapter('io://dev-1/measure/v1');
      expect(afterUnreg, isNull);
    });

    test('IT-002 Multi-adapter discovery and resolution', () async {
      final a1 =
          _StubAdapter(descriptor: _device('scpi-dev', transport: 'tcp'));
      final a2 = _StubAdapter(
          descriptor: _device('modbus-dev', transport: 'serial'));

      await registry.registerAdapter(_manifest('scpi'), a1);
      await registry.registerAdapter(_manifest('modbus'), a2);

      final all = await registry.discover();
      expect(all, hasLength(2));

      final scpiAdapter =
          await registry.resolveAdapter('io://scpi-dev/measure');
      expect(scpiAdapter, isNotNull);

      final modbusAdapter =
          await registry.resolveAdapter('io://modbus-dev/register');
      expect(modbusAdapter, isNotNull);
    });

    test('IT-003 Event stream tracks full lifecycle', () async {
      final events = <RegistryEvent>[];
      registry.events.listen(events.add);

      await registry.registerAdapter(
          _manifest('a1'), _StubAdapter(descriptor: _device('d1')));
      await registry.discover();
      await registry.unregisterAdapter('a1');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final types = events.map((e) => e.type).toList();
      expect(types, contains(RegistryEventType.adapterRegistered));
      expect(types, contains(RegistryEventType.deviceRegistered));
      expect(types, contains(RegistryEventType.deviceUnregistered));
      expect(types, contains(RegistryEventType.adapterUnregistered));
    });
  });
}
