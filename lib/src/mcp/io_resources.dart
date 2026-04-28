import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';

import '../core/io_runtime.dart';

/// MCP resource handler for device browsing.
///
/// Exposes device resource trees as MCP browsable resources.
/// Maps `io://*` resource URIs to IoRuntime read operations.
class IoResources {
  IoResources({required IoRuntime runtime}) : _runtime = runtime;

  final IoRuntime _runtime;

  /// All resource templates for registration with MCP server.
  List<ResourceInfo> get templates => [
        const ResourceInfo(
          uri: 'io://',
          name: 'Device List',
          description: 'List all registered I/O devices.',
          mimeType: 'application/json',
        ),
        const ResourceInfo(
          uri: 'io://{deviceId}',
          name: 'Device Descriptor',
          description: 'Device identity, capabilities, and resource tree.',
          mimeType: 'application/json',
        ),
        const ResourceInfo(
          uri: 'io://{deviceId}/{path}',
          name: 'Device Resource',
          description: 'Read a specific device resource value.',
          mimeType: 'application/json',
        ),
      ];

  /// List available resources matching a URI pattern.
  Future<List<ResourceInfo>> listResources({String? uriPattern}) async {
    if (uriPattern == null || uriPattern == 'io://') {
      // List all devices as resources
      final devices = await _runtime.registry.list();
      return devices
          .map(
            (d) => ResourceInfo(
              uri: 'io://${d.deviceId}',
              name: '${d.manufacturer} ${d.model}',
              description: 'Device: ${d.deviceId}',
              mimeType: 'application/json',
            ),
          )
          .toList();
    }

    // List resources for a specific device
    final deviceId = _extractDeviceId(uriPattern);
    if (deviceId == null) return [];

    final descriptor = await _runtime.describe(deviceId);
    if (descriptor == null) return [];

    return [
      ResourceInfo(
        uri: 'io://$deviceId',
        name: '${descriptor.manufacturer} ${descriptor.model}',
        description: 'Device: $deviceId',
        mimeType: 'application/json',
      ),
    ];
  }

  /// Read a specific resource by URI.
  Future<ResourceContent> readResource(String uri) async {
    final deviceId = _extractDeviceId(uri);
    if (deviceId == null) {
      return ResourceContent(
        uri: uri,
        text: jsonEncode({
          'error': 'resource.not_found',
          'message': 'Invalid URI: $uri',
        }),
        mimeType: 'application/json',
      );
    }

    // If URI is just the device, return descriptor
    if (uri == 'io://$deviceId' || uri == 'io://$deviceId/') {
      final descriptor = await _runtime.describe(deviceId);
      if (descriptor == null) {
        return ResourceContent(
          uri: uri,
          text: jsonEncode({
            'error': 'resource.not_found',
            'message': 'Device not found: $deviceId',
          }),
          mimeType: 'application/json',
        );
      }
      return ResourceContent(
        uri: uri,
        text: jsonEncode(descriptor.toJson()),
        mimeType: 'application/json',
      );
    }

    // Otherwise, read the resource
    try {
      final result = await _runtime.read(ReadSpec(targets: [uri]));
      return ResourceContent(
        uri: uri,
        text: jsonEncode(result.toJson()),
        mimeType: 'application/json',
      );
    } on Object catch (error) {
      return ResourceContent(
        uri: uri,
        text: jsonEncode({
          'error': 'exec.failed',
          'message': '$error',
        }),
        mimeType: 'application/json',
      );
    }
  }

  /// Extract deviceId from URI: `io://<deviceId>/...`
  String? _extractDeviceId(String uri) {
    if (!uri.startsWith('io://')) return null;
    final withoutScheme = uri.substring(5);
    if (withoutScheme.isEmpty) return null;
    final slashIndex = withoutScheme.indexOf('/');
    if (slashIndex == -1) return withoutScheme;
    return withoutScheme.substring(0, slashIndex);
  }
}
