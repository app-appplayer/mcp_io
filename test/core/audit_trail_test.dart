import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

IoAuditRecord _record({
  String id = 'rec-1',
  IoAuditType type = IoAuditType.execute,
  String actorId = 'actor-1',
  String actorRole = 'operator',
  String deviceId = 'dev-1',
  Map<String, dynamic>? metadata,
}) =>
    IoAuditRecord(
      id: id,
      type: type,
      actorId: actorId,
      actorRole: actorRole,
      deviceId: deviceId,
      requestedAt: DateTime.now(),
      metadata: metadata,
    );

void main() {
  group('InMemoryAuditPort', () {
    late InMemoryAuditPort store;

    setUp(() {
      store = InMemoryAuditPort();
    });

    test('TC-043 [normal] Record and retrieve audit entry', () async {
      final record = _record();
      await store.record(record);

      expect(store.records, hasLength(1));
      expect(store.records.first.id, 'rec-1');
    });

    test('TC-044 [normal] Query by deviceId', () async {
      await store.record(_record(id: 'r1', deviceId: 'dev-1'));
      await store.record(_record(id: 'r2', deviceId: 'dev-2'));

      final results =
          await store.query(const IoAuditQuery(deviceId: 'dev-1'));
      expect(results, hasLength(1));
      expect(results.first.deviceId, 'dev-1');
    });

    test('TC-045 [normal] Query by actorId', () async {
      await store.record(_record(id: 'r1', actorId: 'actor-1'));
      await store.record(_record(id: 'r2', actorId: 'actor-2'));

      final results =
          await store.query(const IoAuditQuery(actorId: 'actor-1'));
      expect(results, hasLength(1));
      expect(results.first.actorId, 'actor-1');
    });

    test('TC-046 [normal] Query by type', () async {
      await store.record(
          _record(id: 'r1', type: IoAuditType.execute));
      await store.record(
          _record(id: 'r2', type: IoAuditType.emergencyStop));

      final results =
          await store.query(const IoAuditQuery(type: IoAuditType.execute));
      expect(results, hasLength(1));
      expect(results.first.type, IoAuditType.execute);
    });

    test('TC-047 [normal] Query with time range', () async {
      final now = DateTime.now();
      await store.record(IoAuditRecord(
        id: 'r1',
        type: IoAuditType.execute,
        actorId: 'a',
        actorRole: 'op',
        deviceId: 'd',
        requestedAt: now.subtract(const Duration(hours: 2)),
      ));
      await store.record(IoAuditRecord(
        id: 'r2',
        type: IoAuditType.execute,
        actorId: 'a',
        actorRole: 'op',
        deviceId: 'd',
        requestedAt: now,
      ));

      final results = await store.query(IoAuditQuery(
        from: now.subtract(const Duration(hours: 1)),
      ));
      expect(results, hasLength(1));
      expect(results.first.id, 'r2');
    });

    test('TC-048 [boundary] Query with limit', () async {
      for (var i = 0; i < 10; i++) {
        await store.record(_record(id: 'r$i'));
      }

      final results = await store.query(const IoAuditQuery(limit: 3));
      expect(results, hasLength(3));
    });

    test('TC-049 [boundary] Query with offset', () async {
      for (var i = 0; i < 5; i++) {
        await store.record(_record(id: 'r$i'));
      }

      final results = await store.query(const IoAuditQuery(offset: 3));
      expect(results, hasLength(2));
    });

    test('TC-050 [boundary] Query empty store returns empty list', () async {
      final results = await store.query(const IoAuditQuery());
      expect(results, isEmpty);
    });

    test('TC-051 [normal] Clear removes all records', () async {
      await store.record(_record());
      store.clear();
      expect(store.records, isEmpty);
    });
  });

  group('AuditTrail - Decorator', () {
    late InMemoryAuditPort storage;
    late AuditTrail auditTrail;

    setUp(() {
      storage = InMemoryAuditPort();
      auditTrail = AuditTrail(storagePort: storage);
    });

    test('TC-052 [normal] Record delegates to storage', () async {
      await auditTrail.record(_record());
      expect(storage.records, hasLength(1));
    });

    test('TC-053 [normal] Query delegates to storage', () async {
      await auditTrail.record(_record(deviceId: 'dev-1'));
      final results =
          await auditTrail.query(const IoAuditQuery(deviceId: 'dev-1'));
      expect(results, hasLength(1));
    });

    test('TC-054 [normal] Security filtering removes tokenRef', () async {
      await auditTrail.record(_record(
        metadata: {'tokenRef': 'secret-token', 'info': 'keep'},
      ));

      final recorded = storage.records.first;
      expect(recorded.metadata, isNotNull);
      expect(recorded.metadata!.containsKey('tokenRef'), isFalse);
      expect(recorded.metadata!['info'], 'keep');
    });

    test('TC-055 [normal] Security filtering removes token', () async {
      await auditTrail.record(_record(
        metadata: {'token': 'my-token'},
      ));

      final recorded = storage.records.first;
      expect(recorded.metadata, isNull);
    });

    test('TC-056 [normal] Security filtering removes secret', () async {
      await auditTrail.record(_record(
        metadata: {'secret': 'my-secret'},
      ));

      final recorded = storage.records.first;
      expect(recorded.metadata, isNull);
    });

    test('TC-057 [boundary] Record without metadata passes through', () async {
      await auditTrail.record(_record());
      expect(storage.records.first.metadata, isNull);
    });

    test('TC-058 [normal] Export delegates to storage', () async {
      await auditTrail.export(const IoAuditExportConfig(
        query: IoAuditQuery(),
        targetSystem: 'test',
      ));
      // No error means success (InMemoryAuditPort export is no-op)
    });
  });

  group('AuditTrail - Integration', () {
    test('IT-007 Record → query → verify flow', () async {
      final storage = InMemoryAuditPort();
      final auditTrail = AuditTrail(storagePort: storage);

      await auditTrail.record(_record(id: 'exec-1', deviceId: 'dev-1'));
      await auditTrail.record(_record(
        id: 'exec-2',
        deviceId: 'dev-2',
        type: IoAuditType.emergencyStop,
      ));

      final devResults =
          await auditTrail.query(const IoAuditQuery(deviceId: 'dev-1'));
      expect(devResults, hasLength(1));

      final allResults = await auditTrail.query(const IoAuditQuery());
      expect(allResults, hasLength(2));
    });

    test('IT-008 Security filtering across multiple records', () async {
      final storage = InMemoryAuditPort();
      final auditTrail = AuditTrail(storagePort: storage);

      await auditTrail.record(_record(
        id: 'r1',
        metadata: {'tokenRef': 'secret', 'data': 'ok'},
      ));
      await auditTrail.record(_record(
        id: 'r2',
        metadata: {'token': 't', 'secret': 's'},
      ));
      await auditTrail.record(_record(id: 'r3'));

      expect(storage.records[0].metadata!.containsKey('tokenRef'), isFalse);
      expect(storage.records[0].metadata!['data'], 'ok');
      expect(storage.records[1].metadata, isNull);
      expect(storage.records[2].metadata, isNull);
    });

    test('IT-009 AuditTrail.withDefaults creates working instance', () async {
      final trail = AuditTrail.withDefaults();
      await trail.record(_record());
      final results = await trail.query(const IoAuditQuery());
      expect(results, hasLength(1));
    });
  });
}
