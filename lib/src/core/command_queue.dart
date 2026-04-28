import 'dart:async';
import 'dart:collection';

import 'package:mcp_bundle/mcp_bundle.dart';

import '../models/configs.dart';
import '../models/session_info.dart';

/// Internal queue entry with priority ordering.
class _QueueEntry implements Comparable<_QueueEntry> {
  _QueueEntry({
    required this.command,
    required this.deviceId,
    required this.priority,
    required this.completer,
    required this.enqueuedAt,
    this.idempotencyKey,
  });

  final Command command;
  final String deviceId;
  final Priority priority;
  final Completer<CommandResult> completer;
  final DateTime enqueuedAt;
  final String? idempotencyKey;

  /// Sort: high priority first, then FIFO by enqueue time.
  @override
  int compareTo(_QueueEntry other) {
    final priorityCompare = priority.index.compareTo(other.priority.index);
    if (priorityCompare != 0) return priorityCompare;
    return enqueuedAt.compareTo(other.enqueuedAt);
  }
}

/// Tracks idempotent command results to prevent duplicate execution.
class _IdempotencyTracker {
  _IdempotencyTracker({required this.ttl});

  final Duration ttl;
  final Map<String, _CachedResult> _cache = {};

  /// Check if a cached result exists for the given key.
  CommandResult? check(String key) {
    final cached = _cache[key];
    if (cached == null) return null;

    if (DateTime.now().difference(cached.recordedAt) > ttl) {
      _cache.remove(key);
      return null;
    }

    return cached.result;
  }

  /// Record a result for future idempotency checks.
  void record(String key, CommandResult result) {
    _cache[key] = _CachedResult(result: result, recordedAt: DateTime.now());
  }

  /// Remove expired cache entries.
  void cleanup() {
    final now = DateTime.now();
    _cache.removeWhere(
      (_, cached) => now.difference(cached.recordedAt) > ttl,
    );
  }
}

class _CachedResult {
  _CachedResult({required this.result, required this.recordedAt});

  final CommandResult result;
  final DateTime recordedAt;
}

/// Callback to execute a command on a device adapter.
typedef CommandExecutor = Future<CommandResult> Function(
  String deviceId,
  Command command,
);

/// Callback to get the max concurrent commands for a device.
typedef ConcurrencyLookup = int Function(String deviceId);

/// Per-device priority command queue with concurrency control.
///
/// Manages command ordering (high > normal > low, FIFO within same
/// priority), concurrent execution limits per device, and idempotency
/// deduplication.
class CommandQueue {
  CommandQueue({
    required this.config,
    CommandExecutor? executor,
    ConcurrencyLookup? concurrencyLookup,
    DateTime Function()? clock,
  })  : _executor = executor,
        _concurrencyLookup =
            concurrencyLookup ?? ((_) => config.defaultConcurrency),
        _clock = clock ?? DateTime.now,
        _idempotency = _IdempotencyTracker(ttl: config.idempotencyTtl);

  /// Factory: create with default configuration.
  factory CommandQueue.withDefaults({
    CommandExecutor? executor,
    ConcurrencyLookup? concurrencyLookup,
  }) =>
      CommandQueue(
        config: const CommandQueueConfig.defaults(),
        executor: executor,
        concurrencyLookup: concurrencyLookup,
      );

  final CommandQueueConfig config;
  final CommandExecutor? _executor;
  final ConcurrencyLookup _concurrencyLookup;
  final DateTime Function() _clock;
  final _IdempotencyTracker _idempotency;

  final Map<String, SplayTreeSet<_QueueEntry>> _queues = {};
  final Map<String, int> _activeCount = {};

  bool _running = false;
  bool _disposed = false;

  /// Start queue processing.
  Future<void> start() async {
    if (_disposed) {
      throw StateError('exec.disposed: command queue has been disposed');
    }
    _running = true;
  }

  /// Stop queue processing. Pending commands are rejected.
  Future<void> stop() async {
    _running = false;

    for (final queue in _queues.values) {
      for (final entry in queue) {
        if (!entry.completer.isCompleted) {
          entry.completer.complete(
            CommandResult(
              status: CommandStatus.rejected,
              error: IoError(
                code: 'exec.queue_stopped',
                message: 'Command queue stopped',
                timestamp: _clock(),
              ),
            ),
          );
        }
      }
      queue.clear();
    }
    _queues.clear();
    _activeCount.clear();
  }

  /// Enqueue a command for a device.
  ///
  /// Returns a Future that completes with the command result.
  /// Throws [StateError] if queue depth limit is exceeded.
  Future<CommandResult> enqueue(
    Command command, {
    required String deviceId,
    Priority priority = Priority.normal,
    String? idempotencyKey,
  }) {
    if (!_running) {
      throw StateError('exec.queue_stopped: command queue is not running');
    }

    // Check idempotency
    if (idempotencyKey != null) {
      final cached = _idempotency.check(idempotencyKey);
      if (cached != null) {
        return Future.value(cached);
      }
    }

    // Check queue depth
    final queue = _queues.putIfAbsent(
      deviceId,
      SplayTreeSet<_QueueEntry>.new,
    );

    if (queue.length >= config.defaultMaxQueueDepth) {
      if (config.overflowPolicy == 'reject') {
        throw StateError(
          'exec.queue_full: max queue depth '
          '(${config.defaultMaxQueueDepth}) reached for device $deviceId',
        );
      }
      // drop_oldest: remove the lowest priority item
      if (queue.isNotEmpty) {
        final oldest = queue.last;
        queue.remove(oldest);
        if (!oldest.completer.isCompleted) {
          oldest.completer.complete(
            CommandResult(
              status: CommandStatus.rejected,
              error: IoError(
                code: 'exec.queue_overflow',
                message: 'Dropped due to queue overflow',
                timestamp: _clock(),
              ),
            ),
          );
        }
      }
    }

    final completer = Completer<CommandResult>();
    final entry = _QueueEntry(
      command: command,
      deviceId: deviceId,
      priority: priority,
      completer: completer,
      enqueuedAt: _clock(),
      idempotencyKey: idempotencyKey,
    );

    queue.add(entry);

    // Trigger processing
    _processQueue(deviceId);

    return completer.future;
  }

  /// Per-device queue depths for monitoring.
  Map<String, int> get depths =>
      _queues.map((deviceId, queue) => MapEntry(deviceId, queue.length));

  /// Process the next command in the device queue if capacity allows.
  void _processQueue(String deviceId) {
    if (!_running || _executor == null) return;

    final queue = _queues[deviceId];
    if (queue == null || queue.isEmpty) return;

    final active = _activeCount[deviceId] ?? 0;
    final maxConcurrent = _concurrencyLookup(deviceId);

    if (active >= maxConcurrent) return;

    final entry = queue.first;
    queue.remove(entry);
    _activeCount[deviceId] = active + 1;

    _executeEntry(entry);
  }

  /// Execute a queue entry and handle the result.
  Future<void> _executeEntry(_QueueEntry entry) async {
    try {
      final result = await _executor!(entry.deviceId, entry.command);

      // Record idempotency
      if (entry.idempotencyKey != null) {
        _idempotency.record(entry.idempotencyKey!, result);
      }

      if (!entry.completer.isCompleted) {
        entry.completer.complete(result);
      }
    } on Object catch (error) {
      final errorResult = CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'exec.failed',
          message: 'Execution failed: $error',
          timestamp: _clock(),
        ),
      );

      if (!entry.completer.isCompleted) {
        entry.completer.complete(errorResult);
      }
    } finally {
      final active = _activeCount[entry.deviceId] ?? 1;
      _activeCount[entry.deviceId] = active - 1;

      // Trigger next command in queue
      _processQueue(entry.deviceId);
    }
  }

  /// Clean up idempotency cache.
  void cleanupIdempotency() {
    _idempotency.cleanup();
  }

  /// Remove all queue entries for a specific device.
  Future<void> drainDevice(String deviceId) async {
    final queue = _queues.remove(deviceId);
    if (queue == null) return;

    for (final entry in queue) {
      if (!entry.completer.isCompleted) {
        entry.completer.complete(
          CommandResult(
            status: CommandStatus.rejected,
            error: IoError(
              code: 'exec.session_closed',
              message: 'Session closed, command drained',
              timestamp: _clock(),
            ),
          ),
        );
      }
    }
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    _disposed = true;
  }
}
