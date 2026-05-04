import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';

import '../core/io_runtime.dart';
import '../models/actor_context.dart';

/// MCP tool handler definitions for device operations.
///
/// Maps MCP tool calls to IoRuntime method invocations.
/// Each tool validates arguments, delegates to IoRuntime,
/// and converts results to ToolResult.
class IoTools {
  IoTools({required IoRuntime runtime}) : _runtime = runtime;

  final IoRuntime _runtime;

  /// All tool definitions for registration with MCP server.
  List<ToolInfo> get tools => [
        const ToolInfo(
          name: 'io.list_devices',
          description: 'List all registered devices.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'stateFilter': {'type': 'string'},
            },
          },
        ),
        const ToolInfo(
          name: 'io.describe_device',
          description: 'Get device descriptor by ID.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'deviceId': {'type': 'string'},
            },
            'required': ['deviceId'],
          },
        ),
        const ToolInfo(
          name: 'io.read',
          description: 'Read resource values from devices.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'targets': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['targets'],
          },
        ),
        const ToolInfo(
          name: 'io.execute',
          description: 'Execute a command on a device (policy-gated).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'target': {'type': 'string'},
              'action': {'type': 'string'},
              'args': {'type': 'object'},
              'actorId': {'type': 'string'},
              'role': {'type': 'string'},
            },
            'required': ['target', 'action', 'actorId', 'role'],
          },
        ),
        const ToolInfo(
          name: 'io.emergency_stop',
          description: 'Emergency stop (bypasses policy).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'deviceId': {'type': 'string'},
              'actorId': {'type': 'string'},
            },
            'required': ['actorId'],
          },
        ),
        const ToolInfo(
          name: 'io.subscribe',
          description: 'Create a stream subscription for real-time data.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'uri': {'type': 'string'},
              'consumerId': {'type': 'string'},
            },
            'required': ['uri', 'consumerId'],
          },
        ),
        const ToolInfo(
          name: 'io.plan_execute',
          description: 'Plan a dangerous command (dry-run with risk assessment).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'target': {'type': 'string'},
              'action': {'type': 'string'},
              'args': {'type': 'object'},
              'actorId': {'type': 'string'},
              'role': {'type': 'string'},
            },
            'required': ['target', 'action', 'actorId', 'role'],
          },
        ),
        const ToolInfo(
          name: 'io.commit_execute',
          description: 'Commit a previously planned execution.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'planId': {'type': 'string'},
              'actorId': {'type': 'string'},
              'acknowledgment': {'type': 'string'},
            },
            'required': ['planId', 'actorId'],
          },
        ),
        const ToolInfo(
          name: 'io.cancel_job',
          description: 'Cooperatively cancel a long-running job.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'jobId': {'type': 'string'},
              'cancelledBy': {'type': 'string'},
            },
            'required': ['jobId'],
          },
        ),
        const ToolInfo(
          name: 'io.list_jobs',
          description: 'List active and recently retained jobs.',
          inputSchema: {
            'type': 'object',
            'properties': <String, Object>{},
          },
        ),
        const ToolInfo(
          name: 'io.get_job',
          description: 'Get a job snapshot by id.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'jobId': {'type': 'string'},
            },
            'required': ['jobId'],
          },
        ),
      ];

  /// Dispatch a tool call by name.
  Future<ToolResult> call(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'io.list_devices':
        return listDevices(args);
      case 'io.describe_device':
        return describeDevice(args);
      case 'io.read':
        return readResource(args);
      case 'io.execute':
        return executeCommand(args);
      case 'io.emergency_stop':
        return emergencyStop(args);
      case 'io.subscribe':
        return subscribe(args);
      case 'io.plan_execute':
        return planExecute(args);
      case 'io.commit_execute':
        return commitExecute(args);
      case 'io.cancel_job':
        return cancelJob(args);
      case 'io.list_jobs':
        return listJobs(args);
      case 'io.get_job':
        return getJob(args);
      default:
        return ToolResult.error('tool.not_found: unknown tool $toolName');
    }
  }

  /// io.list_devices — List all registered devices.
  Future<ToolResult> listDevices(Map<String, dynamic> args) async {
    try {
      final devices = await _runtime.registry.list();
      final result = devices.map((d) => d.toJson()).toList();
      return ToolResult.success(jsonEncode(result));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.describe_device — Get device descriptor.
  Future<ToolResult> describeDevice(Map<String, dynamic> args) async {
    final deviceId = args['deviceId'] as String?;
    if (deviceId == null) {
      return ToolResult.error('tool.invalid_args: deviceId is required');
    }

    try {
      final descriptor = await _runtime.describe(deviceId);
      if (descriptor == null) {
        return ToolResult.error('device.not_found: $deviceId');
      }
      return ToolResult.success(jsonEncode(descriptor.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.read — Read resource values.
  Future<ToolResult> readResource(Map<String, dynamic> args) async {
    final targets = (args['targets'] as List?)?.cast<String>();
    if (targets == null || targets.isEmpty) {
      return ToolResult.error('tool.invalid_args: targets is required');
    }

    try {
      final result = await _runtime.read(ReadSpec(targets: targets));
      return ToolResult.success(jsonEncode(result.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.execute — Execute a command (policy-gated).
  Future<ToolResult> executeCommand(Map<String, dynamic> args) async {
    final target = args['target'] as String?;
    final action = args['action'] as String?;
    final actorId = args['actorId'] as String?;
    final role = args['role'] as String?;

    if (target == null || action == null || actorId == null || role == null) {
      return ToolResult.error(
        'tool.invalid_args: target, action, actorId, role are required',
      );
    }

    try {
      final commandArgs =
          (args['args'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final result = await _runtime.execute(
        Command(target: target, action: action, args: commandArgs),
        actor: ActorContext(actorId: actorId, role: role),
      );
      return ToolResult.success(jsonEncode(result.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.emergency_stop — Emergency stop (bypasses policy).
  Future<ToolResult> emergencyStop(Map<String, dynamic> args) async {
    final actorId = args['actorId'] as String?;
    if (actorId == null) {
      return ToolResult.error('tool.invalid_args: actorId is required');
    }

    final deviceId = args['deviceId'] as String?;

    try {
      final reason = args['reason'] as String? ?? 'MCP tool invocation';
      final result = await _runtime.emergencyStop(
        EmergencyStopRequest(
          actorId: actorId,
          deviceId: deviceId,
          reason: reason,
        ),
      );
      return ToolResult.success(jsonEncode(result.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.subscribe — Create a stream subscription.
  Future<ToolResult> subscribe(Map<String, dynamic> args) async {
    final uri = args['uri'] as String?;
    final consumerId = args['consumerId'] as String?;

    if (uri == null || consumerId == null) {
      return ToolResult.error(
        'tool.invalid_args: uri, consumerId are required',
      );
    }

    try {
      final subscription = await _runtime.subscribe(
        TopicSpec(uri: uri, mode: TopicMode.continuous),
        consumerId: consumerId,
      );
      return ToolResult.success(jsonEncode({
        'subscriptionId': subscription.handle.subscriptionId,
        'topic': subscription.handle.topic,
      }));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.plan_execute — Plan a dangerous command (dry-run).
  Future<ToolResult> planExecute(Map<String, dynamic> args) async {
    final target = args['target'] as String?;
    final action = args['action'] as String?;
    final actorId = args['actorId'] as String?;
    final role = args['role'] as String?;

    if (target == null || action == null || actorId == null || role == null) {
      return ToolResult.error(
        'tool.invalid_args: target, action, actorId, role are required',
      );
    }

    try {
      final commandArgs =
          (args['args'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final command = Command(target: target, action: action, args: commandArgs);
      final actor = ActorContext(actorId: actorId, role: role);

      // Resolve device for plan evaluation
      final deviceId = _extractDeviceId(target);
      final device =
          deviceId != null ? await _runtime.registry.get(deviceId) : null;
      if (device == null) {
        return ToolResult.error('device.not_found: $target');
      }

      // Resolve the adapter at plan time and capture it in the pending
      // plan so that commitExecute can route to the same adapter without
      // the caller re-resolving.
      final adapter = await _runtime.registry.resolveAdapter(target);
      if (adapter == null) {
        return ToolResult.error('adapter.not_found: $target');
      }

      final plan = await _runtime.policyEngine.planEvaluate(
        command: command,
        actor: actor,
        device: device,
        adapter: adapter,
      );
      return ToolResult.success(jsonEncode(plan.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.commit_execute — Commit a previously planned execution.
  Future<ToolResult> commitExecute(Map<String, dynamic> args) async {
    final planId = args['planId'] as String?;
    final actorId = args['actorId'] as String?;

    if (planId == null || actorId == null) {
      return ToolResult.error(
        'tool.invalid_args: planId, actorId are required',
      );
    }

    try {
      final acknowledgment = args['acknowledgment'] as String?;

      // Adapter was captured during planExecute and is reused here, so
      // the caller never needs to re-resolve it.
      final result = await _runtime.policyEngine.commitExecute(
        planId: planId,
        actorId: actorId,
        acknowledgment: acknowledgment,
      );
      return ToolResult.success(jsonEncode(result.toJson()));
    } on StateError catch (error) {
      return ToolResult.error(error.message);
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.cancel_job — Cooperatively cancel a long-running job.
  Future<ToolResult> cancelJob(Map<String, dynamic> args) async {
    final jobId = args['jobId'] as String?;
    if (jobId == null) {
      return ToolResult.error('tool.invalid_args: jobId is required');
    }
    try {
      final ok = _runtime.cancelJob(
        jobId,
        cancelledBy: args['cancelledBy'] as String?,
      );
      return ToolResult.success(jsonEncode({'cancelled': ok, 'jobId': jobId}));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.list_jobs — List active and recently retained jobs.
  Future<ToolResult> listJobs(Map<String, dynamic> args) async {
    try {
      final jobs = _runtime.jobs().map((j) => j.toJson()).toList();
      return ToolResult.success(jsonEncode(jobs));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// io.get_job — Get a single job snapshot by id.
  Future<ToolResult> getJob(Map<String, dynamic> args) async {
    final jobId = args['jobId'] as String?;
    if (jobId == null) {
      return ToolResult.error('tool.invalid_args: jobId is required');
    }
    try {
      final snapshot = _runtime.job(jobId);
      if (snapshot == null) {
        return ToolResult.error('job.not_found: $jobId');
      }
      return ToolResult.success(jsonEncode(snapshot.toJson()));
    } on Object catch (error) {
      return ToolResult.error('$error');
    }
  }

  /// Extract deviceId from a target URI.
  String? _extractDeviceId(String target) {
    if (target.startsWith('io://')) {
      final withoutScheme = target.substring(5);
      final slashIndex = withoutScheme.indexOf('/');
      if (slashIndex == -1) return withoutScheme;
      return withoutScheme.substring(0, slashIndex);
    }
    final slashIndex = target.indexOf('/');
    if (slashIndex == -1) return target;
    return target.substring(0, slashIndex);
  }
}

