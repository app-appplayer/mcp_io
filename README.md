# MCP IO

Universal I/O backbone for device integration into the MCP ecosystem.
`mcp_io` ships the protocol-independent core — the **4-Primitive
Contract** (`describe` / `read` / `execute` / `subscribe`), policy
engine with interlock evaluation, plan/commit two-phase execution,
job manager with cooperative cancel, telemetry hook, and shared
type system from `mcp_bundle`.

Concrete protocol implementations live in companion packages:

| Package | Protocol | Production transport |
|---|---|---|
| `mcp_io_websocket` | RFC 6455 (text + binary) | dart:io WebSocket |
| `mcp_io_http` | HTTP REST + SSE | dart:io HttpClient |
| `mcp_io_mqtt` | MQTT v3.1.1 / v5 | dart:io Socket / TLS / WS |
| `mcp_io_serial` | UART / RS-232 / RS-485 / USB-CDC | libserialport FFI |
| `mcp_io_can` | CAN 2.0A/B + CAN-FD | Linux SocketCAN FFI |
| `mcp_io_modbus` | Modbus TCP / RTU / ASCII | dart:io Socket + RTU-over-TCP |
| `mcp_io_opcua` | OPC UA Binary | dart:io Socket |
| `mcp_io_scpi` | SCPI / IEEE 488.2 | dart:io Socket |

## What this core ships

- **AdapterBase** — base class adapters extend; provides 4-Primitive
  surface (describe / read / execute / subscribe), connection state,
  emergency stop hook.
- **Models** — `DeviceDescriptor`, `ReadSpec` / `ReadResult` /
  `PayloadEnvelope`, `Command` / `CommandResult`, `TopicSpec`, all
  re-exported from `mcp_bundle`.
- **PolicyEngine** — 6-stage pipeline (manifest version → capability
  match → SafetyClass guard → bounds check → interlock → approval).
- **Plan / Commit** — `planExecute(...)` returns a plan token; the
  call is only sent on `commitExecute(token)`.
- **JobManager** — cooperative-cancel long-running operations
  surfaced as `io.list_jobs` / `io.get_job` / `io.cancel_job`.
- **IoMetrics** — pluggable telemetry sink (`NoopIoMetrics` /
  `InMemoryIoMetrics` shipped; production sinks integrate with
  whichever observability stack the host project uses).
- **MCP-tool dispatcher** — exposes the 4-Primitive surface as
  MCP tools so an LLM (or any MCP client) can talk to any
  registered adapter without protocol-specific glue.

## Quick start

```dart
import 'package:mcp_io/mcp_io.dart';
import 'package:mcp_bundle/mcp_bundle.dart';

// 1) Build an adapter (one of the protocol packages above).
final adapter = MyHttpAdapter(...);

// 2) Wire it into the runtime.
final runtime = IoRuntime();
runtime.register('sensor-1', adapter);

// 3) Drive it through the 4-Primitive surface.
final result = await runtime.read(
  deviceId: 'sensor-1',
  spec: const ReadSpec(targets: ['/temperature']),
);
for (final item in result.items) {
  print('${item.uri} → ${item.envelope?.payload.value}');
}

// 4) Subscribe for streaming reads.
final stream = runtime.subscribe(
  deviceId: 'sensor-1',
  spec: const TopicSpec(uri: '/temperature', mode: TopicMode.poll),
);
stream.listen((env) => print(env.payload.value));
```

## Support

- Issues: https://github.com/app-appplayer/mcp_io/issues
- Discussions: https://github.com/app-appplayer/mcp_io/discussions

## License

MIT — see [LICENSE](LICENSE).
