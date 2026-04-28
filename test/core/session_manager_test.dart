import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

void main() {
  late SessionManager manager;
  late DateTime currentTime;

  DateTime clock() => currentTime;

  setUp(() async {
    currentTime = DateTime(2025, 1, 1, 12, 0);
    manager = SessionManager(
      config: const SessionConfig(
        idleTimeout: Duration(minutes: 30),
        maxSessionsPerDevice: 3,
        expiryCheckInterval: Duration(seconds: 1),
      ),
      clock: clock,
    );
    await manager.start();
  });

  tearDown(() async {
    await manager.dispose();
  });

  group('SessionManager - Open', () {
    test('TC-105 [normal] Open session returns sessionId', () {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );
      expect(sessionId, isNotEmpty);
    });

    test('TC-106 [normal] Open multiple sessions for same device', () {
      final s1 = manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      final s2 = manager.openSession(deviceId: 'dev-1', actorId: 'a2');
      expect(s1, isNot(equals(s2)));
      expect(manager.activeCount, 2);
    });

    test('TC-107 [error] Exceed maxSessionsPerDevice throws', () {
      manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      manager.openSession(deviceId: 'dev-1', actorId: 'a2');
      manager.openSession(deviceId: 'dev-1', actorId: 'a3');

      expect(
        () => manager.openSession(deviceId: 'dev-1', actorId: 'a4'),
        throwsStateError,
      );
    });

    test('TC-108 [boundary] Max sessions per device does not affect other devices',
        () {
      manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      manager.openSession(deviceId: 'dev-1', actorId: 'a2');
      manager.openSession(deviceId: 'dev-1', actorId: 'a3');

      // Different device should still allow sessions
      final s = manager.openSession(deviceId: 'dev-2', actorId: 'a1');
      expect(s, isNotEmpty);
    });
  });

  group('SessionManager - Touch', () {
    test('TC-109 [normal] Touch updates lastActivityAt', () {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      currentTime = currentTime.add(const Duration(minutes: 5));
      manager.touchSession(sessionId);

      final session = manager.getSession(sessionId);
      expect(session, isNotNull);
      expect(session!.lastActivityAt, currentTime);
    });

    test('TC-110 [error] Touch non-existent session throws', () {
      expect(
        () => manager.touchSession('nonexistent'),
        throwsStateError,
      );
    });

    test('TC-111 [error] Touch expired session throws', () async {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      // Advance time past idle timeout
      currentTime = currentTime.add(const Duration(minutes: 31));

      // Manually trigger expiry check
      await manager.closeSession(sessionId);

      expect(
        () => manager.touchSession(sessionId),
        throwsStateError,
      );
    });
  });

  group('SessionManager - Close', () {
    test('TC-112 [normal] Close session removes it', () async {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      expect(manager.activeCount, 1);
      await manager.closeSession(sessionId);
      expect(manager.activeCount, 0);
    });

    test('TC-113 [error] Close non-existent session throws', () {
      expect(
        () => manager.closeSession('nonexistent'),
        throwsStateError,
      );
    });

    test('TC-114 [normal] Close invokes callback', () async {
      String? closedSessionId;
      String? closedDeviceId;

      final mgr = SessionManager(
        config: const SessionConfig.defaults(),
        onSessionClosed: (sessionId, deviceId) async {
          closedSessionId = sessionId;
          closedDeviceId = deviceId;
        },
        clock: clock,
      );
      await mgr.start();

      final sessionId = mgr.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );
      await mgr.closeSession(sessionId);

      expect(closedSessionId, sessionId);
      expect(closedDeviceId, 'dev-1');
      await mgr.dispose();
    });
  });

  group('SessionManager - Active Count', () {
    test('TC-115 [normal] Active count tracks sessions', () {
      expect(manager.activeCount, 0);
      manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      expect(manager.activeCount, 1);
      manager.openSession(deviceId: 'dev-2', actorId: 'a2');
      expect(manager.activeCount, 2);
    });

    test('TC-116 [normal] Active count decreases on close', () async {
      final s1 = manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      manager.openSession(deviceId: 'dev-2', actorId: 'a2');

      await manager.closeSession(s1);
      expect(manager.activeCount, 1);
    });
  });

  group('SessionManager - CloseAll', () {
    test('TC-117 [normal] CloseAll removes all sessions', () async {
      manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      manager.openSession(deviceId: 'dev-2', actorId: 'a2');
      manager.openSession(deviceId: 'dev-3', actorId: 'a3');

      await manager.closeAll();
      expect(manager.activeCount, 0);
    });

    test('TC-118 [normal] CloseAll invokes callbacks for each session',
        () async {
      final closedIds = <String>[];

      final mgr = SessionManager(
        config: const SessionConfig.defaults(),
        onSessionClosed: (sessionId, deviceId) async {
          closedIds.add(sessionId);
        },
        clock: clock,
      );
      await mgr.start();

      mgr.openSession(deviceId: 'dev-1', actorId: 'a1');
      mgr.openSession(deviceId: 'dev-2', actorId: 'a2');

      await mgr.closeAll();
      expect(closedIds, hasLength(2));
      await mgr.dispose();
    });
  });

  group('SessionManager - GetSession', () {
    test('TC-119 [normal] Get existing session', () {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      final session = manager.getSession(sessionId);
      expect(session, isNotNull);
      expect(session!.deviceId, 'dev-1');
      expect(session.actorId, 'actor-1');
      expect(session.state, SessionState.active);
    });

    test('TC-120 [boundary] Get non-existent session returns null', () {
      final session = manager.getSession('nonexistent');
      expect(session, isNull);
    });
  });

  group('SessionManager - Defaults', () {
    test('TC-121 [normal] WithDefaults creates working instance', () async {
      final mgr = SessionManager.withDefaults();
      await mgr.start();
      final id = mgr.openSession(deviceId: 'dev-1', actorId: 'a1');
      expect(id, isNotEmpty);
      await mgr.dispose();
    });

    test('TC-122 [normal] Session state is active on creation', () {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      final session = manager.getSession(sessionId);
      expect(session!.state, SessionState.active);
    });
  });

  group('SessionManager - Integration', () {
    test('IT-016 Create → touch → close lifecycle', () async {
      final sessionId = manager.openSession(
        deviceId: 'dev-1',
        actorId: 'actor-1',
      );

      // Touch to keep alive
      currentTime = currentTime.add(const Duration(minutes: 10));
      manager.touchSession(sessionId);

      final session = manager.getSession(sessionId);
      expect(session!.state, SessionState.active);

      // Close
      await manager.closeSession(sessionId);
      expect(manager.activeCount, 0);
    });

    test('IT-017 Cleanup callback invoked on close', () async {
      final cleanedUp = <String>[];

      final mgr = SessionManager(
        config: const SessionConfig.defaults(),
        onSessionClosed: (sessionId, deviceId) async {
          cleanedUp.add(deviceId);
        },
        clock: clock,
      );
      await mgr.start();

      final s1 = mgr.openSession(deviceId: 'dev-1', actorId: 'a1');
      final s2 = mgr.openSession(deviceId: 'dev-2', actorId: 'a2');

      await mgr.closeSession(s1);
      await mgr.closeSession(s2);

      expect(cleanedUp, ['dev-1', 'dev-2']);
      await mgr.dispose();
    });

    test('IT-018 Multiple devices with independent session limits', () {
      // 3 sessions per device
      manager.openSession(deviceId: 'dev-1', actorId: 'a1');
      manager.openSession(deviceId: 'dev-1', actorId: 'a2');
      manager.openSession(deviceId: 'dev-1', actorId: 'a3');

      manager.openSession(deviceId: 'dev-2', actorId: 'a1');
      manager.openSession(deviceId: 'dev-2', actorId: 'a2');

      expect(manager.activeCount, 5);

      // dev-1 is at limit
      expect(
        () => manager.openSession(deviceId: 'dev-1', actorId: 'a4'),
        throwsStateError,
      );

      // dev-2 still has capacity
      manager.openSession(deviceId: 'dev-2', actorId: 'a3');
      expect(manager.activeCount, 6);
    });
  });
}
