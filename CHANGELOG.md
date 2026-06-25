## [0.2.2] - 2026-06-25 - Import hygiene — use the public ports catalogue

### Changed
- `policy_engine.dart` and `io_policy_port_adapter.dart` now import the io
  policy contract via the public `package:mcp_bundle/ports.dart` instead of
  reaching into `package:mcp_bundle/src/ports/io_policy_port.dart` (an
  implementation import). The io `PolicyRule` / `PolicyCondition` names are
  taken with an explicit `show`, so the models/policy `PolicyRule` stays
  disambiguated. No API or behaviour change.

## [0.2.1] - 2026-05-23 - mcp_bundle 0.4.0 cascade

### Changed (cascade)
- `mcp_bundle` caret bumped from `^0.3.0` to `^0.4.0`. mcp_io does not touch `UiSection.pages` directly, so this release is a caret-only cascade. Consumers should bump to `^0.2.1`.

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
