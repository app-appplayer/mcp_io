/// mcp_io - Universal I/O Backbone for device integration.
///
/// Provides device registry, policy engine, audit trail, streaming,
/// command queue, and session management for the MCP ecosystem.
// ignore: unnecessary_library_name
library mcp_io;

// Models
export 'src/models/actor_context.dart';
export 'src/models/configs.dart';
export 'src/models/plan_result.dart';
export 'src/models/session_info.dart';

// Core
export 'src/core/device_registry.dart';
export 'src/core/policy_engine.dart';
export 'src/core/audit_trail.dart';
export 'src/core/stream_manager.dart';
export 'src/core/command_queue.dart';
export 'src/core/session_manager.dart';
export 'src/core/io_runtime.dart';

// Adapters
export 'src/adapters/adapter_base.dart';
export 'src/adapters/io_policy_port_adapter.dart';

// MCP
export 'src/mcp/io_tools.dart';
export 'src/mcp/io_resources.dart';
