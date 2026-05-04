import 'package:mcp_io/mcp_io.dart';
import 'package:test/test.dart';

void main() {
  group('NoopIoMetrics', () {
    test('TC-MET-001 [normal] No-op accepts any call', () {
      const metrics = NoopIoMetrics();
      expect(() => metrics.incrementCounter('x'), returnsNormally);
      expect(() => metrics.setGauge('y', 1), returnsNormally);
      expect(() => metrics.observe('z', 1.5), returnsNormally);
    });
  });

  group('InMemoryIoMetrics', () {
    late InMemoryIoMetrics metrics;
    setUp(() => metrics = InMemoryIoMetrics());

    test('TC-MET-010 [normal] increment counter', () {
      metrics.incrementCounter('io.request.count');
      metrics.incrementCounter('io.request.count');
      expect(metrics.counter('io.request.count'), 2);
    });

    test('TC-MET-011 [normal] increment with delta', () {
      metrics.incrementCounter('io.bytes', delta: 100);
      metrics.incrementCounter('io.bytes', delta: 50);
      expect(metrics.counter('io.bytes'), 150);
    });

    test('TC-MET-012 [normal] labels separate counters', () {
      metrics.incrementCounter('io.request.count', labels: {'op': 'read'});
      metrics.incrementCounter('io.request.count', labels: {'op': 'execute'});
      metrics.incrementCounter('io.request.count', labels: {'op': 'read'});
      expect(metrics.counter('io.request.count', labels: {'op': 'read'}), 2);
      expect(
          metrics.counter('io.request.count', labels: {'op': 'execute'}), 1);
    });

    test('TC-MET-013 [normal] labels are sorted for stable keys', () {
      metrics.incrementCounter('m', labels: {'a': '1', 'b': '2'});
      metrics.incrementCounter('m', labels: {'b': '2', 'a': '1'});
      // Same key regardless of insertion order.
      expect(metrics.counter('m', labels: {'a': '1', 'b': '2'}), 2);
    });

    test('TC-MET-020 [normal] gauge stores latest value', () {
      metrics.setGauge('queue.depth', 5);
      metrics.setGauge('queue.depth', 7);
      expect(metrics.gauges()['queue.depth'], 7);
    });

    test('TC-MET-030 [normal] histogram records observations', () {
      metrics.observe('latency.ms', 12);
      metrics.observe('latency.ms', 30);
      metrics.observe('latency.ms', 8);
      final hist = metrics.histograms()['latency.ms'];
      expect(hist, isNotNull);
      expect(hist!.length, 3);
      expect(hist, containsAll(<num>[12, 30, 8]));
    });

    test('TC-MET-040 [normal] reset clears all', () {
      metrics.incrementCounter('a');
      metrics.setGauge('b', 1);
      metrics.observe('c', 1);
      metrics.reset();
      expect(metrics.counters(), isEmpty);
      expect(metrics.gauges(), isEmpty);
      expect(metrics.histograms(), isEmpty);
    });
  });
}
