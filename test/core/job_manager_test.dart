import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

PayloadEnvelope _envelope({Object? value = 'ok'}) => PayloadEnvelope(
      uri: 'io://test/job/result',
      kind: PayloadKind.event,
      payload: TypedPayload(
        type: PayloadType.scalar,
        value: value,
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: 'test',
      ),
    );

void main() {
  late JobManager manager;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 5, 2, 10, 0);
    manager = JobManager(
      config: const JobManagerConfig(retainTerminal: Duration(hours: 1)),
      clock: () => now,
    );
  });

  tearDown(() async {
    await manager.dispose();
  });

  group('JobManager - lifecycle', () {
    test('TC-JOB-001 [normal] start returns running snapshot', () {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => _envelope(),
      );

      expect(handle.jobId, isNotEmpty);
      expect(handle.snapshot.status, JobStatus.running);
      expect(handle.snapshot.capability, 'scope.run_recipe');
    });

    test('TC-JOB-002 [normal] runner completes → JobStatus.completed',
        () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => _envelope(value: 42),
      );

      // Wait for microtask to run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final snapshot = manager.get(handle.jobId);
      expect(snapshot, isNotNull);
      expect(snapshot!.status, JobStatus.completed);
      expect(snapshot.result, isNotNull);
      expect(snapshot.result!.payload.value, 42);
      expect(snapshot.finishedAt, isNotNull);
    });

    test('TC-JOB-003 [normal] runner throws → JobStatus.failed', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => throw StateError('boom'),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final snapshot = manager.get(handle.jobId);
      expect(snapshot, isNotNull);
      expect(snapshot!.status, JobStatus.failed);
      expect(snapshot.error, isNotNull);
      expect(snapshot.error!.code, 'job.failed');
      expect(snapshot.error!.message, contains('boom'));
    });

    test('TC-JOB-004 [normal] cancel delivers signal + status', () async {
      var runnerNoticedCancel = false;
      final completer = Completer<PayloadEnvelope>();

      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (controller) async {
          unawaited(controller.waitForCancellation().then((_) {
            runnerNoticedCancel = true;
            completer.complete(_envelope(value: 'never'));
          }));
          return completer.future;
        },
      );

      await Future<void>.delayed(Duration.zero);

      final ok = manager.cancel(handle.jobId, cancelledBy: 'admin');
      expect(ok, isTrue);

      // Allow runner future to process cancellation
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(runnerNoticedCancel, isTrue);
      final snapshot = manager.get(handle.jobId);
      expect(snapshot!.status, JobStatus.cancelled);
      expect(snapshot.cancelledBy, 'admin');
    });

    test('TC-JOB-005 [error] cancel terminal job returns false', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => _envelope(),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final ok = manager.cancel(handle.jobId);
      expect(ok, isFalse);
    });

    test('TC-JOB-006 [error] cancel unknown job returns false', () {
      expect(manager.cancel('nonexistent'), isFalse);
    });
  });

  group('JobManager - progress', () {
    test('TC-JOB-010 [normal] reportProgress publishes snapshot', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (controller) async {
          for (var i = 1; i <= 3; i++) {
            controller.reportProgress(JobProgress(
              current: i,
              total: 3,
              message: 'step $i',
            ));
          }
          return _envelope();
        },
      );

      final snapshots = <Job>[];
      final sub = manager.progress(handle.jobId).listen(snapshots.add);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // Replay (initial) + 3 progress + completed = 5 minimum
      expect(snapshots.length, greaterThanOrEqualTo(4));
      expect(snapshots.last.status, JobStatus.completed);
    });

    test('TC-JOB-011 [normal] late subscriber gets replay', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (controller) async {
          controller.reportProgress(const JobProgress(current: 1, total: 1));
          return _envelope();
        },
      );

      // Wait for runner to finish before subscribing.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final snapshots = <Job>[];
      final sub = manager.progress(handle.jobId).listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // Late subscriber gets at least the current (terminal) snapshot.
      expect(snapshots, isNotEmpty);
      expect(snapshots.first.status, JobStatus.completed);
    });
  });

  group('JobManager - cleanup', () {
    test('TC-JOB-020 [normal] terminal jobs survive within TTL', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => _envelope(),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(minutes: 30));
      manager.cleanup();

      expect(manager.get(handle.jobId), isNotNull);
    });

    test('TC-JOB-021 [normal] terminal jobs evicted past TTL', () async {
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => _envelope(),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(hours: 2));
      manager.cleanup();

      expect(manager.get(handle.jobId), isNull);
    });

    test('TC-JOB-022 [normal] running jobs not evicted by cleanup', () async {
      final completer = Completer<PayloadEnvelope>();
      final handle = manager.start(
        capability: 'scope.run_recipe',
        runner: (_) async => completer.future,
      );
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(hours: 24));
      manager.cleanup();

      expect(manager.get(handle.jobId), isNotNull);
      expect(manager.get(handle.jobId)!.status, JobStatus.running);

      completer.complete(_envelope());
    });

    test('TC-JOB-023 [normal] list returns most-recent-first', () async {
      final h1 = manager.start(
          capability: 'a', runner: (_) async => _envelope());
      now = now.add(const Duration(seconds: 1));
      final h2 = manager.start(
          capability: 'b', runner: (_) async => _envelope());

      final list = manager.list();
      expect(list.length, 2);
      expect(list.first.jobId, h2.jobId);
      expect(list.last.jobId, h1.jobId);
    });
  });

  group('JobProgress', () {
    test('TC-JOB-030 [normal] percent computed', () {
      const p = JobProgress(current: 25, total: 100);
      expect(p.percent, 25.0);
    });

    test('TC-JOB-031 [boundary] indeterminate (total=0) → -1', () {
      const p = JobProgress(current: 5, total: 0);
      expect(p.percent, -1.0);
    });
  });
}
