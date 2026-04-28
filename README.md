# MCP IO

Universal I/O Backbone for device integration into the MCP ecosystem. Implements the IO Contract Layer from `mcp_bundle` with device registry, policy engine, audit trail, streaming, command queue, and session management.

Concrete protocol adapters are published as separate companion packages:

- `mcp_io_websocket` — text/binary WebSocket frames.
- `mcp_io_http` — HTTP REST + polling subscribe.
- `mcp_io_mqtt` — MQTT v3.1.1 pub/sub.
- `mcp_io_serial` — UART / RS-232 / USB-Serial.
- `mcp_io_can` — Classic CAN 2.0A/B (SocketCAN).
- `mcp_io_modbus` — Modbus TCP/RTU.
- `mcp_io_opcua` — OPC UA Binary.
- `mcp_io_scpi` — SCPI text protocol over TCP.

## Components

- **Models** — actor context, device configs, plan result, session info.
- **Device registry** — register and discover transport adapters.
- **Policy engine** — enforce read / write / execute permissions.
- **Audit trail** — pluggable audit sinks.
- **Session manager** — multi-device session lifecycle.
- **Streaming and command queue** — backpressure-aware streaming and reliable command dispatch.
- **Standard port adapters** — implementations of `mcp_bundle` IO Contract Layer (`IoDevicePort`, `IoStreamPort`, `IoRegistryPort`, `IoPolicyPort`, `IoAuditPort`).

## Quick Start

```dart
import 'package:mcp_io/mcp_io.dart';

final registry = DeviceRegistry();
registry.register('sensor-1', myAdapter, config: DeviceConfig(...));

final session = await registry.openSession('sensor-1', actor: actorContext);
await for (final event in session.stream) {
  // ...
}
```

## Support

- [Issue Tracker](https://github.com/app-appplayer/mcp_io/issues)
- [Discussions](https://github.com/app-appplayer/mcp_io/discussions)

## License

MIT — see [LICENSE](LICENSE).
