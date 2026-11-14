import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';

Future<void> setKeepScreenOn() => _updateKeepScreenOn('set');

Future<void> cancelKeepScreenOn() => _updateKeepScreenOn('cancel');

Future<void> _updateKeepScreenOn(String method) async {
  if (!App.isMobile) return;
  const channel = MethodChannel("com.github.pacalini.pica_comic/keepScreenOn");
  try {
    await channel.invokeMethod<void>(method);
  } catch (e, s) {
    LogManager.addLog(LogLevel.warning, 'Keep screen on',
        '$method failed: ${safeNetworkError(e)}\n$s');
  }
}
