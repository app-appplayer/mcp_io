import 'package:mcp_bundle/mcp_bundle.dart';

import '../models/configs.dart';

/// In-memory audit storage for default/testing usage.
class InMemoryAuditPort implements IoAuditPort {
  final List<IoAuditRecord> _records = [];

  /// Access recorded entries for test assertions.
  List<IoAuditRecord> get records => List.unmodifiable(_records);

  @override
  Future<void> record(IoAuditRecord record) async {
    _records.add(record);
  }

  @override
  Future<List<IoAuditRecord>> query(IoAuditQuery query) async {
    var results = _records.where((r) {
      if (query.deviceId != null && r.deviceId != query.deviceId) return false;
      if (query.actorId != null && r.actorId != query.actorId) return false;
      if (query.type != null && r.type != query.type) return false;
      if (query.from != null && r.requestedAt.isBefore(query.from!)) {
        return false;
      }
      if (query.to != null && r.requestedAt.isAfter(query.to!)) return false;
      return true;
    }).toList();

    final offset = query.offset ?? 0;
    final limit = query.limit ?? 100;

    if (offset > 0) {
      results = results.skip(offset).toList();
    }
    if (results.length > limit) {
      results = results.take(limit).toList();
    }

    return results;
  }

  @override
  Future<void> export(IoAuditExportConfig config) async {
    // No-op for in-memory storage
  }

  /// Clear all recorded entries.
  void clear() {
    _records.clear();
  }
}

/// Audit trail implementing IoAuditPort with Decorator pattern.
///
/// Implements IoAuditPort while holding an internal _storagePort
/// as a delegation target. Performs security filtering (tokenRef removal)
/// and async queuing before delegating actual storage.
class AuditTrail implements IoAuditPort {
  AuditTrail({
    required IoAuditPort storagePort,
    AuditConfig? config,
  })  : _storagePort = storagePort,
        _config = config ?? const AuditConfig.defaults();

  /// Factory: create with default in-memory storage.
  factory AuditTrail.withDefaults() => AuditTrail(
        storagePort: InMemoryAuditPort(),
      );

  final IoAuditPort _storagePort;
  // ignore: unused_field
  final AuditConfig _config;

  @override
  Future<void> record(IoAuditRecord record) async {
    // Security filtering: remove tokenRef from metadata
    final sanitizedRecord = _sanitize(record);

    // Fire-and-forget: delegate to storage without awaiting
    // in production, but await in implementation for testability
    await _storagePort.record(sanitizedRecord);
  }

  @override
  Future<List<IoAuditRecord>> query(IoAuditQuery query) async {
    return _storagePort.query(query);
  }

  @override
  Future<void> export(IoAuditExportConfig config) async {
    await _storagePort.export(config);
  }

  /// Remove security-sensitive fields from audit records.
  IoAuditRecord _sanitize(IoAuditRecord record) {
    if (record.metadata == null) return record;

    final metadata = Map<String, dynamic>.from(record.metadata!);
    metadata.remove('tokenRef');
    metadata.remove('token');
    metadata.remove('secret');

    return IoAuditRecord(
      id: record.id,
      type: record.type,
      actorId: record.actorId,
      actorRole: record.actorRole,
      command: record.command,
      deviceId: record.deviceId,
      policyDecision: record.policyDecision,
      policyTrace: record.policyTrace,
      resultStatus: record.resultStatus,
      requestedAt: record.requestedAt,
      executedAt: record.executedAt,
      completedAt: record.completedAt,
      stateBefore: record.stateBefore,
      stateAfter: record.stateAfter,
      metadata: metadata.isEmpty ? null : metadata,
    );
  }
}
