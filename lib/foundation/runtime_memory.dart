import 'dart:io';

import 'package:flutter/services.dart';

/// A point-in-time Android process memory sample for explicit diagnostics.
///
/// Values are in KiB. Sampling is opt-in so normal app startup and rendering
/// do not pay for a platform channel round trip.
class RuntimeMemorySnapshot {
  const RuntimeMemorySnapshot({
    required this.totalPssKb,
    required this.privateDirtyKb,
    required this.nativePssKb,
    required this.dalvikPssKb,
    required this.otherPssKb,
    required this.javaHeapUsedKb,
    required this.javaHeapMaxKb,
  });

  final int totalPssKb;
  final int privateDirtyKb;
  final int nativePssKb;
  final int dalvikPssKb;
  final int otherPssKb;
  final int javaHeapUsedKb;
  final int javaHeapMaxKb;

  Map<String, int> toJson() => {
        'totalPssKb': totalPssKb,
        'privateDirtyKb': privateDirtyKb,
        'nativePssKb': nativePssKb,
        'dalvikPssKb': dalvikPssKb,
        'otherPssKb': otherPssKb,
        'javaHeapUsedKb': javaHeapUsedKb,
        'javaHeapMaxKb': javaHeapMaxKb,
      };

  static RuntimeMemorySnapshot? fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final values = <String, int>{};
    for (final key in [
      'totalPssKb',
      'privateDirtyKb',
      'nativePssKb',
      'dalvikPssKb',
      'otherPssKb',
      'javaHeapUsedKb',
      'javaHeapMaxKb',
    ]) {
      final value = raw[key];
      if (value is! num || !value.isFinite || value < 0) return null;
      values[key] = value.round();
    }
    return RuntimeMemorySnapshot(
      totalPssKb: values['totalPssKb']!,
      privateDirtyKb: values['privateDirtyKb']!,
      nativePssKb: values['nativePssKb']!,
      dalvikPssKb: values['dalvikPssKb']!,
      otherPssKb: values['otherPssKb']!,
      javaHeapUsedKb: values['javaHeapUsedKb']!,
      javaHeapMaxKb: values['javaHeapMaxKb']!,
    );
  }
}

class RuntimeMemory {
  RuntimeMemory._();

  static const MethodChannel _channel =
      MethodChannel('pica_comic/runtime_memory');

  /// Returns a platform sample, or null when memory sampling is unavailable.
  static Future<RuntimeMemorySnapshot?> sample() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('sample');
      return RuntimeMemorySnapshot.fromMap(raw);
    } catch (_) {
      return null;
    }
  }
}

