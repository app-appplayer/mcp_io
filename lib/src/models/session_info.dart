/// State of a session in its lifecycle.
enum SessionState {
  /// Session is actively being used.
  active,

  /// Session has been idle beyond the warning threshold.
  idle,

  /// Session has expired due to idle timeout.
  expired,

  /// Session has been explicitly closed.
  closed;
}

/// Information about an active session.
class SessionInfo {
  SessionInfo({
    required this.sessionId,
    required this.deviceId,
    required this.actorId,
    required this.createdAt,
    required this.lastActivityAt,
    this.state = SessionState.active,
  });

  /// Create from JSON.
  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      sessionId: json['sessionId'] as String,
      deviceId: json['deviceId'] as String,
      actorId: json['actorId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastActivityAt: DateTime.parse(json['lastActivityAt'] as String),
      state: SessionState.values.byName(json['state'] as String),
    );
  }

  /// Unique session identifier.
  final String sessionId;

  /// Device this session is associated with.
  final String deviceId;

  /// Actor who owns this session.
  final String actorId;

  /// When the session was created.
  final DateTime createdAt;

  /// When the session was last active.
  DateTime lastActivityAt;

  /// Current session state.
  SessionState state;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'deviceId': deviceId,
        'actorId': actorId,
        'createdAt': createdAt.toIso8601String(),
        'lastActivityAt': lastActivityAt.toIso8601String(),
        'state': state.name,
      };
}

/// Command execution priority.
enum Priority {
  /// Highest priority, processed first.
  high,

  /// Default priority.
  normal,

  /// Lowest priority, processed last.
  low;
}
