import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/configs.dart';
import '../models/session_info.dart';

/// Callback invoked when a session is closed or expired.
typedef SessionClosedCallback = Future<void> Function(
  String sessionId,
  String deviceId,
);

/// Manages device sessions with idle timeout and automatic expiry.
///
/// Handles session creation (UUID), activity refresh, idle expiry,
/// and cleanup of related subscriptions and queue items via callback.
class SessionManager {
  SessionManager({
    required this.config,
    SessionClosedCallback? onSessionClosed,
    DateTime Function()? clock,
  })  : _onSessionClosed = onSessionClosed,
        _clock = clock ?? DateTime.now;

  /// Factory: create with default configuration.
  factory SessionManager.withDefaults({
    SessionClosedCallback? onSessionClosed,
  }) =>
      SessionManager(
        config: const SessionConfig.defaults(),
        onSessionClosed: onSessionClosed,
      );

  final SessionConfig config;
  final SessionClosedCallback? _onSessionClosed;
  final DateTime Function() _clock;
  final Map<String, SessionInfo> _sessions = {};
  final Uuid _uuid = const Uuid();
  Timer? _expiryTimer;

  /// Start the session manager's expiry check timer.
  Future<void> start() async {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(
      config.expiryCheckInterval,
      (_) => _checkExpiry(),
    );
  }

  /// Close all sessions and stop the expiry timer.
  Future<void> closeAll() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    final sessionIds = _sessions.keys.toList();
    for (final sessionId in sessionIds) {
      await _closeSessionInternal(sessionId);
    }
  }

  /// Open a new session for a device and actor.
  ///
  /// Returns the generated session ID.
  /// Throws [StateError] if maxSessionsPerDevice is exceeded.
  String openSession({
    required String deviceId,
    required String actorId,
  }) {
    final deviceSessionCount = _sessions.values
        .where(
          (s) =>
              s.deviceId == deviceId &&
              (s.state == SessionState.active || s.state == SessionState.idle),
        )
        .length;

    if (deviceSessionCount >= config.maxSessionsPerDevice) {
      throw StateError(
        'session.max_exceeded: max sessions per device '
        '(${config.maxSessionsPerDevice}) reached for $deviceId',
      );
    }

    final sessionId = _uuid.v4();
    final now = _clock();

    _sessions[sessionId] = SessionInfo(
      sessionId: sessionId,
      deviceId: deviceId,
      actorId: actorId,
      createdAt: now,
      lastActivityAt: now,
      state: SessionState.active,
    );

    return sessionId;
  }

  /// Refresh session activity timestamp.
  ///
  /// Throws [StateError] if session not found or expired.
  void touchSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('session.not_found: session $sessionId not found');
    }

    if (session.state == SessionState.expired ||
        session.state == SessionState.closed) {
      throw StateError('session.expired: session $sessionId is ${session.state.name}');
    }

    session.lastActivityAt = _clock();
    session.state = SessionState.active;
  }

  /// Close a session and trigger cleanup callback.
  Future<void> closeSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('session.not_found: session $sessionId not found');
    }

    await _closeSessionInternal(sessionId);
  }

  /// Get session info by ID.
  SessionInfo? getSession(String sessionId) => _sessions[sessionId];

  /// Number of active (non-closed, non-expired) sessions.
  int get activeCount => _sessions.values
      .where(
        (s) => s.state == SessionState.active || s.state == SessionState.idle,
      )
      .length;

  /// Check for expired sessions based on idle timeout.
  Future<void> _checkExpiry() async {
    final now = _clock();
    final toExpire = <String>[];

    for (final entry in _sessions.entries) {
      final session = entry.value;
      if (session.state == SessionState.closed ||
          session.state == SessionState.expired) {
        continue;
      }

      final idleDuration = now.difference(session.lastActivityAt);
      if (idleDuration >= config.idleTimeout) {
        toExpire.add(entry.key);
      } else if (idleDuration >= config.idleTimeout ~/ 2) {
        session.state = SessionState.idle;
      }
    }

    for (final sessionId in toExpire) {
      final session = _sessions[sessionId];
      if (session != null) {
        session.state = SessionState.expired;
        if (_onSessionClosed != null) {
          await _onSessionClosed(sessionId, session.deviceId);
        }
        _sessions.remove(sessionId);
      }
    }
  }

  /// Internal close: update state, invoke callback, remove entry.
  Future<void> _closeSessionInternal(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    session.state = SessionState.closed;

    if (_onSessionClosed != null) {
      await _onSessionClosed(sessionId, session.deviceId);
    }

    _sessions.remove(sessionId);
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await closeAll();
  }
}
