import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:uuid/uuid.dart';

import '../models/job.dart';

/// Token passed to long-running adapter operations so that they can
/// cooperatively check for cancellation and report progress.
class JobController {
  JobController._({
    required this.jobId,
    required void Function(JobProgress) onProgress,
    required Future<void> Function() onWaitCancellation,
  })  : _onProgress = onProgress,
        _onWaitCancellation = onWaitCancellation;

  final String jobId;
  final void Function(JobProgress) _onProgress;
  final Future<void> Function() _onWaitCancellation;

  /// Adapter calls this to publish progress updates.
  void reportProgress(JobProgress progress) => _onProgress(progress);

  /// Returns a future that completes when cancellation is requested.
  /// Adapter implementations may race their work against this future.
  Future<void> waitForCancellation() => _onWaitCancellation();
}

/// Result of a `JobManager.start` call. Returned synchronously so the
/// caller (typically `IoRuntime.execute`) can hand the `jobId` back to
/// the requester immediately.
class JobHandle {
  JobHandle({required this.jobId, required this.snapshot});

  final String jobId;
  final Job snapshot;
}

/// Configuration for [JobManager].
class JobManagerConfig {
  const JobManagerConfig({
    this.retainTerminal = const Duration(hours: 1),
  });

  const JobManagerConfig.defaults() : this();

  /// How long to keep terminal jobs (completed/failed/cancelled) before
  /// cleanup. Default 1 hour.
  final Duration retainTerminal;
}

/// Internal state of an active job. Lifetime owned by [JobManager].
class _JobEntry {
  _JobEntry({required this.job});

  /// Closed by [JobManager._publish] (closeAfter:true) on terminal
  /// transitions and by [JobManager.dispose] for any survivors.
  // ignore: close_sinks
  final StreamController<Job> progressController =
      StreamController<Job>.broadcast();
  final Completer<void> cancellation = Completer<void>();

  Job job;
}

/// Manages the lifecycle of long-running jobs.
class JobManager {
  JobManager({
    JobManagerConfig? config,
    DateTime Function()? clock,
  })  : _config = config ?? const JobManagerConfig.defaults(),
        _clock = clock ?? DateTime.now;

  final JobManagerConfig _config;
  final DateTime Function() _clock;
  final Uuid _uuid = const Uuid();
  final Map<String, _JobEntry> _entries = {};

  /// Start a new job. The runner runs in the background; the snapshot is
  /// returned synchronously so the caller can release the inbound
  /// `execute` future with `CommandResult { result: { jobId } }`.
  ///
  /// `runner` receives a [JobController] and returns the final
  /// [PayloadEnvelope] on success. Throwing from the runner records the
  /// job as `failed`. Honouring cancellation is the runner's
  /// responsibility (typically via `controller.waitForCancellation`).
  JobHandle start({
    required String capability,
    required Future<PayloadEnvelope> Function(JobController controller)
        runner,
  }) {
    final jobId = _uuid.v4();
    final initial = Job(
      jobId: jobId,
      capability: capability,
      status: JobStatus.running,
      progress: const JobProgress(current: 0, total: 0),
      startedAt: _clock(),
    );
    final entry = _JobEntry(job: initial);
    _entries[jobId] = entry;
    entry.progressController.add(initial);

    final controller = JobController._(
      jobId: jobId,
      onProgress: (p) => _publish(jobId, (j) => j.copyWith(progress: p)),
      onWaitCancellation: () => entry.cancellation.future,
    );

    // Launch in microtask so caller observes `running` first.
    Future<void>.microtask(() async {
      try {
        final result = await runner(controller);
        _publish(jobId, (j) {
          if (j.status == JobStatus.cancelled) return j;
          return j.copyWith(
            status: JobStatus.completed,
            result: result,
            finishedAt: _clock(),
          );
        }, closeAfter: true);
      } on Object catch (error) {
        _publish(jobId, (j) {
          if (j.status == JobStatus.cancelled) return j;
          return j.copyWith(
            status: JobStatus.failed,
            error: IoError(
              code: 'job.failed',
              message: '$error',
              timestamp: _clock(),
            ),
            finishedAt: _clock(),
          );
        }, closeAfter: true);
      }
    });

    return JobHandle(jobId: jobId, snapshot: initial);
  }

  /// Get a snapshot of a job, or null when unknown.
  Job? get(String jobId) => _entries[jobId]?.job;

  /// Stream of progress updates for `jobId`. Replays the latest snapshot
  /// on subscribe so late subscribers see the current state.
  Stream<Job> progress(String jobId) {
    final entry = _entries[jobId];
    if (entry == null) {
      return Stream.error(StateError('job.not_found: $jobId'));
    }
    return _replayingStream(entry);
  }

  /// All jobs (active + retained terminal). Sorted by `startedAt` desc.
  List<Job> list() {
    final jobs = _entries.values.map((e) => e.job).toList();
    jobs.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return jobs;
  }

  /// Cooperatively cancel a job. Returns true when the cancellation
  /// signal was delivered (the runner is then responsible for actually
  /// stopping). Returns false when the job is unknown or already
  /// terminal.
  bool cancel(String jobId, {String? cancelledBy}) {
    final entry = _entries[jobId];
    if (entry == null) return false;
    if (entry.job.status.isTerminal) return false;

    if (!entry.cancellation.isCompleted) {
      entry.cancellation.complete();
    }
    _publish(
      jobId,
      (j) => j.copyWith(
        status: JobStatus.cancelled,
        cancelledBy: cancelledBy,
        finishedAt: _clock(),
      ),
      closeAfter: true,
    );
    return true;
  }

  /// Remove terminal jobs older than [JobManagerConfig.retainTerminal].
  void cleanup() {
    final now = _clock();
    final cutoff = now.subtract(_config.retainTerminal);
    _entries.removeWhere((_, entry) {
      final terminal = entry.job.status.isTerminal;
      final finishedAt = entry.job.finishedAt;
      if (!terminal || finishedAt == null) return false;
      return finishedAt.isBefore(cutoff);
    });
  }

  /// Dispose all controllers. Used on runtime shutdown.
  Future<void> dispose() async {
    for (final entry in _entries.values) {
      if (!entry.cancellation.isCompleted) entry.cancellation.complete();
      await entry.progressController.close();
    }
    _entries.clear();
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  void _publish(
    String jobId,
    Job Function(Job current) update, {
    bool closeAfter = false,
  }) {
    final entry = _entries[jobId];
    if (entry == null) return;
    final next = update(entry.job);
    entry.job = next;
    if (!entry.progressController.isClosed) {
      entry.progressController.add(next);
      if (closeAfter) entry.progressController.close();
    }
  }

  Stream<Job> _replayingStream(_JobEntry entry) {
    late StreamController<Job> ctrl;
    StreamSubscription<Job>? sub;
    ctrl = StreamController<Job>(
      onListen: () {
        // Replay current snapshot.
        ctrl.add(entry.job);
        sub = entry.progressController.stream.listen(
          ctrl.add,
          onError: ctrl.addError,
          onDone: ctrl.close,
        );
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }
}
