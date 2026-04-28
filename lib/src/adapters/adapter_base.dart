import 'dart:async';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';

/// Result of resolving a URI path to a native protocol address.
class MappingResult {
  const MappingResult({
    required this.nativeAddress,
    required this.parameters,
  });

  /// The native protocol address string.
  final String nativeAddress;

  /// Extracted template parameters.
  final Map<String, String> parameters;
}

/// Resource mapping definition for URI template ↔ native address.
class ResourceMapping {
  const ResourceMapping({
    required this.uriTemplate,
    required this.addressTemplate,
  });

  /// URI path template (e.g., "ch/{ch}/measure/{measure}").
  final String uriTemplate;

  /// Native address template (e.g., ":MEASure:{measure}?").
  final String addressTemplate;
}

/// Maps URIs to native protocol addresses via template patterns.
class UriMapper {
  UriMapper(this._mappings);

  final List<ResourceMapping> _mappings;

  /// Resolve a URI path to its native address.
  ///
  /// Returns null if no mapping matches.
  MappingResult? resolve(String uriPath) {
    for (final mapping in _mappings) {
      final params = _matchTemplate(uriPath, mapping.uriTemplate);
      if (params != null) {
        final address = _applyTemplate(mapping.addressTemplate, params);
        return MappingResult(nativeAddress: address, parameters: params);
      }
    }
    return null;
  }

  /// Match a path against a template, extracting parameters.
  Map<String, String>? _matchTemplate(String path, String template) {
    final pathParts = path.split('/');
    final templateParts = template.split('/');

    if (pathParts.length != templateParts.length) return null;

    final params = <String, String>{};
    for (var i = 0; i < templateParts.length; i++) {
      final tPart = templateParts[i];
      if (tPart.startsWith('{') && tPart.endsWith('}')) {
        final paramName = tPart.substring(1, tPart.length - 1);
        params[paramName] = pathParts[i];
      } else if (tPart != pathParts[i]) {
        return null;
      }
    }
    return params;
  }

  /// Apply parameter values to an address template.
  String _applyTemplate(String template, Map<String, String> params) {
    var result = template;
    for (final entry in params.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }
}

/// Abstract base class for protocol-specific device adapters.
///
/// Provides the adapter lifecycle contract, URI mapping helpers,
/// and error conversion utilities. Protocol adapters extend this
/// class and implement the 4-Primitive Contract methods.
abstract class AdapterBase implements IoDevicePort {
  AdapterBase({required this.manifest});

  /// Adapter manifest describing identity, capabilities, and constraints.
  final AdapterManifest manifest;

  /// Discover compatible devices from a transport connection.
  Future<List<DeviceDescriptor>> probe(dynamic transport);

  /// Convert a protocol-specific exception to a standard IoError.
  static IoError mapException(Object error) {
    final now = DateTime.now();

    if (error is SocketException) {
      return IoError(
        code: 'conn.lost',
        message: 'Connection lost: ${error.message}',
        timestamp: now,
      );
    }

    if (error is TimeoutException) {
      return IoError(
        code: 'conn.timeout',
        message: 'Connection timeout: ${error.message}',
        timestamp: now,
      );
    }

    if (error is ArgumentError) {
      return IoError(
        code: 'exec.invalid_args',
        message: 'Invalid arguments: ${error.message}',
        timestamp: now,
      );
    }

    if (error is UnsupportedError) {
      return IoError(
        code: 'device.unsupported',
        message: 'Unsupported operation: ${error.message}',
        timestamp: now,
      );
    }

    return IoError(
      code: 'exec.failed',
      message: 'Execution failed: $error',
      timestamp: now,
    );
  }
}
