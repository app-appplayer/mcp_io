import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';

import '../models/configs.dart';

/// Internal entry for a registered adapter.
class _AdapterEntry {
  _AdapterEntry({required this.manifest, required this.port});

  final AdapterManifest manifest;
  final IoDevicePort port;
}

/// Internal entry for a discovered device.
class _DeviceEntry {
  _DeviceEntry({
    required this.descriptor,
    required this.adapterId,
  });

  DeviceDescriptor descriptor;
  final String adapterId;
}

/// Device and adapter registry implementing IoRegistryPort.
///
/// Manages adapter registration, device discovery, URI-based
/// adapter resolution, and emits registry lifecycle events.
class DeviceRegistry implements IoRegistryPort {
  DeviceRegistry({
    required this.config,
    required this.reconnectionConfig,
  });

  /// Factory: create with default configuration.
  factory DeviceRegistry.withDefaults() => DeviceRegistry(
        config: const RegistryConfig.defaults(),
        reconnectionConfig: const ReconnectionConfig.defaults(),
      );

  final RegistryConfig config;
  final ReconnectionConfig reconnectionConfig;

  final Map<String, _AdapterEntry> _adapters = {};
  final Map<String, _DeviceEntry> _devices = {};
  final StreamController<RegistryEvent> _events =
      StreamController<RegistryEvent>.broadcast();

  bool _initialized = false;

  /// Initialize the registry.
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> registerAdapter(
    AdapterManifest manifest,
    IoDevicePort adapter,
  ) async {
    _checkInitialized();

    if (_adapters.length >= config.maxAdapters) {
      throw StateError(
        'registry.max_exceeded: max adapters (${config.maxAdapters}) reached',
      );
    }

    if (_adapters.containsKey(manifest.adapterId)) {
      throw StateError(
        'device.duplicate: adapter ${manifest.adapterId} already registered',
      );
    }

    _adapters[manifest.adapterId] = _AdapterEntry(
      manifest: manifest,
      port: adapter,
    );

    _emitEvent(
      RegistryEventType.adapterRegistered,
      manifest.adapterId,
      adapterId: manifest.adapterId,
    );

    if (config.autoDiscover) {
      await discover();
    }
  }

  @override
  Future<void> unregisterAdapter(String adapterId) async {
    _checkInitialized();

    final entry = _adapters.remove(adapterId);
    if (entry == null) return;

    // Remove all devices belonging to this adapter
    final deviceIds = _devices.entries
        .where((e) => e.value.adapterId == adapterId)
        .map((e) => e.key)
        .toList();

    for (final deviceId in deviceIds) {
      _devices.remove(deviceId);
      _emitEvent(
        RegistryEventType.deviceUnregistered,
        deviceId,
        adapterId: adapterId,
      );
    }

    _emitEvent(
      RegistryEventType.adapterUnregistered,
      adapterId,
      adapterId: adapterId,
    );
  }

  @override
  Future<List<DeviceDescriptor>> discover({
    String? transportFilter,
    Duration? timeout,
  }) async {
    _checkInitialized();

    final effectiveTimeout = timeout ?? config.discoveryTimeout;
    final discovered = <DeviceDescriptor>[];

    for (final entry in _adapters.values.toList()) {
      DeviceDescriptor descriptors;
      try {
        descriptors = await entry.port.describe().timeout(
              effectiveTimeout,
              onTimeout: () => throw TimeoutException(
                'Discovery timed out',
                effectiveTimeout,
              ),
            );
      } on TimeoutException {
        // Skip adapter on timeout
        continue;
      } on Object {
        // Skip adapter on error
        continue;
      }

      // Filter by transport if specified
      if (transportFilter != null &&
          descriptors.transport != transportFilter) {
        continue;
      }

      if (!_devices.containsKey(descriptors.deviceId)) {
        if (_devices.length >= config.maxDevices) {
          throw StateError(
            'registry.max_exceeded: max devices (${config.maxDevices}) reached',
          );
        }

        _devices[descriptors.deviceId] = _DeviceEntry(
          descriptor: descriptors,
          adapterId: entry.manifest.adapterId,
        );

        _emitEvent(
          RegistryEventType.deviceRegistered,
          descriptors.deviceId,
          adapterId: entry.manifest.adapterId,
        );
      }

      discovered.add(descriptors);
    }

    return discovered;
  }

  @override
  Future<List<DeviceDescriptor>> list({
    IoConnectionState? stateFilter,
  }) async {
    _checkInitialized();

    if (stateFilter == null) {
      return _devices.values.map((e) => e.descriptor).toList();
    }

    return _devices.values
        .where((e) => e.descriptor.connectionState == stateFilter)
        .map((e) => e.descriptor)
        .toList();
  }

  @override
  Future<DeviceDescriptor?> get(String deviceId) async {
    _checkInitialized();
    return _devices[deviceId]?.descriptor;
  }

  @override
  Future<IoDevicePort?> resolveAdapter(String uri) async {
    _checkInitialized();

    final deviceId = _extractDeviceId(uri);
    if (deviceId == null) return null;

    final deviceEntry = _devices[deviceId];
    if (deviceEntry == null) return null;

    return _adapters[deviceEntry.adapterId]?.port;
  }

  @override
  Stream<RegistryEvent> get events => _events.stream;

  /// Disconnect all devices and clean up.
  Future<void> disconnectAll() async {
    final deviceIds = _devices.keys.toList();
    for (final deviceId in deviceIds) {
      final entry = _devices[deviceId];
      if (entry != null) {
        final adapter = _adapters[entry.adapterId];
        if (adapter != null) {
          try {
            await adapter.port.disconnect();
          } on Object {
            // Best effort disconnect
          }
        }
        _emitEvent(
          RegistryEventType.deviceDisconnected,
          deviceId,
          adapterId: entry.adapterId,
        );
      }
    }
    _devices.clear();
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await disconnectAll();
    _adapters.clear();
    await _events.close();
  }

  /// Extract deviceId from URI: `io://<deviceId>/...`
  String? _extractDeviceId(String uri) {
    if (!uri.startsWith('io://')) return null;
    final withoutScheme = uri.substring(5);
    final slashIndex = withoutScheme.indexOf('/');
    if (slashIndex == -1) return withoutScheme;
    return withoutScheme.substring(0, slashIndex);
  }

  void _emitEvent(
    RegistryEventType type,
    String deviceId, {
    String? adapterId,
  }) {
    _events.add(RegistryEvent(
      type: type,
      deviceId: deviceId,
      adapterId: adapterId,
      timestamp: DateTime.now(),
    ));
  }

  void _checkInitialized() {
    if (!_initialized) {
      throw StateError('DeviceRegistry not initialized. Call initialize() first.');
    }
  }
}
