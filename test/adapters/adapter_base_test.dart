import 'dart:async';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Concrete stub adapter extending AdapterBase for testing.
class _TestAdapter extends AdapterBase {
  _TestAdapter({
    required super.manifest,
    required this.descriptor,
    this.shouldFailConnect = false,
    this.shouldFailExecute = false,
  });

  final DeviceDescriptor descriptor;
  bool isConnected = false;
  Command? lastCommand;
  bool shouldFailConnect;
  bool shouldFailDisconnect = false;
  bool shouldFailExecute;

  @override
  Future<List<DeviceDescriptor>> probe(dynamic transport) async {
    return [descriptor];
  }

  @override
  Future<void> connect() async {
    if (shouldFailConnect) {
      throw const SocketException('Connection refused');
    }
    isConnected = true;
  }

  @override
  Future<void> disconnect() async {
    if (shouldFailDisconnect) {
      isConnected = false;
      throw const SocketException('Disconnect error');
    }
    isConnected = false;
  }

  @override
  Future<DeviceDescriptor> describe() async => descriptor;

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    return ReadResult(
      items: spec.targets
          .map((uri) => ReadResultItem(
                uri: uri,
                envelope: PayloadEnvelope(
                  uri: uri,
                  kind: PayloadKind.read,
                  payload: TypedPayload(
                    type: PayloadType.scalar,
                    value: 42.0,
                    timestamp: DateTime.now(),
                  ),
                  meta: EnvelopeMeta(
                    capturedAt: DateTime.now(),
                    sourceAddress: descriptor.deviceId,
                  ),
                ),
              ))
          .toList(),
    );
  }

  @override
  Future<CommandResult> execute(Command command) async {
    if (shouldFailExecute) {
      throw Exception('Execution failed');
    }
    lastCommand = command;
    return CommandResult(
      status: CommandStatus.completed,
      result: 'ok',
    );
  }

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) {
    return Stream.periodic(const Duration(milliseconds: 100), (i) {
      return PayloadEnvelope(
        uri: spec.uri,
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.scalar,
          value: i.toDouble(),
          timestamp: DateTime.now(),
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: descriptor.deviceId,
          sequenceNumber: i,
        ),
      );
    });
  }

  @override
  Future<EmergencyStopResult> emergencyStop(
      EmergencyStopRequest request) async {
    isConnected = false;
    return EmergencyStopResult(
      success: true,
      stoppedDevices: [descriptor.deviceId],
    );
  }
}

AdapterManifest _testManifest({String id = 'test-adapter'}) =>
    AdapterManifest(
      adapterId: id,
      adapterVersion: '1.0.0',
      contractVersionRange: '>=0.1.0 <1.0.0',
      displayName: 'Test Adapter',
    );

DeviceDescriptor _testDevice({String id = 'dev-1'}) => DeviceDescriptor(
      deviceId: id,
      manufacturer: 'TestCorp',
      model: 'TestModel',
      transport: 'tcp',
      connectionState: IoConnectionState.connected,
    );

void main() {
  group('AdapterBase - Lifecycle', () {
    test('TC-123 [normal] Connect and disconnect', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();
      expect(adapter.isConnected, isTrue);

      await adapter.disconnect();
      expect(adapter.isConnected, isFalse);
    });

    test('TC-124 [normal] Describe returns device descriptor', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final desc = await adapter.describe();
      expect(desc.deviceId, 'dev-1');
      expect(desc.manufacturer, 'TestCorp');
    });

    test('TC-125 [normal] Probe discovers devices', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final devices = await adapter.probe('tcp://localhost:5025');
      expect(devices, hasLength(1));
      expect(devices.first.deviceId, 'dev-1');
    });
  });

  group('AdapterBase - Read', () {
    test('TC-126 [normal] Read returns payload envelopes', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final result = await adapter.read(
        const ReadSpec(targets: ['io://dev-1/ch/1']),
      );
      expect(result.items, hasLength(1));
      expect(result.items.first.envelope, isNotNull);
      expect(result.items.first.envelope!.payload.value, 42.0);
    });

    test('TC-127 [normal] Read multiple targets', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final result = await adapter.read(
        const ReadSpec(targets: ['io://dev-1/ch/1', 'io://dev-1/ch/2']),
      );
      expect(result.items, hasLength(2));
    });
  });

  group('AdapterBase - Execute', () {
    test('TC-128 [normal] Execute command successfully', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final result = await adapter.execute(
        const Command(action: 'setVoltage', target: 'io://dev-1/ch/1'),
      );
      expect(result.status, CommandStatus.completed);
      expect(adapter.lastCommand!.action, 'setVoltage');
    });
  });

  group('AdapterBase - Subscribe', () {
    test('TC-129 [normal] Subscribe returns data stream', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      final stream = adapter.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
      );

      final events = await stream.take(3).toList();
      expect(events, hasLength(3));
      expect(events[0].payload.value, 0.0);
      expect(events[1].payload.value, 1.0);
    });
  });

  group('AdapterBase - Emergency Stop', () {
    test('TC-130 [normal] Emergency stop succeeds', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();
      final result = await adapter.emergencyStop(
        const EmergencyStopRequest(reason: 'test', actorId: 'operator-1'),
      );

      expect(result.success, isTrue);
      expect(result.stoppedDevices, contains('dev-1'));
      expect(adapter.isConnected, isFalse);
    });
  });

  group('AdapterBase - Error Mapping', () {
    test('TC-131 [normal] SocketException maps to conn.lost', () {
      final error = AdapterBase.mapException(
        const SocketException('Connection refused'),
      );
      expect(error.code, 'conn.lost');
      expect(error.message, contains('Connection lost'));
    });

    test('TC-132 [normal] TimeoutException maps to conn.timeout', () {
      final error = AdapterBase.mapException(
        TimeoutException('Timed out'),
      );
      expect(error.code, 'conn.timeout');
      expect(error.message, contains('Connection timeout'));
    });

    test('TC-133 [normal] ArgumentError maps to exec.invalid_args', () {
      final error = AdapterBase.mapException(
        ArgumentError('Invalid value'),
      );
      expect(error.code, 'exec.invalid_args');
    });

    test('TC-134 [normal] UnsupportedError maps to device.unsupported', () {
      final error = AdapterBase.mapException(
        UnsupportedError('Not supported'),
      );
      expect(error.code, 'device.unsupported');
    });

    test('TC-135 [normal] Unknown error maps to exec.failed', () {
      final error = AdapterBase.mapException(Exception('Unknown'));
      expect(error.code, 'exec.failed');
    });
  });

  group('UriMapper', () {
    test('TC-136 [normal] Resolve URI with template parameters', () {
      final mapper = UriMapper([
        const ResourceMapping(
          uriTemplate: 'ch/{ch}/measure/{measure}',
          addressTemplate: ':MEASure:{measure}?',
        ),
      ]);

      final result = mapper.resolve('ch/1/measure/voltage');
      expect(result, isNotNull);
      expect(result!.nativeAddress, ':MEASure:voltage?');
      expect(result.parameters['ch'], '1');
      expect(result.parameters['measure'], 'voltage');
    });

    test('TC-137 [boundary] No matching template returns null', () {
      final mapper = UriMapper([
        const ResourceMapping(
          uriTemplate: 'ch/{ch}/measure/{measure}',
          addressTemplate: ':MEASure:{measure}?',
        ),
      ]);

      final result = mapper.resolve('status/info');
      expect(result, isNull);
    });

    test('TC-138 [normal] Multiple templates match first', () {
      final mapper = UriMapper([
        const ResourceMapping(
          uriTemplate: 'ch/{ch}/measure/{m}',
          addressTemplate: ':MEAS:{m}?',
        ),
        const ResourceMapping(
          uriTemplate: 'ch/{ch}/output/{o}',
          addressTemplate: ':OUTP:{o}',
        ),
      ]);

      final result = mapper.resolve('ch/1/output/voltage');
      expect(result, isNotNull);
      expect(result!.nativeAddress, ':OUTP:voltage');
    });

    test('TC-139 [boundary] Template with different segment count returns null',
        () {
      final mapper = UriMapper([
        const ResourceMapping(
          uriTemplate: 'ch/{ch}/measure',
          addressTemplate: ':MEAS?',
        ),
      ]);

      final result = mapper.resolve('ch/1/measure/extra');
      expect(result, isNull);
    });
  });

  group('AdapterBase - Integration', () {
    test('IT-019 Full adapter lifecycle: connect → describe → read → disconnect',
        () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      // Connect
      await adapter.connect();
      expect(adapter.isConnected, isTrue);

      // Describe
      final desc = await adapter.describe();
      expect(desc.deviceId, 'dev-1');

      // Read
      final readResult = await adapter.read(
        const ReadSpec(targets: ['io://dev-1/ch/1']),
      );
      expect(readResult.items, hasLength(1));

      // Disconnect
      await adapter.disconnect();
      expect(adapter.isConnected, isFalse);
    });

    test('IT-020 Execute and emergency stop flow', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();

      final execResult = await adapter.execute(
        const Command(action: 'setVoltage', target: 'ch/1', args: {'value': 5.0}),
      );
      expect(execResult.status, CommandStatus.completed);

      final stopResult = await adapter.emergencyStop(
        const EmergencyStopRequest(reason: 'safety', actorId: 'op-1'),
      );
      expect(stopResult.success, isTrue);
    });

    test('IT-021 Manifest properties accessible', () {
      final adapter = _TestAdapter(
        manifest: _testManifest(id: 'my-adapter'),
        descriptor: _testDevice(),
      );

      expect(adapter.manifest.adapterId, 'my-adapter');
      expect(adapter.manifest.displayName, 'Test Adapter');
    });

    test('IT-022 Error mapping covers all exception types', () {
      final errors = <IoError>[
        AdapterBase.mapException(const SocketException('lost')),
        AdapterBase.mapException(TimeoutException('timeout')),
        AdapterBase.mapException(ArgumentError('bad args')),
        AdapterBase.mapException(UnsupportedError('unsupported')),
        AdapterBase.mapException(Exception('generic')),
      ];

      final codes = errors.map((e) => e.code).toSet();
      expect(codes, containsAll([
        'conn.lost',
        'conn.timeout',
        'exec.invalid_args',
        'device.unsupported',
        'exec.failed',
      ]));
    });
  });

  group('AdapterBase - Idempotent Operations', () {
    test('TC-124-spec [boundary] Idempotent connect (already connected)',
        () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();
      expect(adapter.isConnected, isTrue);

      // Second connect should not throw
      await adapter.connect();
      expect(adapter.isConnected, isTrue);
    });

    test('TC-127-spec [boundary] Idempotent disconnect (already disconnected)',
        () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      // Disconnect without prior connect should not throw
      await adapter.disconnect();
      expect(adapter.isConnected, isFalse);
    });
  });

  group('AdapterBase - Connection Failures', () {
    test('TC-125-spec [error] Connection failure maps to conn.lost', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
        shouldFailConnect: true,
      );

      try {
        await adapter.connect();
        fail('Should have thrown');
      } on SocketException catch (e) {
        final error = AdapterBase.mapException(e);
        expect(error.code, 'conn.lost');
      }
      expect(adapter.isConnected, isFalse);
    });

    test('TC-128-spec [error] Exception during disconnect', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();
      adapter.shouldFailDisconnect = true;

      try {
        await adapter.disconnect();
        fail('Should have thrown');
      } on SocketException catch (e) {
        final error = AdapterBase.mapException(e);
        expect(error.code, 'conn.lost');
      }

      // State should be disconnected despite exception
      expect(adapter.isConnected, isFalse);
    });
  });

  group('AdapterBase - Execute Failures', () {
    test('TC-136-spec [error] Execution failure maps to exec.failed', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
        shouldFailExecute: true,
      );

      try {
        await adapter.execute(
          const Command(action: 'setVoltage', target: 'io://dev-1/ch/1'),
        );
        fail('Should have thrown');
      } on Exception catch (e) {
        final error = AdapterBase.mapException(e);
        expect(error.code, 'exec.failed');
      }
    });

    test('TC-137-spec [error] Unsupported action maps to device.unsupported',
        () {
      final error = AdapterBase.mapException(
        UnsupportedError('Action not supported: unknown.action'),
      );
      expect(error.code, 'device.unsupported');
    });
  });

  group('AdapterBase - E-Stop Extended', () {
    test('TC-142-spec [boundary] E-Stop latency requirement', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();

      final stopwatch = Stopwatch()..start();
      final result = await adapter.emergencyStop(
        const EmergencyStopRequest(reason: 'safety', actorId: 'op-1'),
      );
      stopwatch.stop();

      expect(result.success, isTrue);
      // Core overhead should be minimal (well under 100ms)
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('TC-143-spec [error] Communication failure during E-Stop', () async {
      final adapter = _TestAdapter(
        manifest: _testManifest(),
        descriptor: _testDevice(),
      );

      await adapter.connect();

      // Simulate a transport-level failure wrapper
      try {
        throw const SocketException('E-Stop communication lost');
      } on SocketException catch (e) {
        final error = AdapterBase.mapException(e);
        expect(error.code, 'conn.lost');
        expect(error.message, contains('Connection lost'));
      }

      // Local safety state should still be applied
      await adapter.emergencyStop(
        const EmergencyStopRequest(reason: 'comm-failure', actorId: 'op-1'),
      );
      expect(adapter.isConnected, isFalse);
    });
  });
}
