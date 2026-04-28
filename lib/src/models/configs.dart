import 'package:mcp_bundle/mcp_bundle.dart';

/// Configuration for DeviceRegistry.
class RegistryConfig {
  const RegistryConfig({
    this.maxAdapters = 32,
    this.maxDevices = 256,
    this.discoveryTimeout = const Duration(seconds: 10),
    this.autoDiscover = false,
  });

  const RegistryConfig.defaults() : this();

  /// Maximum number of adapters that can be registered.
  final int maxAdapters;

  /// Maximum number of devices that can be registered.
  final int maxDevices;

  /// Timeout for device discovery operations.
  final Duration discoveryTimeout;

  /// Whether to auto-discover devices when an adapter is registered.
  final bool autoDiscover;
}

/// Configuration for automatic reconnection on connection loss.
class ReconnectionConfig {
  const ReconnectionConfig({
    this.autoReconnect = true,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.maxAttempts = 10,
    this.backoffMultiplier = 2.0,
  });

  const ReconnectionConfig.defaults() : this();

  /// Whether to enable automatic reconnection.
  final bool autoReconnect;

  /// Initial delay before first reconnection attempt.
  final Duration initialDelay;

  /// Maximum delay between reconnection attempts.
  final Duration maxDelay;

  /// Maximum number of reconnection attempts.
  final int maxAttempts;

  /// Multiplier for exponential backoff.
  final double backoffMultiplier;
}

/// Configuration for PolicyEngine.
class PolicyEngineConfig {
  const PolicyEngineConfig({
    this.defaultDecision = Decision.deny,
    this.rateLimitCleanupInterval = const Duration(minutes: 5),
    this.evaluationTimeout = const Duration(milliseconds: 50),
    this.planExpiry = const Duration(minutes: 5),
  });

  const PolicyEngineConfig.defaults() : this();

  /// Default decision when no rule matches.
  final Decision defaultDecision;

  /// Interval for cleaning up expired rate limit trackers.
  final Duration rateLimitCleanupInterval;

  /// Maximum time allowed for a single evaluation.
  final Duration evaluationTimeout;

  /// Default expiry duration for pending plans.
  final Duration planExpiry;
}

/// Configuration for AuditTrail.
class AuditConfig {
  const AuditConfig({
    this.maxBatchSize = 100,
    this.flushInterval = const Duration(seconds: 5),
    this.includeStateSnapshot = true,
  });

  const AuditConfig.defaults() : this();

  /// Maximum number of records to batch before flushing.
  final int maxBatchSize;

  /// Interval for flushing batched audit records.
  final Duration flushInterval;

  /// Whether to include device state snapshots in audit records.
  final bool includeStateSnapshot;
}

/// Configuration for StreamManager.
class StreamingConfig {
  const StreamingConfig({
    this.defaultBufferSize = 100,
    this.maxBufferSize = 10000,
    this.maxTotalBufferMemoryBytes = 50 * 1024 * 1024,
    this.maxSubscriptions = 256,
    this.defaultBufferPolicy = BackpressurePolicy.dropOldest,
    this.expiryCheckInterval = const Duration(seconds: 30),
    this.defaultTtl = Duration.zero,
  });

  const StreamingConfig.defaults() : this();

  /// Default buffer size for new subscriptions.
  final int defaultBufferSize;

  /// Maximum buffer size allowed per subscription.
  final int maxBufferSize;

  /// Maximum total buffer memory in bytes across all subscriptions.
  final int maxTotalBufferMemoryBytes;

  /// Maximum number of active subscriptions.
  final int maxSubscriptions;

  /// Default backpressure policy for new subscriptions.
  final BackpressurePolicy defaultBufferPolicy;

  /// Interval for checking subscription expiry.
  final Duration expiryCheckInterval;

  /// Default TTL for subscriptions (Duration.zero = no expiry).
  final Duration defaultTtl;
}

/// Configuration for CommandQueue.
class CommandQueueConfig {
  const CommandQueueConfig({
    this.defaultMaxQueueDepth = 100,
    this.overflowPolicy = 'reject',
    this.defaultConcurrency = 1,
    this.idempotencyTtl = const Duration(minutes: 10),
  });

  const CommandQueueConfig.defaults() : this();

  /// Default maximum queue depth per device.
  final int defaultMaxQueueDepth;

  /// Policy when queue is full: 'reject' or 'drop_oldest'.
  final String overflowPolicy;

  /// Default maximum concurrent commands per device.
  final int defaultConcurrency;

  /// TTL for idempotency cache entries.
  final Duration idempotencyTtl;
}

/// Configuration for SessionManager.
class SessionConfig {
  const SessionConfig({
    this.idleTimeout = const Duration(minutes: 30),
    this.maxSessionsPerDevice = 10,
    this.expiryCheckInterval = const Duration(minutes: 1),
  });

  const SessionConfig.defaults() : this();

  /// Duration of inactivity before a session is expired.
  final Duration idleTimeout;

  /// Maximum number of sessions allowed per device.
  final int maxSessionsPerDevice;

  /// Interval for checking session expiry.
  final Duration expiryCheckInterval;
}
