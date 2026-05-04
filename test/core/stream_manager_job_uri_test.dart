/// Tests for `StreamManager` job-progress URI routing — `FR-011-05`.
///
/// Validates that subscriptions on `io://<deviceId>/job/<jobId>/progress`
/// pull from the injected `JobManager.progress(jobId)` stream and
/// surface progress snapshots as `PayloadEnvelope` events.
@TestOn('vm')
library;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

PayloadEnvelope _resultEnvelope() => PayloadEnvelope(
      uri: 'io://plc-1/result',
      kind: PayloadKind.commandResult,
      payload: TypedPayload(
        type: PayloadType.scalar,
        value: 'ok',
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: 'plc-1',
      ),
    );

void main() {
  group('StreamManager job-progress URI routing', () {
    late JobManager jobManager;
    late StreamManager streamManager;

    setUp(() async {
      jobManager = JobManager();
      streamManager = StreamManager(
        config: const StreamingConfig(
          defaultBufferSize: 16,
          maxBufferSize: 64,
          maxTotalBufferMemoryBytes: 4 * 1024 * 1024,
          maxSubscriptions: 4,
          defaultBufferPolicy: BackpressurePolicy.dropOldest,
          defaultTtl: Duration.zero,
        ),
        jobManager: jobManager,
      );
      await streamManager.initialize();
    });

    tearDown(() async {
      await streamManager.dispose();
      await jobManager.dispose();
    });

    test('TC-SM-JOB-001 subscribe yields initial pending snapshot', () async {
      final handle = jobManager.start(
        capability: 'firmware.flash',
        runner: (controller) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return _resultEnvelope();
        },
      );

      final sub = await streamManager.subscribe(
        TopicSpec(
          uri: 'io://plc-1/job/${handle.jobId}/progress',
          mode: TopicMode.continuous,
        ),
        consumerId: 'tester',
      );

      final first = await sub.stream.first.timeout(const Duration(seconds: 2));
      expect(first.uri, 'io://plc-1/job/${handle.jobId}/progress');
      expect(first.kind, PayloadKind.event);
      expect(first.payload.type, PayloadType.event);
      final body = first.payload.value as Map<String, dynamic>;
      expect(body['jobId'], handle.jobId);
      expect(body['capability'], 'firmware.flash');

      await streamManager.unsubscribe(sub.handle.subscriptionId);
    });

    test('TC-SM-JOB-002 progress updates flow through subscription',
        () async {
      final handle = jobManager.start(
        capability: 'firmware.flash',
        runner: (controller) async {
          for (var i = 1; i <= 3; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            controller.reportProgress(
                JobProgress(current: i, total: 3));
          }
          return _resultEnvelope();
        },
      );

      final sub = await streamManager.subscribe(
        TopicSpec(
          uri: 'io://plc-1/job/${handle.jobId}/progress',
          mode: TopicMode.continuous,
        ),
        consumerId: 'tester',
      );

      final captured = <Map<String, dynamic>>[];
      final waiter = sub.stream.listen((env) {
        captured.add(env.payload.value as Map<String, dynamic>);
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await waiter.cancel();
      await streamManager.unsubscribe(sub.handle.subscriptionId);

      expect(captured.length, greaterThanOrEqualTo(2));
      for (final s in captured) {
        expect(s['jobId'], handle.jobId);
      }
      final hasProgress = captured.any((s) {
        final p = s['progress'] as Map<String, dynamic>?;
        return p != null && (p['current'] as int) >= 1;
      });
      expect(hasProgress, isTrue);
    });

    test('TC-SM-JOB-003 unknown jobId surfaces error on the stream',
        () async {
      final sub = await streamManager.subscribe(
        const TopicSpec(
          uri: 'io://plc-1/job/nonexistent/progress',
          mode: TopicMode.continuous,
        ),
        consumerId: 'tester',
      );
      Object? captured;
      var done = false;
      final completer = sub.stream.listen(
        (_) {},
        onError: (Object e) => captured = e,
        onDone: () => done = true,
      );
      // Stream is single-shot (Stream.error) — give the runtime a few
      // microtasks to surface the error or close the channel.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await completer.cancel();
      await streamManager.unsubscribe(sub.handle.subscriptionId);
      expect(captured != null || done, isTrue,
          reason: 'unknown jobId must surface error or close the stream');
    });

    test(
        'TC-SM-JOB-004 non-job URI does not consume job stream',
        () async {
      final sub = await streamManager.subscribe(
        const TopicSpec(
          uri: 'io://plc-1/ch/1',
          mode: TopicMode.continuous,
        ),
        consumerId: 'tester',
      );
      var fired = false;
      final l = sub.stream.listen((_) => fired = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await l.cancel();
      expect(fired, isFalse);
      await streamManager.unsubscribe(sub.handle.subscriptionId);
    });
  });
}
