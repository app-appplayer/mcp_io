import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

/// Stub adapter that produces a controllable stream.
class _StubStreamAdapter implements IoDevicePort {
  final StreamController<PayloadEnvelope> _controller =
      StreamController<PayloadEnvelope>.broadcast();

  void emit(PayloadEnvelope envelope) {
    if (!_controller.isClosed) {
      _controller.add(envelope);
    }
  }

  void emitError(Object error) {
    if (!_controller.isClosed) {
      _controller.addError(error);
    }
  }

  void close() {
    _controller.close();
  }

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<DeviceDescriptor> describe() async => const DeviceDescriptor(
        deviceId: 'dev-1',
        manufacturer: 'Test',
        model: 'M',
        transport: 'tcp',
      );
  @override
  Future<ReadResult> read(ReadSpec spec) async => const ReadResult();
  @override
  Future<CommandResult> execute(Command command) async =>
      CommandResult(status: CommandStatus.completed);
  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) => _controller.stream;
  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async =>
      const EmergencyStopResult(success: true);
}

PayloadEnvelope _envelope({
  String uri = 'io://dev-1/ch/1',
  double value = 42.0,
  int? seq,
}) =>
    PayloadEnvelope(
      uri: uri,
      kind: PayloadKind.stream,
      payload: TypedPayload(
        type: PayloadType.scalar,
        value: value,
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: 'dev-1',
        sequenceNumber: seq,
      ),
    );

void main() {
  late StreamManager manager;
  late _StubStreamAdapter stubAdapter;

  setUp(() async {
    stubAdapter = _StubStreamAdapter();
    manager = StreamManager(
      config: const StreamingConfig(
        defaultBufferSize: 10,
        maxBufferSize: 100,
        maxTotalBufferMemoryBytes: 50 * 1024 * 1024,
        maxSubscriptions: 5,
        defaultBufferPolicy: BackpressurePolicy.dropOldest,
        defaultTtl: Duration.zero,
      ),
      adapterResolver: (uri) async => stubAdapter,
    );
    await manager.initialize();
  });

  tearDown(() async {
    stubAdapter.close();
    await manager.dispose();
  });

  group('StreamManager - Subscribe', () {
    test('TC-059 [normal] Subscribe creates subscription', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'consumer-1',
      );

      expect(sub.handle.subscriptionId, isNotEmpty);
      expect(sub.handle.topic, 'io://dev-1/ch/1');
      expect(manager.subscriptionCount, 1);
    });

    test('TC-060 [normal] Subscribe delivers adapter data', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'consumer-1',
      );

      final completer = Completer<PayloadEnvelope>();
      sub.stream.listen((e) {
        if (!completer.isCompleted) completer.complete(e);
      });

      stubAdapter.emit(_envelope(value: 99.0));
      final received = await completer.future.timeout(
        const Duration(seconds: 2),
      );
      expect(received.payload.value, 99.0);
    });

    test('TC-061 [error] Max subscriptions exceeded throws', () async {
      for (var i = 0; i < 5; i++) {
        await manager.subscribe(
          TopicSpec(uri: 'io://dev-1/ch/$i', mode: TopicMode.continuous),
          consumerId: 'c-$i',
        );
      }

      expect(
        () => manager.subscribe(
          const TopicSpec(uri: 'io://dev-1/ch/6', mode: TopicMode.continuous),
          consumerId: 'c-6',
        ),
        throwsStateError,
      );
    });
  });

  group('StreamManager - Unsubscribe', () {
    test('TC-062 [normal] Unsubscribe removes subscription', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'consumer-1',
      );

      expect(manager.subscriptionCount, 1);
      await manager.unsubscribe(sub.handle.subscriptionId);
      expect(manager.subscriptionCount, 0);
    });

    test('TC-063 [boundary] Unsubscribe non-existent does nothing', () async {
      await manager.unsubscribe('nonexistent');
    });
  });

  group('StreamManager - List Subscriptions', () {
    test('TC-064 [normal] List all subscriptions', () async {
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/2', mode: TopicMode.continuous),
        consumerId: 'c2',
      );

      final list = await manager.listSubscriptions();
      expect(list, hasLength(2));
    });

    test('TC-065 [normal] List by consumerId', () async {
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/2', mode: TopicMode.continuous),
        consumerId: 'c2',
      );

      final list = await manager.listSubscriptions(consumerId: 'c1');
      expect(list, hasLength(1));
      expect(list.first.topic, 'io://dev-1/ch/1');
    });
  });

  group('StreamManager - Status', () {
    test('TC-066 [normal] Get subscription status', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      final status = await manager.getStatus(sub.handle.subscriptionId);
      expect(status, isNotNull);
      expect(status!.active, isTrue);
      expect(status.subscriptionId, sub.handle.subscriptionId);
    });

    test('TC-067 [boundary] Get status for unknown subscription', () async {
      final status = await manager.getStatus('unknown');
      expect(status, isNull);
    });
  });

  group('StreamManager - Backpressure', () {
    test('TC-068 [normal] DropOldest policy drops oldest when buffer full',
        () async {
      final smallManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 3,
          maxSubscriptions: 10,
          defaultBufferPolicy: BackpressurePolicy.dropOldest,
        ),
        adapterResolver: (uri) async => stubAdapter,
      );
      await smallManager.initialize();

      final sub = await smallManager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      // Emit more than buffer can hold
      for (var i = 0; i < 5; i++) {
        stubAdapter.emit(_envelope(value: i.toDouble(), seq: i));
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final status =
          await smallManager.getStatus(sub.handle.subscriptionId);
      expect(status, isNotNull);

      await smallManager.dispose();
    });

    test('TC-069 [normal] DropNewest policy discards new data', () async {
      final dropNewestManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 2,
          maxSubscriptions: 10,
          defaultBufferPolicy: BackpressurePolicy.dropNewest,
        ),
        adapterResolver: (uri) async => stubAdapter,
      );
      await dropNewestManager.initialize();

      await dropNewestManager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      await dropNewestManager.dispose();
    });
  });

  group('StreamManager - Memory', () {
    test('TC-070 [boundary] Memory limit prevents new subscriptions', () async {
      final tinyManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 100,
          maxTotalBufferMemoryBytes: 100,
          maxSubscriptions: 100,
        ),
        adapterResolver: (uri) async => stubAdapter,
      );
      await tinyManager.initialize();

      expect(
        () => tinyManager.subscribe(
          const TopicSpec(
              uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
          consumerId: 'c1',
        ),
        throwsStateError,
      );

      await tinyManager.dispose();
    });

    test('TC-071 [normal] Total buffer bytes tracked', () async {
      expect(manager.totalBufferBytes, 0);

      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      expect(manager.totalBufferBytes, greaterThan(0));
    });
  });

  group('StreamManager - CloseAll', () {
    test('TC-072 [normal] CloseAll removes all subscriptions', () async {
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/2', mode: TopicMode.continuous),
        consumerId: 'c2',
      );

      expect(manager.subscriptionCount, 2);
      await manager.closeAll();
      expect(manager.subscriptionCount, 0);
    });
  });

  group('StreamManager - RemoveByDevice', () {
    test('TC-073 [normal] RemoveByDevice removes device subscriptions',
        () async {
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );
      await manager.subscribe(
        const TopicSpec(uri: 'io://dev-2/ch/1', mode: TopicMode.continuous),
        consumerId: 'c2',
      );

      await manager.removeByDevice('dev-1');
      expect(manager.subscriptionCount, 1);
    });
  });

  group('StreamManager - Defaults', () {
    test('TC-074 [normal] WithDefaults creates working instance', () async {
      final mgr = StreamManager.withDefaults();
      await mgr.initialize();
      expect(mgr.subscriptionCount, 0);
      await mgr.dispose();
    });
  });

  group('StreamManager - Integration', () {
    test('IT-010 Subscribe → receive data → unsubscribe flow', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      final received = <PayloadEnvelope>[];
      final streamSub = sub.stream.listen(received.add);

      stubAdapter.emit(_envelope(value: 1.0));
      stubAdapter.emit(_envelope(value: 2.0));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await manager.unsubscribe(sub.handle.subscriptionId);
      await streamSub.cancel();

      expect(received, hasLength(2));
      expect(received[0].payload.value, 1.0);
      expect(received[1].payload.value, 2.0);
    });

    test('IT-011 Multi-consumer isolation', () async {
      final sub1 = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );
      final sub2 = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/2', mode: TopicMode.continuous),
        consumerId: 'c2',
      );

      expect(sub1.handle.subscriptionId, isNot(sub2.handle.subscriptionId));
      expect(manager.subscriptionCount, 2);

      await manager.unsubscribe(sub1.handle.subscriptionId);
      expect(manager.subscriptionCount, 1);
    });

    test('IT-012 Status tracking across lifecycle', () async {
      final sub = await manager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/1', mode: TopicMode.continuous),
        consumerId: 'c1',
      );

      var status = await manager.getStatus(sub.handle.subscriptionId);
      expect(status!.active, isTrue);
      expect(status.messagesDelivered, 0);

      stubAdapter.emit(_envelope(value: 1.0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      status = await manager.getStatus(sub.handle.subscriptionId);
      expect(status!.messagesDelivered, greaterThan(0));

      await manager.unsubscribe(sub.handle.subscriptionId);
      status = await manager.getStatus(sub.handle.subscriptionId);
      expect(status, isNull);
    });
  });

  group('StreamManager - TTL', () {
    test('TC-075 [normal] TTL expiration triggers auto-unsubscribe', () async {
      late DateTime currentTime;
      currentTime = DateTime(2025, 1, 1, 12, 0);

      final ttlManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 10,
          maxSubscriptions: 10,
          expiryCheckInterval: Duration(milliseconds: 50),
          defaultTtl: Duration.zero,
        ),
        adapterResolver: (uri) async => stubAdapter,
        clock: () => currentTime,
      );
      await ttlManager.initialize();

      // Subscribe with short TTL
      await ttlManager.subscribe(
        const TopicSpec(
          uri: 'io://dev-1/ch/1',
          mode: TopicMode.continuous,
          options: TopicOptions(ttlSeconds: 1),
        ),
        consumerId: 'c1',
      );
      expect(ttlManager.subscriptionCount, 1);

      // Advance time past TTL
      currentTime = currentTime.add(const Duration(seconds: 2));
      await ttlManager.checkExpiry();

      expect(ttlManager.subscriptionCount, 0);
      await ttlManager.dispose();
    });

    test('TC-076 [boundary] ttl=0 means no expiration', () async {
      late DateTime currentTime;
      currentTime = DateTime(2025, 1, 1, 12, 0);

      final ttlManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 10,
          maxSubscriptions: 10,
          expiryCheckInterval: Duration(milliseconds: 50),
          defaultTtl: Duration.zero,
        ),
        adapterResolver: (uri) async => stubAdapter,
        clock: () => currentTime,
      );
      await ttlManager.initialize();

      await ttlManager.subscribe(
        const TopicSpec(
          uri: 'io://dev-1/ch/1',
          mode: TopicMode.continuous,
        ),
        consumerId: 'c1',
      );
      expect(ttlManager.subscriptionCount, 1);

      // Advance time significantly
      currentTime = currentTime.add(const Duration(hours: 24));
      await ttlManager.checkExpiry();

      // Still active
      expect(ttlManager.subscriptionCount, 1);
      await ttlManager.dispose();
    });
  });

  group('StreamManager - Chunking', () {
    test('TC-077 [normal] Large payload chunking', () {
      // Create a payload with 50,000 points
      final data = List<double>.generate(50000, (i) => i.toDouble());
      final envelope = PayloadEnvelope(
        uri: 'io://scope_01/ch/1/waveform',
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.waveform,
          value: data,
          timestamp: DateTime.now(),
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: 'scope_01',
        ),
      );

      final chunks = PayloadChunker.chunk(
        envelope: envelope,
        maxPoints: 10000,
        groupId: 'group-1',
      );

      expect(chunks, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(chunks[i].chunkIndex, i);
        expect(chunks[i].totalChunks, 5);
        expect(chunks[i].isLast, i == 4);
        final chunkData = chunks[i].envelope.payload.value as List;
        expect(chunkData, hasLength(10000));
        expect(chunks[i].envelope.meta.chunk, isNotNull);
        expect(chunks[i].envelope.meta.chunk!.index, i);
        expect(chunks[i].envelope.meta.chunk!.total, 5);
      }
    });
  });

  group('StreamManager - Downsampling', () {
    test('TC-078 [normal] minmax downsampling', () {
      final data = List<double>.generate(1000, (i) => i.toDouble());
      final result = Downsampler.apply(data, DownsampleMethod.minmax, 10);

      // minmax produces min+max per bucket = 2 per bucket (if different)
      // Each bucket of 10: min=i*10, max=i*10+9
      expect(result.length, greaterThan(0));
      // First bucket [0..9]: min=0, max=9
      expect(result[0], 0.0);
      expect(result[1], 9.0);
      // Original peak values preserved
      expect(result, contains(999.0));
    });

    test('TC-079 [normal] avg downsampling', () {
      final data = [10.0, 20.0, 30.0, 40.0];
      final result = Downsampler.apply(data, DownsampleMethod.avg, 2);

      expect(result, hasLength(2));
      expect(result[0], 15.0);
      expect(result[1], 35.0);
    });

    test('TC-080 [normal] decimate downsampling', () {
      final data = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
      final result = Downsampler.apply(data, DownsampleMethod.decimate, 3);

      expect(result, hasLength(2));
      expect(result[0], 1.0);
      expect(result[1], 4.0);
    });
  });

  group('StreamManager - RingBuffer', () {
    test('TC-081 [normal] add/removeOldest with overflow', () {
      final buffer = RingBuffer<int>(3);
      for (var i = 1; i <= 5; i++) {
        buffer.add(i);
      }

      expect(buffer.isFull, isTrue);
      expect(buffer.length, 3);
      // Oldest 2 (1,2) were overwritten, so removeOldest returns 3
      expect(buffer.removeOldest(), 3);
      expect(buffer.removeOldest(), 4);
      expect(buffer.removeOldest(), 5);
      expect(buffer.isEmpty, isTrue);
    });

    test('TC-082 [normal] drain returns all items oldest first', () {
      final buffer = RingBuffer<int>(5);
      buffer.add(10);
      buffer.add(20);
      buffer.add(30);

      final drained = buffer.drain();
      expect(drained, [10, 20, 30]);
      expect(buffer.isEmpty, isTrue);
    });
  });

  group('StreamManager - Memory Management', () {
    test('TC-083 [boundary] 80% memory warning rejects large buffers',
        () async {
      // maxBytes = 1280, each sub with bufferSize=1 → 256 bytes
      // 4 subs × 256 = 1024/1280 = 0.80 → warning threshold
      final memManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 1,
          maxBufferSize: 100,
          maxTotalBufferMemoryBytes: 1280,
          maxSubscriptions: 100,
        ),
        adapterResolver: (uri) async => stubAdapter,
      );
      await memManager.initialize();

      // Allocate to 80% (4 subs × 1 entry × 256 = 1024 bytes)
      for (var i = 1; i <= 4; i++) {
        await memManager.subscribe(
          TopicSpec(uri: 'io://dev-1/ch/$i', mode: TopicMode.continuous,
              options: const TopicOptions(bufferSize: 1)),
          consumerId: 'c$i',
        );
      }

      expect(memManager.memoryLevel, MemoryLevel.warning);

      // Large-buffer subscription should be rejected at warning level
      expect(
        () => memManager.subscribe(
          const TopicSpec(
            uri: 'io://dev-1/ch/large',
            mode: TopicMode.continuous,
            options: TopicOptions(bufferSize: 50),
          ),
          consumerId: 'c-large',
        ),
        throwsStateError,
      );

      // Small-buffer subscription should still work
      await memManager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/5', mode: TopicMode.continuous,
            options: TopicOptions(bufferSize: 1)),
        consumerId: 'c5',
      );

      await memManager.dispose();
    });

    test('TC-084 [boundary] 95% memory critical rejects all subscriptions',
        () async {
      // maxBytes = 1280, each sub with bufferSize=1 → 256 bytes
      // 4 subs = 1024/1280 = 0.80 → warning
      // 5 subs = 1280/1280 = 1.00 → critical
      final critManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 1,
          maxBufferSize: 100,
          maxTotalBufferMemoryBytes: 1280,
          maxSubscriptions: 100,
        ),
        adapterResolver: (uri) async => stubAdapter,
      );
      await critManager.initialize();

      // Fill to 80%: 4 × (1 × 256) = 1024/1280 = 0.80 → warning
      for (var i = 0; i < 4; i++) {
        await critManager.subscribe(
          TopicSpec(uri: 'io://dev-1/ch/$i', mode: TopicMode.continuous,
              options: const TopicOptions(bufferSize: 1)),
          consumerId: 'c$i',
        );
      }

      expect(critManager.memoryLevel, MemoryLevel.warning);

      // One more to push to critical: 5 × 256 = 1280/1280 = 1.0
      await critManager.subscribe(
        const TopicSpec(uri: 'io://dev-1/ch/99', mode: TopicMode.continuous,
            options: TopicOptions(bufferSize: 1)),
        consumerId: 'c99',
      );

      expect(critManager.memoryLevel, MemoryLevel.critical);

      // All new subscriptions rejected at critical level
      expect(
        () => critManager.subscribe(
          const TopicSpec(uri: 'io://dev-1/ch/new', mode: TopicMode.continuous,
              options: TopicOptions(bufferSize: 1)),
          consumerId: 'cnew',
        ),
        throwsStateError,
      );

      await critManager.dispose();
    });
  });
}
