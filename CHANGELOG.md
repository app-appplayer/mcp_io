## [0.2.0] - 2026-05-04

- Long-running job lifecycle (`JobManager` + cooperative cancellation +
  progress URI subscribe).
- Runtime telemetry hooks (`IoMetrics` counter / gauge interface).
- MCP tool surface expanded to 11 tools (3 job-control tools added).

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- Device registry with pluggable transport adapters.
- Policy engine for read / write / execute permissions.
- Audit trail with pluggable sinks.
- Multi-device session manager.
- Streaming subsystem with backpressure and command queue.
- Standard port adapters implementing `mcp_bundle` IO Contract Layer (`IoDevicePort`, `IoStreamPort`, `IoRegistryPort`, `IoPolicyPort`, `IoAuditPort`).
- Models — actor context, device configs, plan result, session info.
