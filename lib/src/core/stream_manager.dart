import 'dart:async';
import 'dart:math' as math;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:uuid/uuid.dart';

import '../models/configs.dart';

/// Internal ring buffer for backpressure management.
class RingBuffer<T> {
  RingBuffer(this.capacity) : _buffer = List<T?>.filled(capacity, null);

  final int capacity;
  final List<T?> _buffer;
  int _head = 0;
  int _tail = 0;
  int _count = 0;

  bool get isFull => _count == capacity;
  bool get isEmpty => _count == 0;
  int get length => _count;

  /// Add an item to the buffer. Overwrites oldest if full.
  void add(T item) {
    if (isFull) {
      // Overwrite oldest
      _buffer[_tail] = item;
      _head = (_head + 1) % capacity;
      _tail = (_tail + 1) % capacity;
    } else {
      _buffer[_tail] = item;
      _tail = (_tail + 1) % capacity;
      _count++;
    }
  }

  /// Remove and return the oldest item.
  T removeOldest() {
    if (isEmpty) throw StateError('Buffer is empty');
    final item = _buffer[_head] as T;
    _buffer[_head] = null;
    _head = (_head + 1) % capacity;
    _count--;
    return item;
  }

  /// Drain all items oldest first.
  List<T> drain() {
    final items = <T>[];
    while (!isEmpty) {
      items.add(removeOldest());
    }
    return items;
  }
}

// ============================================================================
// Downsampling
// ============================================================================

/// Downsampling method for stream data.
enum DownsampleMethod {
  /// Extract min/max per bucket (peak preserving). Suitable for waveforms.
  minmax,

  /// Average per bucket. Suitable for temperature, pressure trends.
  avg,

  /// Extract every Nth sample. Suitable for low-frequency signals.
  decimate;
}

/// Configuration for downsampling.
class DownsamplingConfig {
  const DownsamplingConfig({
    required this.method,
    required this.factor,
  });

  /// The downsampling algorithm to use.
  final DownsampleMethod method;

  /// The downsampling factor (e.g., 10 means 1/10 output).
  final int factor;
}

/// Applies downsampling algorithms to numeric data lists.
class Downsampler {
  const Downsampler._();

  /// Downsample a list of double values using the specified method and factor.
  static List<double> apply(
    List<double> data,
    DownsampleMethod method,
    int factor,
  ) {
    if (factor <= 1 || data.isEmpty) return List.of(data);

    switch (method) {
      case DownsampleMethod.minmax:
        return _minmax(data, factor);
      case DownsampleMethod.avg:
        return _avg(data, factor);
      case DownsampleMethod.decimate:
        return _decimate(data, factor);
    }
  }

  /// MinMax: extract min and max per bucket (peak preserving).
  static List<double> _minmax(List<double> data, int factor) {
    final result = <double>[];
    for (var i = 0; i < data.length; i += factor) {
      final end = math.min(i + factor, data.length);
      final bucket = data.sublist(i, end);
      var minVal = bucket[0];
      var maxVal = bucket[0];
      for (final v in bucket) {
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
      }
      result.add(minVal);
      if (minVal != maxVal) {
        result.add(maxVal);
      }
    }
    return result;
  }

  /// Avg: average per bucket.
  static List<double> _avg(List<double> data, int factor) {
    final result = <double>[];
    for (var i = 0; i < data.length; i += factor) {
      final end = math.min(i + factor, data.length);
      final bucket = data.sublist(i, end);
      var sum = 0.0;
      for (final v in bucket) {
        sum += v;
      }
      result.add(sum / bucket.length);
    }
    return result;
  }

  /// Decimate: extract every Nth sample.
  static List<double> _decimate(List<double> data, int factor) {
    final result = <double>[];
    for (var i = 0; i < data.length; i += factor) {
      result.add(data[i]);
    }
    return result;
  }
}

// ============================================================================
// Chunking
// ============================================================================

/// Result of chunking a large payload.
class ChunkedEnvelope {
  const ChunkedEnvelope({
    required this.envelope,
    required this.chunkIndex,
    required this.totalChunks,
    required this.isLast,
  });

  final PayloadEnvelope envelope;
  final int chunkIndex;
  final int totalChunks;
  final bool isLast;
}

/// Splits large payloads into smaller chunks.
class PayloadChunker {
  const PayloadChunker._();

  /// Chunk a list payload into pieces of [maxPoints] each.
  ///
  /// Returns the list of chunked envelopes with ChunkMeta attached.
  static List<ChunkedEnvelope> chunk({
    required PayloadEnvelope envelope,
    required int maxPoints,
    required String groupId,
  }) {
    final value = envelope.payload.value;
    if (value is! List || value.length <= maxPoints) {
      return [
        ChunkedEnvelope(
          envelope: envelope,
          chunkIndex: 0,
          totalChunks: 1,
          isLast: true,
        ),
      ];
    }

    final dataList = value;
    final totalChunks = (dataList.length / maxPoints).ceil();
    final result = <ChunkedEnvelope>[];

    for (var i = 0; i < totalChunks; i++) {
      final start = i * maxPoints;
      final end = math.min(start + maxPoints, dataList.length);
      final chunkData = dataList.sublist(start, end);
      final isLast = i == totalChunks - 1;

      final chunkMeta = ChunkMeta(
        index: i,
        total: totalChunks,
        groupId: groupId,
      );

      final chunkedEnvelope = PayloadEnvelope(
        uri: envelope.uri,
        kind: envelope.kind,
        payload: TypedPayload(
          type: envelope.payload.type,
          value: chunkData,
          unit: envelope.payload.unit,
          timestamp: envelope.payload.timestamp,
          quality: envelope.payload.quality,
          source: envelope.payload.source,
        ),
        meta: EnvelopeMeta(
          capturedAt: envelope.meta.capturedAt,
          sourceAddress: envelope.meta.sourceAddress,
          sequenceNumber: envelope.meta.sequenceNumber,
          chunk: chunkMeta,
        ),
      );

      result.add(ChunkedEnvelope(
        envelope: chunkedEnvelope,
        chunkIndex: i,
        totalChunks: totalChunks,
        isLast: isLast,
      ));
    }

    return result;
  }
}

// ============================================================================
// Memory Tracker
// ============================================================================

/// Memory usage level for threshold-based policies.
enum MemoryLevel {
  /// Below 80% - normal operation.
  normal,

  /// 80%~95% - large-buffer subscriptions rejected.
  warning,

  /// Above 95% - all new subscriptions rejected.
  critical;
}

/// Tracks total memory usage across all subscription buffers.
class MemoryTracker {
  MemoryTracker({required this.maxBytes});

  final int maxBytes;
  int _currentBytes = 0;

  int get currentBytes => _currentBytes;

  /// Current memory usage ratio (0.0 ~ 1.0).
  double get usageRatio => maxBytes > 0 ? _currentBytes / maxBytes : 0.0;

  /// Current memory level based on thresholds.
  MemoryLevel get level {
    final ratio = usageRatio;
    if (ratio >= 0.95) return MemoryLevel.critical;
    if (ratio >= 0.80) return MemoryLevel.warning;
    return MemoryLevel.normal;
  }

  /// Check if allocation is possible considering memory thresholds.
  ///
  /// At warning level (80%+): only small buffers (<=defaultBufferSize) allowed.
  /// At critical level (95%+): all allocations rejected.
  bool canAllocate(int bytes, {int? defaultBufferSize}) {
    if ((_currentBytes + bytes) > maxBytes) return false;

    final currentLevel = level;
    if (currentLevel == MemoryLevel.critical) return false;
    if (currentLevel == MemoryLevel.warning && defaultBufferSize != null) {
      // At warning level, only allow small-buffer subscriptions
      final estimatedEntries = bytes ~/ 256;
      if (estimatedEntries > defaultBufferSize) return false;
    }

    return true;
  }

  void allocate(int bytes) {
    _currentBytes += bytes;
  }

  void release(int bytes) {
    _currentBytes -= bytes;
    if (_currentBytes < 0) _currentBytes = 0;
  }
}

/// Internal subscription tracking entry.
class _SubscriptionEntry {
  _SubscriptionEntry({
    required this.handle,
    required this.controller,
    required this.buffer,
    required this.backpressure,
    required this.consumerId,
    this.expiresAt,
    this.downsamplingConfig,
  });

  final SubscriptionHandle handle;
  final StreamController<PayloadEnvelope> controller;
  final RingBuffer<PayloadEnvelope> buffer;
  final BackpressurePolicy backpressure;
  final String consumerId;
  // Lifetime tied to _SubscriptionEntry; cancelled in removeSubscription.
  // ignore: cancel_subscriptions
  StreamSubscription<PayloadEnvelope>? sourceSubscription;
  final DateTime? expiresAt;

  final DownsamplingConfig? downsamplingConfig;
  int messagesDelivered = 0;
  int messagesDropped = 0;
  DateTime? lastMessageAt;
  bool active = true;
  int allocatedBytes = 0;
}

/// Callback to resolve a URI to its device adapter.
typedef AdapterResolver = Future<IoDevicePort?> Function(String uri);

/// Manages streaming subscriptions with backpressure and TTL.
///
/// Implements [IoStreamPort] with RingBuffer-based backpressure handling,
/// memory tracking, and automatic TTL-based subscription expiry.
class StreamManager implements IoStreamPort {
  StreamManager({
    required this.config,
    AdapterResolver? adapterResolver,
    DateTime Function()? clock,
  })  : _adapterResolver = adapterResolver,
        _clock = clock ?? DateTime.now;

  /// Factory: create with default configuration.
  factory StreamManager.withDefaults({
    AdapterResolver? adapterResolver,
  }) =>
      StreamManager(
        config: const StreamingConfig.defaults(),
        adapterResolver: adapterResolver,
      );

  final StreamingConfig config;
  final AdapterResolver? _adapterResolver;
  final DateTime Function() _clock;
  final Map<String, _SubscriptionEntry> _subscriptions = {};
  final Uuid _uuid = const Uuid();
  late final MemoryTracker _memory =
      MemoryTracker(maxBytes: config.maxTotalBufferMemoryBytes);
  Timer? _expiryTimer;

  /// Initialize the stream manager and start the expiry timer.
  ///
  /// The expiry timer runs regardless of defaultTtl, since individual
  /// subscriptions can specify their own TTL via TopicOptions.ttlSeconds.
  Future<void> initialize() async {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(
      config.expiryCheckInterval,
      (_) => _checkExpiry(),
    );
  }

  /// Close all subscriptions and stop the expiry timer.
  Future<void> closeAll() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    final ids = _subscriptions.keys.toList();
    for (final id in ids) {
      await _removeSubscription(id);
    }
  }

  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
    DownsamplingConfig? downsampling,
  }) async {
    // Check subscription limit
    if (_subscriptions.length >= config.maxSubscriptions) {
      throw StateError(
        'stream.max_subscriptions: max subscriptions '
        '(${config.maxSubscriptions}) reached',
      );
    }

    // Determine buffer size and check memory
    final bufferSize = spec.options?.bufferSize ?? config.defaultBufferSize;
    final effectiveBufferSize = bufferSize.clamp(1, config.maxBufferSize);
    final estimatedBytes = effectiveBufferSize * 256; // estimate per entry

    if (!_memory.canAllocate(
      estimatedBytes,
      defaultBufferSize: config.defaultBufferSize,
    )) {
      throw StateError(
        'stream.memory_exceeded: total buffer memory limit exceeded',
      );
    }

    final subscriptionId = _uuid.v4();
    final now = _clock();
    final ttlSeconds = spec.options?.ttlSeconds;
    final ttl = ttlSeconds != null && ttlSeconds > 0
        ? Duration(seconds: ttlSeconds)
        : config.defaultTtl;
    final expiresAt = ttl != Duration.zero ? now.add(ttl) : null;

    final backpressure =
        spec.options?.backpressure ?? config.defaultBufferPolicy;

    final handle = SubscriptionHandle(
      subscriptionId: subscriptionId,
      topic: spec.uri,
      mode: spec.mode,
      createdAt: now.millisecondsSinceEpoch,
      expiresAt: expiresAt?.millisecondsSinceEpoch,
    );

    // Controller is stored in _SubscriptionEntry and closed in removeSubscription.
    // ignore: close_sinks
    final controller = StreamController<PayloadEnvelope>.broadcast();
    final buffer = RingBuffer<PayloadEnvelope>(effectiveBufferSize);

    final entry = _SubscriptionEntry(
      handle: handle,
      controller: controller,
      buffer: buffer,
      backpressure: backpressure,
      consumerId: consumerId,
      expiresAt: expiresAt,
      downsamplingConfig: downsampling,
    );
    entry.allocatedBytes = estimatedBytes;

    _memory.allocate(estimatedBytes);
    _subscriptions[subscriptionId] = entry;

    // Resolve adapter and subscribe to source stream
    if (_adapterResolver != null) {
      try {
        final adapter = await _adapterResolver(spec.uri);
        if (adapter != null) {
          final sourceStream = adapter.subscribe(spec);
          entry.sourceSubscription = sourceStream.listen(
            (envelope) => _onData(envelope, entry),
            onError: (Object error) => _onSourceError(error, entry),
            onDone: () => _onSourceDone(entry),
          );
        }
      } on Object {
        // Adapter resolution failure — subscription exists but has no source
      }
    }

    return IoStreamSubscription(
      handle: handle,
      stream: controller.stream,
    );
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {
    await _removeSubscription(subscriptionId);
  }

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    return _subscriptions.values
        .where((entry) {
          if (!entry.active) return false;
          if (consumerId != null && entry.consumerId != consumerId) {
            return false;
          }
          if (deviceId != null && !entry.handle.topic.contains(deviceId)) {
            return false;
          }
          return true;
        })
        .map((entry) => entry.handle)
        .toList();
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async {
    final entry = _subscriptions[subscriptionId];
    if (entry == null) return null;

    return SubscriptionStatus(
      subscriptionId: subscriptionId,
      active: entry.active,
      messagesDelivered: entry.messagesDelivered,
      messagesDropped: entry.messagesDropped,
      bufferUsed: entry.buffer.length,
      bufferCapacity: entry.buffer.capacity,
      lastMessageAt: entry.lastMessageAt,
    );
  }

  /// Number of active subscriptions.
  int get subscriptionCount =>
      _subscriptions.values.where((e) => e.active).length;

  /// Total buffer memory usage in bytes.
  int get totalBufferBytes => _memory.currentBytes;

  /// Current memory usage level (normal, warning, critical).
  MemoryLevel get memoryLevel => _memory.level;

  /// Trigger an expiry check manually (useful for testing).
  Future<void> checkExpiry() => _checkExpiry();

  /// Handle incoming data from adapter source stream.
  ///
  /// Applies downsampling if configured, then manages backpressure.
  void _onData(PayloadEnvelope envelope, _SubscriptionEntry entry) {
    if (!entry.active) return;

    // Apply downsampling if configured (FR-004-04)
    final effectiveEnvelope = _applyDownsampling(envelope, entry);

    if (entry.buffer.isFull) {
      switch (entry.backpressure) {
        case BackpressurePolicy.dropOldest:
          entry.buffer.removeOldest();
          entry.messagesDropped++;
        case BackpressurePolicy.dropNewest:
          entry.messagesDropped++;
          return;
        case BackpressurePolicy.block:
          entry.sourceSubscription?.pause();
          entry.messagesDropped++;
          return;
      }
    }

    entry.buffer.add(effectiveEnvelope);
    entry.messagesDelivered++;
    entry.lastMessageAt = _clock();

    // Flush buffer to consumer
    _flushBuffer(entry);
  }

  /// Apply downsampling to an envelope if the subscription has a config.
  PayloadEnvelope _applyDownsampling(
    PayloadEnvelope envelope,
    _SubscriptionEntry entry,
  ) {
    final dsConfig = entry.downsamplingConfig;
    if (dsConfig == null) return envelope;

    final value = envelope.payload.value;
    if (value is! List<double>) return envelope;
    if (value.length <= dsConfig.factor) return envelope;

    final downsampled = Downsampler.apply(value, dsConfig.method, dsConfig.factor);

    return PayloadEnvelope(
      uri: envelope.uri,
      kind: envelope.kind,
      payload: TypedPayload(
        type: envelope.payload.type,
        value: downsampled,
        unit: envelope.payload.unit,
        timestamp: envelope.payload.timestamp,
        quality: envelope.payload.quality,
        source: envelope.payload.source,
      ),
      meta: envelope.meta,
    );
  }

  /// Flush buffered items to the consumer stream.
  void _flushBuffer(_SubscriptionEntry entry) {
    while (!entry.buffer.isEmpty && !entry.controller.isClosed) {
      final item = entry.buffer.removeOldest();
      entry.controller.add(item);
    }

    // Resume source if it was paused (block policy)
    if (entry.backpressure == BackpressurePolicy.block &&
        !entry.buffer.isFull) {
      entry.sourceSubscription?.resume();
    }
  }

  /// Handle source stream errors.
  void _onSourceError(Object error, _SubscriptionEntry entry) {
    if (!entry.controller.isClosed) {
      entry.controller.addError(error);
    }
  }

  /// Handle source stream completion.
  void _onSourceDone(_SubscriptionEntry entry) {
    _flushBuffer(entry);
    _removeSubscription(entry.handle.subscriptionId);
  }

  /// Check for expired subscriptions based on TTL.
  Future<void> _checkExpiry() async {
    final now = _clock();
    final toExpire = <String>[];

    for (final entry in _subscriptions.entries) {
      if (entry.value.expiresAt != null &&
          now.isAfter(entry.value.expiresAt!)) {
        toExpire.add(entry.key);
      }
    }

    for (final id in toExpire) {
      await _removeSubscription(id);
    }
  }

  /// Remove a subscription and release its resources.
  Future<void> _removeSubscription(String subscriptionId) async {
    final entry = _subscriptions.remove(subscriptionId);
    if (entry == null) return;

    entry.active = false;
    await entry.sourceSubscription?.cancel();
    entry.buffer.drain();

    if (!entry.controller.isClosed) {
      await entry.controller.close();
    }

    _memory.release(entry.allocatedBytes);
  }

  /// Remove all subscriptions for a specific device.
  Future<void> removeByDevice(String deviceId) async {
    final toRemove = _subscriptions.entries
        .where((e) => e.value.handle.topic.contains(deviceId))
        .map((e) => e.key)
        .toList();

    for (final id in toRemove) {
      await _removeSubscription(id);
    }
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await closeAll();
  }
}
