import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/downloading_page.dart';
import '../foundation/app.dart';
import '../network/network_logging.dart';

class Notifications {
  FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;
  final progressId = 72382;

  Future<bool?> requestPermission() async {
    try {
      if (App.isAndroid) {
        return await flutterLocalNotificationsPlugin!
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()!
            .requestNotificationsPermission();
      } else if (App.isIOS) {
        return await flutterLocalNotificationsPlugin
            ?.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> init() async {
    if (!(App.isAndroid || App.isIOS)) return;
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@drawable/notification');
    final DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
            onDidReceiveLocalNotification: onDidReceiveLocalNotification);
    InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );
    try {
      await flutterLocalNotificationsPlugin!.initialize(initializationSettings,
          onDidReceiveNotificationResponse: onDidReceiveNotificationResponse);
    } catch (e, s) {
      _logFailure('Initialize', e, s);
    }
  }

  // Plugin callbacks are typed as void Function(...). Keep this boundary
  // synchronous; all work here is synchronous as well.
  void onDidReceiveNotificationResponse(
      NotificationResponse notificationResponse) {
    if (!(App.isAndroid || App.isIOS)) return;
    final String? payload = notificationResponse.payload;
    if (payload != "item y") {
      App.globalTo(() => const DownloadingPage());
    }
  }

  void onDidReceiveLocalNotification(
      int id, String? title, String? body, String? payload) {
    if (payload != "item y") {
      App.globalTo(() => const DownloadingPage());
    }
  }

  Future<void> sendProgressNotification(
      int progress, int total, String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails('download', '下载漫画'.tl,
            channelDescription: '显示下载进度'.tl,
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: total,
            progress: progress,
            ongoing: true,
            onlyAlertOnce: true,
            autoCancel: false);
    DarwinNotificationDetails ios = const DarwinNotificationDetails(
        presentSound: false,
        presentAlert: false,
        presentBadge: false,
        presentBanner: false);
    NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails, iOS: ios);
    try {
      await flutterLocalNotificationsPlugin!.show(
          progressId, title, content, notificationDetails,
          payload: 'item x');
    } catch (e, s) {
      _logFailure('Progress notification', e, s);
    }
  }

  Future<void> endProgress() async {
    if (!(App.isAndroid || App.isIOS)) return;
    try {
      await flutterLocalNotificationsPlugin!.cancel(progressId);
    } catch (e, s) {
      _logFailure('End progress notification', e, s);
    }
  }

  Future<void> cancelAll() async {
    if (!(App.isAndroid || App.isIOS)) return;
    try {
      await flutterLocalNotificationsPlugin!.cancelAll();
    } catch (e, s) {
      _logFailure('Cancel notifications', e, s);
    }
  }

  Future<void> sendNotification(String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    AndroidNotificationDetails androidNotificationDetails =
        const AndroidNotificationDetails(
      'PicaComic',
      'notification',
      channelDescription: 'notification',
      importance: Importance.max,
      priority: Priority.max,
    );
    DarwinNotificationDetails ios = const DarwinNotificationDetails();
    NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails, iOS: ios);
    try {
      await flutterLocalNotificationsPlugin!.show(
          1145140, title, content, notificationDetails,
          payload: 'item x');
    } catch (e, s) {
      _logFailure('Notification', e, s);
    }
  }

  Future<void> sendUnimportantNotification(String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    AndroidNotificationDetails androidNotificationDetails =
        const AndroidNotificationDetails(
      'punchIN',
      '打卡',
      channelDescription: '打卡',
      importance: Importance.low,
      priority: Priority.low,
    );

    DarwinNotificationDetails ios = const DarwinNotificationDetails(
        presentAlert: false, presentSound: false, presentBadge: false);

    NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails, iOS: ios);
    try {
      await flutterLocalNotificationsPlugin!.show(
          51515568, title, content, notificationDetails,
          payload: 'item y');
    } catch (e, s) {
      _logFailure('Unimportant notification', e, s);
    }
  }

  void _logFailure(String operation, Object error, StackTrace stack) {
    LogManager.addLog(
      LogLevel.warning,
      'Notifications',
      '$operation failed: ${safeNetworkError(error)}\n$stack',
    );
  }
}
