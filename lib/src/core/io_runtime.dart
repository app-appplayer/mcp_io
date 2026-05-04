import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart' hide PolicyRule, PolicyCondition;

import '../models/actor_context.dart';
import '../models/configs.dart';
import '../models/job.dart';
import 'audit_trail.dart';
import 'command_queue.dart';
import 'device_registry.dart';
import 'io_metrics.dart';
import 'job_manager.dart';
import 'policy_engine.dart';
import 'session_manager.dart';
import 'stream_manager.dart';

/// Composite configuration for all IoRuntime modules.
class IoRuntimeConfig {
  const IoRuntimeConfig({
    this.registry = const RegistryConfig.defaults(),
    this.policy = const PolicyEngineConfig.defaults(),
    this.streaming = const StreamingConfig.defaults(),
    this.commandQueue = const CommandQueueConfig.defaults(),
    this.session = const SessionConfig.defaults(),
    this.reconnection = const ReconnectionConfig.defaults(),
    this.jobs = const JobManagerConfig.defaults(),
  });

  const IoRuntimeConfig.defaults() : this();

  final RegistryConfig registry;
  final PolicyEngineConfig policy;
  final StreamingConfig streaming;
  final CommandQueueConfig commandQueue;
  final SessionConfig session;
  final ReconnectionConfig reconnection;
  final JobManagerConfig jobs;
}

/// Central I/O runtime orchestrator.
///
/// Owns all core modules, handles their lifecycle, wires inter-module
/// dependencies, and dispatches the 4-Primitive Contract operations
/// (describe, read, execute, subscribe) plus emergency stop.
class IoRuntime {
  IoRuntime({
    IoRuntimeConfig? config,
    required IoPolicyPort policyPort,
    required IoAuditPort auditPort,
    IoMetrics? metrics,
  })  : config = config ?? const IoRuntimeConfig.defaults(),
        _metrics = metrics ?? const NoopIoMetrics() {
    _registry = DeviceRegistry(
      config: this.config.registry,
      reconnectionConfig: this.config.reconnection,
    );

    _policyEngine = PolicyEngine(
      ruleStore: policyPort,
      config: this.config.policy,
    );

    _auditTrail = AuditTrail(storagePort: auditPort);

    _streamManager = StreamManager(
      config: this.config.streaming,
      adapterResolver: (String uri) => _registry.resolveAdapter(uri),
    );

    _commandQueue = CommandQueue(
      config: this.config.commandQueue,
      executor: _executeOnAdapter,
    );

    _sessionManager = SessionManager(
      config: this.config.session,
      onSessionClosed: _onSessionClosed,
    );

    _jobManager = JobManager(config: this.config.jobs);
  }

  final IoRuntimeConfig config;

  late final DeviceRegistry _registry;
  late final PolicyEngine _policyEngine;
  late final AuditTrail _auditTrail;
  late final StreamManager _streamManager;
  late final CommandQueue _commandQueue;
  late final SessionManager _sessionManager;
  late final JobManager _jobManager;

  final IoMetrics _metrics;

  /// Access the device registry for adapter/device management.
  DeviceRegistry get registry => _registry;

  /// Access the policy engine for rule management.
  PolicyEngine get policyEngine => _policyEngine;

  /// Access the audit trail for querying records.
  AuditTrail get auditTrail => _auditTrail;

  /// Access the stream manager for subscription management.
  StreamManager get streamManager => _streamManager;

  /// Access the session manager for session management.
  SessionManager get sessionManager => _sessionManager;

  /// Access the job manager for long-running job lifecycle.
  JobManager get jobManager => _jobManager;

  /// Access the metrics sink. Hosts inject their own [IoMetrics]
  /// implementation in the constructor; default is [NoopIoMetrics].
  IoMetrics get metrics => _metrics;

  /// Initialize runtime and all core modules.
  Future<void> initialize() async {
    await _registry.initialize();
    await _policyEngine.initialize();
    await _streamManager.initialize();
    await _commandQueue.start();
    await _sessionManager.start();
  }

  /// Shutdown runtime and cleanup all resources.
  Future<void> shutdown() async {
    await _commandQueue.stop();
    await _streamManager.closeAll();
    await _sessionManager.closeAll();
    await _registry.disconnectAll();
  }

  // -----------------------------------------------------------------------
  // 4-Primitive dispatch
  // -----------------------------------------------------------------------

  /// Describe a device by its ID.
  Future<DeviceDescriptor?> describe(String deviceId) async {
    return _registry.get(deviceId);
  }

  /// Read from device resources.
  Future<ReadResult> read(
    ReadSpec spec, {
    ActorContext? actor,
  }) async {
    final items = <ReadResultItem>[];
    _metrics.incrementCounter('io.request.count',
        labels: {'op': 'read', 'targets': spec.targets.length});

    for (final target in spec.targets) {
      try {
        final adapter = await _registry.resolveAdapter('io://$target');
        if (adapter == null) {
          items.add(ReadResultItem(
            uri: target,
            error: IoError(
              code: 'device.not_found',
              message: 'No adapter found for target: $target',
              timestamp: DateTime.now(),
            ),
          ));
          _metrics.incrementCounter('io.request.error.count',
              labels: {'op': 'read', 'code': 'device.not_found'});
          continue;
        }

        final result = await adapter
            .read(ReadSpec(targets: [target], options: spec.options));
        items.addAll(result.items);
        for (final item in result.items) {
          if (item.error != null) {
            _metrics.incrementCounter('io.request.error.count',
                labels: {'op': 'read', 'code': item.error!.code});
          }
        }
      } on Object catch (error) {
        items.add(ReadResultItem(
          uri: target,
          error: IoError(
            code: 'exec.failed',
            message: 'Read failed: $error',
            timestamp: DateTime.now(),
          ),
        ));
        _metrics.incrementCounter('io.request.error.count',
            labels: {'op': 'read', 'code': 'exec.failed'});
      }
    }

    return ReadResult(items: items);
  }

  /// Execute a command with policy enforcement.
  ///
  /// Evaluates the command against policy rules, then queues it
  /// for execution on the target device adapter.
  Future<CommandResult> execute(
    Command command, {
    required ActorContext actor,
  }) async {
    final now = DateTime.now();
    _metrics.incrementCounter('io.request.count',
        labels: {'op': 'execute', 'action': command.action});

    // Resolve device descriptor for policy evaluation
    final deviceId = _extractDeviceId(command.target);
    final device = deviceId != null ? await _registry.get(deviceId) : null;

    if (device == null) {
      _metrics.incrementCounter('io.request.error.count',
          labels: {'op': 'execute', 'code': 'device.not_found'});
      return CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'device.not_found',
          message: 'No device found for target: ${command.target}',
          timestamp: now,
        ),
      );
    }

    // Policy evaluation with live interlock evaluator.
    final decision = await _policyEngine.evaluate(
      command: command,
      actor: actor,
      device: device,
      interlockEvaluator: _evaluateInterlock,
    );
    _metrics.incrementCounter('io.policy.decision.count',
        labels: {'decision': decision.decision.name});

    // Record audit
    await _auditTrail.record(IoAuditRecord(
      id: '${command.action}:${command.target}:${now.millisecondsSinceEpoch}',
      type: IoAuditType.execute,
      actorId: actor.actorId,
      actorRole: actor.role,
      command: command,
      deviceId: device.deviceId,
      policyDecision: decision,
      requestedAt: now,
    ));

    switch (decision.decision) {
      case Decision.deny:
        return CommandResult(
          status: CommandStatus.rejected,
          policyTrace: PolicyTrace(
            commandId: '${command.action}:${command.target}',
            ruleId: decision.ruleId,
            evaluatedAt: now,
            finalDecision: Decision.deny,
            finalNotes: decision.notes,
          ),
        );

      case Decision.needsApproval:
      case Decision.needsPlan:
        return CommandResult(
          status: CommandStatus.needsApproval,
          policyTrace: PolicyTrace(
            commandId: '${command.action}:${command.target}',
            ruleId: decision.ruleId,
            evaluatedAt: now,
            finalDecision: decision.decision,
            finalNotes: decision.notes,
          ),
        );

      case Decision.allow:
        // Enqueue for execution
        return _commandQueue.enqueue(
          command,
          deviceId: device.deviceId,
        );
    }
  }

  /// Subscribe to a device topic for real-time data.
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
    ActorContext? actor,
  }) async {
    return _streamManager.subscribe(spec, consumerId: consumerId);
  }

  /// Emergency stop — bypasses policy and command queue.
  Future<EmergencyStopResult> emergencyStop(
    EmergencyStopRequest request,
  ) async {
    final now = DateTime.now();
    _metrics.incrementCounter('io.estop.count',
        labels: {'scope': request.deviceId == null ? 'all' : 'single'});

    try {
      EmergencyStopResult result;

      if (request.deviceId != null) {
        // Stop specific device
        final adapter =
            await _registry.resolveAdapter('io://${request.deviceId}');
        if (adapter == null) {
          result = EmergencyStopResult(
            success: false,
            error: IoError(
              code: 'device.not_found',
              message: 'No adapter for device: ${request.deviceId}',
              timestamp: now,
            ),
          );
        } else {
          result = await adapter.emergencyStop(request);
        }
      } else {
        // Stop all devices
        final devices = await _registry.list();
        final stoppedDevices = <String>[];

        for (final device in devices) {
          try {
            final adapter =
                await _registry.resolveAdapter('io://${device.deviceId}');
            if (adapter != null) {
              await adapter.emergencyStop(request);
              stoppedDevices.add(device.deviceId);
            }
          } on Object {
            // Best-effort stop for each device
          }
        }

        result = EmergencyStopResult(
          success: true,
          stoppedDevices: stoppedDevices,
        );
      }

      // Post-hoc audit recording
      await _auditTrail.record(IoAuditRecord(
        id: 'estop:${now.millisecondsSinceEpoch}',
        type: IoAuditType.emergencyStop,
        actorId: request.actorId,
        actorRole: 'system',
        deviceId: request.deviceId ?? 'all',
        requestedAt: now,
        executedAt: now,
        completedAt: DateTime.now(),
      ));

      return result;
    } on Object catch (error) {
      return EmergencyStopResult(
        success: false,
        error: IoError(
          code: 'estop.failed',
          message: 'Emergency stop failed: $error',
          timestamp: now,
        ),
      );
    }
  }

  // -----------------------------------------------------------------------
  // Internal wiring
  // -----------------------------------------------------------------------

  /// Execute a command on the resolved adapter (called by CommandQueue).
  Future<CommandResult> _executeOnAdapter(
    String deviceId,
    Command command,
  ) async {
    final adapter = await _registry.resolveAdapter('io://$deviceId');
    if (adapter == null) {
      return CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'device.not_found',
          message: 'No adapter found for device: $deviceId',
          timestamp: DateTime.now(),
        ),
      );
    }

    // Capture state before execution.
    Map<String, dynamic>? stateBefore;
    try {
      final desc = await adapter.describe();
      stateBefore = <String, dynamic>{
        'deviceId': desc.deviceId,
        'connectionState': desc.connectionState.name,
      };
    } on Object {
      // Best-effort state capture
    }

    final result = await adapter.execute(command);

    // Capture state after execution.
    Map<String, dynamic>? stateAfter;
    try {
      final desc = await adapter.describe();
      stateAfter = <String, dynamic>{
        'deviceId': desc.deviceId,
        'connectionState': desc.connectionState.name,
      };
    } on Object {
      // Best-effort state capture
    }

    // Record audit for completed execution
    final completedAt = DateTime.now();
    await _auditTrail.record(IoAuditRecord(
      id: '${command.action}:$deviceId:${completedAt.millisecondsSinceEpoch}',
      type: IoAuditType.execute,
      actorId: 'system',
      actorRole: 'system',
      command: command,
      deviceId: deviceId,
      resultStatus: result.status,
      requestedAt: completedAt,
      executedAt: completedAt,
      completedAt: completedAt,
      stateBefore: stateBefore,
      stateAfter: stateAfter,
    ));

    return result;
  }

  /// Cleanup callback when a session is closed or expired.
  Future<void> _onSessionClosed(String sessionId, String deviceId) async {
    await _streamManager.removeByDevice(deviceId);
    await _commandQueue.drainDevice(deviceId);
  }

  /// Live interlock evaluator. Reads the interlock URI through the
  /// resolved adapter and applies the configured condition operator.
  /// Returns `true` when the interlock condition is satisfied (action
  /// should be applied — typically deny).
  Future<bool> _evaluateInterlock(Interlock interlock) async {
    try {
      final adapter = await _registry.resolveAdapter(interlock.uri);
      if (adapter == null) {
        // Adapter unresolved → fail-safe: treat as triggered so caller
        // sees a deny instead of silently passing.
        return true;
      }
      final result = await adapter.read(ReadSpec(targets: [interlock.uri]));
      if (result.items.isEmpty || result.items.first.error != null) {
        return true;
      }
      final envelope = result.items.first.envelope;
      if (envelope == null) return true;
      return _matchInterlockCondition(envelope.payload.value, interlock.condition);
    } on Object {
      // Read failure → fail-safe deny.
      return true;
    }
  }

  /// Apply an [InterlockCondition] operator to a live value.
  ///
  /// v1 supports `isTrue` / `isFalse` for boolean interlocks (the
  /// dominant industrial use case — E-Stop coil, safety relay, ...).
  /// `equals` / `greaterThan` / `lessThan` require an expected operand
  /// that is not part of the current spec; they are deferred to v1.x.
  bool _matchInterlockCondition(Object? value, InterlockCondition condition) {
    switch (condition) {
      case InterlockCondition.isTrue:
        return value == true;
      case InterlockCondition.isFalse:
        return value == false;
      case InterlockCondition.equals:
      case InterlockCondition.greaterThan:
      case InterlockCondition.lessThan:
        // Operand-less operators: treat as not-triggered for now and
        // surface a notes hint via PolicyDecision in a future revision.
        return false;
    }
  }

  /// Extract deviceId from a target URI or path.
  String? _extractDeviceId(String target) {
    // Handle io://<deviceId>/... format
    if (target.startsWith('io://')) {
      final withoutScheme = target.substring(5);
      final slashIndex = withoutScheme.indexOf('/');
      if (slashIndex == -1) return withoutScheme;
      return withoutScheme.substring(0, slashIndex);
    }

    // Handle bare <deviceId>/... format
    final slashIndex = target.indexOf('/');
    if (slashIndex == -1) return target;
    return target.substring(0, slashIndex);
  }

  /// Cancel a long-running job by id. Returns true when the
  /// cancellation was delivered. The runner is responsible for actually
  /// stopping cooperatively.
  bool cancelJob(String jobId, {String? cancelledBy}) {
    final ok = _jobManager.cancel(jobId, cancelledBy: cancelledBy);
    _metrics.incrementCounter('io.job.cancel.count',
        labels: {'delivered': ok});
    return ok;
  }

  /// Snapshot of a job, or null when unknown.
  Job? job(String jobId) => _jobManager.get(jobId);

  /// All known jobs, sorted by start time desc.
  List<Job> jobs() => _jobManager.list();

  /// Dispose all resources.
  Future<void> dispose() async {
    await shutdown();
    await _policyEngine.dispose();
    await _streamManager.dispose();
    await _commandQueue.dispose();
    await _sessionManager.dispose();
    await _jobManager.dispose();
    await _registry.dispose();
  }
}
