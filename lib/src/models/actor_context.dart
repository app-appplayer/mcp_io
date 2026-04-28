/// Actor context for identifying who is performing an operation.
class ActorContext {
  const ActorContext({
    required this.actorId,
    required this.role,
  });

  /// Create from JSON.
  factory ActorContext.fromJson(Map<String, dynamic> json) {
    return ActorContext(
      actorId: json['actorId'] as String,
      role: json['role'] as String,
    );
  }

  /// Unique identifier for the actor.
  final String actorId;

  /// Role of the actor (e.g., 'operator', 'skill', 'system', 'admin').
  final String role;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        'actorId': actorId,
        'role': role,
      };

  @override
  String toString() => 'ActorContext(actorId: $actorId, role: $role)';
}
