import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:workmanager/workmanager.dart';
import '../base.dart';
import '../network/network_logging.dart';
import '../network/picacg_network/methods.dart';
import 'notification.dart';

@pragma('vm:entry-point')
void onStart() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  // Workmanager 0.8 exposes executeTask as `void ... async`, so there is no
  // Future to await. The callback itself remains a Future<bool> as required by
  // the plugin API.
  Workmanager().executeTask((taskName, inputData) async {
    await App.init();
    appdata = Appdata();
    await appdata.readData();
    var notifications = Notifications();
    await notifications.init();
    if (picacg.data['token'] != "") {
      var userInfo = await network.getProfile(false);
      if (userInfo.error) {
        return true;
      }
      if (userInfo.data.isPunched == false) {
        var res = await network.punchIn();
        if (res) {
          await notifications.sendUnimportantNotification("自动打卡", "成功签到");
          return true;
        }
      } else {
        return true;
      }
    }
    return true;
  });
}

Future<void> runBackgroundService() async {
  try {
    await Workmanager().cancelAll();
    await Workmanager().registerPeriodicTask(
      "Piacg PunchIn",
      "打卡",
      frequency: const Duration(minutes: 1440),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (e, s) {
    _logFailure('Register background service', e, s);
  }
}

Future<void> cancelBackgroundService() async {
  try {
    await Workmanager().cancelAll();
  } catch (e, s) {
    _logFailure('Cancel background service', e, s);
  }
}

void _logFailure(String operation, Object error, StackTrace stack) {
  LogManager.addLog(
    LogLevel.warning,
    'Background service',
    '$operation failed: ${safeNetworkError(error)}\n$stack',
  );
}
