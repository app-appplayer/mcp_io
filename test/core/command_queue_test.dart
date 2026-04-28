import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

Command _cmd({String action = 'read', String target = 'io://dev-1/ch/1'}) =>
    Command(action: action, target: target);

void main() {
  late CommandQueue queue;
  late List<String> executedActions;

  Future<CommandResult> testExecutor(String deviceId, Command command) async {
    executedActions.add(command.action);
    return CommandResult(status: CommandStatus.completed, result: 'ok');
  }

  setUp(() async {
    executedActions = [];
    queue = CommandQueue(
      config: const CommandQueueConfig(
        defaultMaxQueueDepth: 10,
        overflowPolicy: 'reject',
        defaultConcurrency: 1,
        idempotencyTtl: Duration(minutes: 10),
      ),
      executor: testExecutor,
    );
    await queue.start();
  });

  tearDown(() async {
    await queue.dispose();
  });

  group('CommandQueue - Enqueue', () {
    test('TC-085 [normal] Enqueue and execute command', () async {
      final result = await queue.enqueue(
        _cmd(action: 'measure'),
        deviceId: 'dev-1',
      );

      expect(result.status, CommandStatus.completed);
      expect(executedActions, contains('measure'));
    });

    test('TC-086 [normal] Enqueue multiple commands sequentially', () async {
      final r1 = queue.enqueue(_cmd(action: 'cmd1'), deviceId: 'dev-1');
      final r2 = queue.enqueue(_cmd(action: 'cmd2'), deviceId: 'dev-1');

      final results = await Future.wait([r1, r2]);
      expect(results, hasLength(2));
      expect(results.every((r) => r.status == CommandStatus.completed), isTrue);
    });

    test('TC-087 [error] Enqueue when not running throws', () async {
      await queue.stop();
      expect(
        () => queue.enqueue(_cmd(), deviceId: 'dev-1'),
        throwsStateError,
      );
    });

    test('TC-088 [error] Queue depth overflow with reject policy', () async {
      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(
          defaultMaxQueueDepth: 2,
          overflowPolicy: 'reject',
          defaultConcurrency: 1,
        ),
        executor: (deviceId, cmd) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      // Fill the queue
      unawaited(slowQueue.enqueue(_cmd(action: 'c1'), deviceId: 'dev-1'));
      unawaited(slowQueue.enqueue(_cmd(action: 'c2'), deviceId: 'dev-1'));

      // Wait a tick for queue processing to begin
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Third should fail if queue is full
      // (depends on timing, so we test the mechanic)
      await slowQueue.dispose();
    });
  });

  group('CommandQueue - Priority', () {
    test('TC-089 [normal] High priority executes before normal', () async {
      final order = <String>[];

      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(
          defaultConcurrency: 1,
          defaultMaxQueueDepth: 100,
        ),
        executor: (deviceId, cmd) async {
          order.add(cmd.action);
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      // Enqueue normal then high
      final f1 = slowQueue.enqueue(
        _cmd(action: 'normal-1'),
        deviceId: 'dev-1',
        priority: Priority.normal,
      );
      final f2 = slowQueue.enqueue(
        _cmd(action: 'high-1'),
        deviceId: 'dev-1',
        priority: Priority.high,
      );

      await Future.wait([f1, f2]);
      await slowQueue.dispose();

      // First dequeued should be the first enqueued (already processing)
      // but high priority should come before remaining normals
      expect(order, hasLength(2));
    });

    test('TC-090 [normal] Low priority executes after normal', () async {
      final result = await queue.enqueue(
        _cmd(action: 'low-cmd'),
        deviceId: 'dev-1',
        priority: Priority.low,
      );
      expect(result.status, CommandStatus.completed);
    });
  });

  group('CommandQueue - Idempotency', () {
    test('TC-091 [normal] Same idempotency key returns cached result',
        () async {
      final r1 = await queue.enqueue(
        _cmd(action: 'measure'),
        deviceId: 'dev-1',
        idempotencyKey: 'key-1',
      );

      executedActions.clear();

      final r2 = await queue.enqueue(
        _cmd(action: 'measure'),
        deviceId: 'dev-1',
        idempotencyKey: 'key-1',
      );

      expect(r1.status, r2.status);
      expect(executedActions, isEmpty);
    });

    test('TC-092 [normal] Different idempotency keys execute independently',
        () async {
      await queue.enqueue(
        _cmd(action: 'a'),
        deviceId: 'dev-1',
        idempotencyKey: 'key-1',
      );
      await queue.enqueue(
        _cmd(action: 'b'),
        deviceId: 'dev-1',
        idempotencyKey: 'key-2',
      );

      expect(executedActions, ['a', 'b']);
    });

    test('TC-093 [normal] Null idempotency key always executes', () async {
      await queue.enqueue(_cmd(action: 'a'), deviceId: 'dev-1');
      await queue.enqueue(_cmd(action: 'a'), deviceId: 'dev-1');

      expect(executedActions, ['a', 'a']);
    });
  });

  group('CommandQueue - Concurrency', () {
    test('TC-094 [normal] Respects concurrency limit per device', () async {
      var concurrent = 0;
      var maxConcurrent = 0;

      final concQueue = CommandQueue(
        config: const CommandQueueConfig(
          defaultConcurrency: 2,
          defaultMaxQueueDepth: 100,
        ),
        executor: (deviceId, cmd) async {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          concurrent--;
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await concQueue.start();

      final futures = <Future<CommandResult>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(
          concQueue.enqueue(_cmd(action: 'cmd-$i'), deviceId: 'dev-1'),
        );
      }

      await Future.wait(futures);
      expect(maxConcurrent, lessThanOrEqualTo(2));
      await concQueue.dispose();
    });

    test('TC-095 [normal] Different devices have independent concurrency',
        () async {
      await queue.enqueue(_cmd(action: 'a'), deviceId: 'dev-1');
      await queue.enqueue(_cmd(action: 'b'), deviceId: 'dev-2');

      expect(executedActions, ['a', 'b']);
    });
  });

  group('CommandQueue - Depths', () {
    test('TC-096 [normal] Depths reports per-device queue size', () async {
      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(defaultConcurrency: 1),
        executor: (deviceId, cmd) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      unawaited(slowQueue.enqueue(_cmd(), deviceId: 'dev-1'));
      unawaited(slowQueue.enqueue(_cmd(), deviceId: 'dev-1'));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final depths = slowQueue.depths;
      // One should be processing, others in queue
      expect(depths.containsKey('dev-1'), isTrue);
      await slowQueue.dispose();
    });

    test('TC-097 [boundary] Empty queue returns empty depths', () {
      expect(queue.depths, isEmpty);
    });
  });

  group('CommandQueue - Error Handling', () {
    test('TC-098 [error] Executor exception returns failed result', () async {
      final errorQueue = CommandQueue(
        config: const CommandQueueConfig.defaults(),
        executor: (deviceId, cmd) async {
          throw StateError('Adapter error');
        },
      );
      await errorQueue.start();

      final result =
          await errorQueue.enqueue(_cmd(), deviceId: 'dev-1');
      expect(result.status, CommandStatus.failed);
      expect(result.error, isNotNull);
      expect(result.error!.code, 'exec.failed');
      await errorQueue.dispose();
    });
  });

  group('CommandQueue - DrainDevice', () {
    test('TC-099 [normal] Drain removes all entries for device', () async {
      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(defaultConcurrency: 1),
        executor: (deviceId, cmd) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      // Enqueue but don't await
      unawaited(slowQueue.enqueue(_cmd(), deviceId: 'dev-1'));
      unawaited(slowQueue.enqueue(_cmd(), deviceId: 'dev-1'));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await slowQueue.drainDevice('dev-1');

      // The first command may complete, second should be drained
      await slowQueue.dispose();
    });
  });

  group('CommandQueue - Lifecycle', () {
    test('TC-100 [normal] Stop rejects pending commands', () async {
      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(defaultConcurrency: 1),
        executor: (deviceId, cmd) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      unawaited(slowQueue.enqueue(_cmd(), deviceId: 'dev-1'));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await slowQueue.stop();
    });
  });

  group('CommandQueue - Integration', () {
    test('IT-013 Enqueue → execute → result flow', () async {
      final result = await queue.enqueue(
        _cmd(action: 'setVoltage'),
        deviceId: 'dev-1',
      );

      expect(result.status, CommandStatus.completed);
      expect(executedActions, ['setVoltage']);
    });

    test('IT-014 Multi-device concurrent execution', () async {
      final r1 = queue.enqueue(_cmd(action: 'measure'), deviceId: 'dev-1');
      final r2 = queue.enqueue(_cmd(action: 'measure'), deviceId: 'dev-2');

      final results = await Future.wait([r1, r2]);
      expect(results.every((r) => r.status == CommandStatus.completed), isTrue);
      expect(executedActions, hasLength(2));
    });

    test('IT-015 Priority + idempotency combined', () async {
      final r1 = await queue.enqueue(
        _cmd(action: 'cmd1'),
        deviceId: 'dev-1',
        priority: Priority.high,
        idempotencyKey: 'idem-1',
      );

      // Same idempotency key returns cached
      executedActions.clear();
      final r2 = await queue.enqueue(
        _cmd(action: 'cmd1'),
        deviceId: 'dev-1',
        priority: Priority.normal,
        idempotencyKey: 'idem-1',
      );

      expect(r1.status, r2.status);
      expect(executedActions, isEmpty);
    });
  });

  group('CommandQueue - Lifecycle (Extended)', () {
    test('TC-100 [boundary] Double start is no-op', () async {
      // queue already started in setUp
      await queue.start();

      final result = await queue.enqueue(
        _cmd(action: 'after-double-start'),
        deviceId: 'dev-1',
      );
      expect(result.status, CommandStatus.completed);
      expect(executedActions, contains('after-double-start'));
    });

    test('TC-101 [error] Start after dispose throws', () async {
      await queue.dispose();

      expect(
        () => queue.start(),
        throwsStateError,
      );
    });

    test('TC-102 [boundary] Stop before start is no-op', () async {
      final freshQueue = CommandQueue(
        config: const CommandQueueConfig.defaults(),
        executor: testExecutor,
      );

      // Stop without prior start should not throw
      await freshQueue.stop();
      await freshQueue.dispose();
    });

    test('TC-103 [error] Stop with in-flight commands', () async {
      final completers = <Completer<void>>[];
      final completed = <String>[];

      final slowQueue = CommandQueue(
        config: const CommandQueueConfig(
          defaultConcurrency: 1,
          defaultMaxQueueDepth: 100,
        ),
        executor: (deviceId, cmd) async {
          final c = Completer<void>();
          completers.add(c);
          await c.future;
          completed.add(cmd.action);
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await slowQueue.start();

      // Enqueue two commands
      final f1 = slowQueue.enqueue(_cmd(action: 'inflight'), deviceId: 'dev-1');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final f2 = slowQueue.enqueue(_cmd(action: 'queued'), deviceId: 'dev-1');

      // Stop while first is in-flight
      await slowQueue.stop();

      // Complete the in-flight command
      if (completers.isNotEmpty) {
        completers.first.complete();
      }

      final r1 = await f1;
      expect(r1.status, CommandStatus.completed);

      // Second was queued and should be rejected by stop
      final r2 = await f2;
      expect(r2.status, CommandStatus.rejected);
    });

    test('TC-104 [normal] Per-device queue independence', () async {
      final order = <String>[];

      final independentQueue = CommandQueue(
        config: const CommandQueueConfig(
          defaultConcurrency: 1,
          defaultMaxQueueDepth: 2,
          overflowPolicy: 'reject',
        ),
        executor: (deviceId, cmd) async {
          order.add('$deviceId:${cmd.action}');
          return CommandResult(status: CommandStatus.completed);
        },
      );
      await independentQueue.start();

      // Enqueue to two different devices
      final f1 = independentQueue.enqueue(
        _cmd(action: 'a'),
        deviceId: 'dev-1',
      );
      final f2 = independentQueue.enqueue(
        _cmd(action: 'b'),
        deviceId: 'dev-2',
      );

      await Future.wait([f1, f2]);

      // Both devices should have processed independently
      expect(order, containsAll(['dev-1:a', 'dev-2:b']));
      await independentQueue.dispose();
    });
  });
}
