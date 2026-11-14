import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import '../foundation/app.dart';

void mouseSideButtonCallback() {
  if (App.canPop) {
    App.globalBack();
  } else if (App.mainNavigatorKey?.currentState?.canPop() ?? false) {
    App.mainNavigatorKey!.currentState!.pop();
  }
}

///监听鼠标侧键, 若为下键, 则调用返回
StreamSubscription<dynamic>? listenMouseSideButtonToBack() {
  if (!App.isWindows) return null;
  const channel = EventChannel("com.github.pacalini.pica_comic/mouse");
  return channel.receiveBroadcastStream().listen((res) {
    if (res == 0) {
      mouseSideButtonCallback();
    }
  }, onError: (Object error, StackTrace stack) {
    LogManager.addLog(LogLevel.warning, 'Mouse listener',
        '${safeNetworkError(error)}\n$stack');
  }, cancelOnError: true);
}
