/// Lightweight metrics collector for the IoRuntime and adapters.
///
/// Defines a minimal counter / gauge interface that the runtime calls
/// from hot paths. Hosts may inject any concrete implementation that
/// forwards into Prometheus, OpenTelemetry, etc. The default
/// [InMemoryIoMetrics] keeps counts in process memory for tests and
/// development inspection.
abstract class IoMetrics {
  /// Increment a named counter by [delta] (default 1).
  ///
  /// [labels] are key/value pairs scoped to the counter (e.g.
  /// `{'category': 'transport.timeout'}`). Values must be primitives
  /// (String/num/bool) so that downstream systems can serialize them.
  void incrementCounter(
    String name, {
    int delta = 1,
    Map<String, Object?> labels = const {},
  });

  /// Set a gauge to an absolute value.
  void setGauge(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  });

  /// Record an observation for a histogram (e.g. latency in ms).
  void observe(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  });
}

/// No-op metrics. Default when the host wires nothing.
class NoopIoMetrics implements IoMetrics {
  const NoopIoMetrics();

  @override
  void incrementCounter(
    String name, {
    int delta = 1,
    Map<String, Object?> labels = const {},
  }) {}

  @override
  void setGauge(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  }) {}

  @override
  void observe(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  }) {}
}

/// In-memory implementation. Counters are stored as
/// `<name>|<sortedLabelKVs>` keys.
class InMemoryIoMetrics implements IoMetrics {
  final Map<String, int> _counters = {};
  final Map<String, num> _gauges = {};
  final Map<String, List<num>> _histograms = {};

  @override
  void incrementCounter(
    String name, {
    int delta = 1,
    Map<String, Object?> labels = const {},
  }) {
    final key = _key(name, labels);
    _counters[key] = (_counters[key] ?? 0) + delta;
  }

  @override
  void setGauge(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  }) {
    _gauges[_key(name, labels)] = value;
  }

  @override
  void observe(
    String name,
    num value, {
    Map<String, Object?> labels = const {},
  }) {
    _histograms.putIfAbsent(_key(name, labels), () => <num>[]).add(value);
  }

  /// Snapshot of the current counter values. Read-only copy.
  Map<String, int> counters() => Map.unmodifiable(_counters);

  /// Snapshot of gauge values.
  Map<String, num> gauges() => Map.unmodifiable(_gauges);

  /// Snapshot of histogram observations.
  Map<String, List<num>> histograms() =>
      _histograms.map((k, v) => MapEntry(k, List<num>.unmodifiable(v)));

  /// Reset all metrics. Useful between test cases.
  void reset() {
    _counters.clear();
    _gauges.clear();
    _histograms.clear();
  }

  /// Get a single counter value (without labels) for convenience.
  int counter(String name, {Map<String, Object?> labels = const {}}) =>
      _counters[_key(name, labels)] ?? 0;

  static String _key(String name, Map<String, Object?> labels) {
    if (labels.isEmpty) return name;
    final entries = labels.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tag = entries.map((e) => '${e.key}=${e.value}').join(',');
    return '$name|$tag';
  }
}
