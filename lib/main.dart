import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/window_frame.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/init.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/pages/auth_page.dart';
import 'package:pica_comic/pages/main_page.dart';
import 'package:pica_comic/pages/startup_recovery.dart';
import 'package:pica_comic/pages/welcome_page.dart';
import 'package:pica_comic/tools/block_screenshot.dart';
import 'package:pica_comic/tools/mouse_listener.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:window_manager/window_manager.dart';

import 'components/components.dart';
import 'network/webdav.dart';

bool notFirstUse = false;

void main(List<String> args) {
  if (runWebViewTitleBarWidget(args)) {
    return;
  }
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final startup = await init();
      FlutterError.onError = (details) {
        LogManager.addLog(
          LogLevel.error,
          "Unhandled Exception",
          "${safeNetworkError(details.exception)}\n${details.stack}",
        );
        unawaited(LogManager.flush());
      };
      if (startup.ready) notFirstUse = appdata.firstUse[3] == '1';
      runApp(
        StartupGate(
          initialResult: startup,
          retry: () async {
            final result = await init();
            if (result.ready) notFirstUse = appdata.firstUse[3] == '1';
            return result;
          },
          applicationBuilder: () => const MyApp(),
        ),
      );
      if (App.isDesktop) {
        await windowManager.ensureInitialized();
        windowManager.waitUntilReadyToShow().then((_) async {
          await windowManager.setTitleBarStyle(
            TitleBarStyle.hidden,
            windowButtonVisibility: App.isMacOS,
          );
          if (App.isLinux) {
            await windowManager.setBackgroundColor(Colors.transparent);
          }
          await windowManager.setMinimumSize(const Size(500, 600));
          if (!App.isLinux && startup.ready) {
            // https://github.com/leanflutter/window_manager/issues/460
            var placement = await WindowPlacement.loadFromFile();
            await placement.applyToWindow();
            await windowManager.show();
            WindowPlacement.loop();
          } else if (!startup.ready) {
            await windowManager.show();
          }
        });
      }
    },
    (error, stack) {
      LogManager.addLog(
        LogLevel.error,
        "Unhandled Exception",
        "${safeNetworkError(error)}\n$stack",
      );
      unawaited(LogManager.flush());
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  static void Function()? updater;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  DateTime time = DateTime.fromMillisecondsSinceEpoch(0);

  bool forceRebuild = false;

  Timer? _proxyRefreshTimer;

  StreamSubscription<dynamic>? _mouseButtonSubscription;

  OverlayEntry? hideContentOverlay;

  void hideContent() {
    if (hideContentOverlay != null) return;
    hideContentOverlay = OverlayEntry(
      builder: (context) => Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.width,
        color: Theme.of(context).colorScheme.surface,
      ),
    );
    OverlayWidget.addOverlay(hideContentOverlay!);
  }

  void showContent() {
    hideContentOverlay = null;
    OverlayWidget.removeAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Give queued diagnostics a chance to reach disk before the process is
    // backgrounded or detached. The call is intentionally fire-and-forget so
    // lifecycle handling never blocks the UI thread.
    if (state != AppLifecycleState.resumed) {
      unawaited(LogManager.flush());
    }
    bool enableAuth = appdata.settings[13] == "1";
    if (App.isAndroid && appdata.settings[38] == "1") {
      try {
        FlutterDisplayMode.setHighRefreshRate();
      } catch (e) {
        // ignore
      }
    }
    unawaited(setNetworkProxy());
    scheduleMicrotask(() {
      if (state == AppLifecycleState.hidden && enableAuth) {
        if (!AuthPage.lock && appdata.settings[13] == "1") {
          AuthPage.initial = false;
          AuthPage.lock = true;
          App.to(App.globalContext!, () => const AuthPage());
        }
      }

      if (state == AppLifecycleState.inactive && enableAuth) {
        hideContent();
      } else if (state == AppLifecycleState.resumed) {
        showContent();
        Future.delayed(const Duration(milliseconds: 200), checkClipboard);
      }

      if (DateTime.now().millisecondsSinceEpoch - time.millisecondsSinceEpoch >
          7200000) {
        Webdav.syncData();
        time = DateTime.now();
      }
    });
  }

  @override
  void didHaveMemoryPressure() {
    BaseImageProvider.clearCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    super.didHaveMemoryPressure();
  }

  @override
  void initState() {
    MyApp.updater = () => setState(() => forceRebuild = true);
    time = DateTime.now();
    TagsTranslation.readData();
    if (App.isAndroid && appdata.settings[38] == "1") {
      try {
        FlutterDisplayMode.setHighRefreshRate();
      } finally {}
    }
    _mouseButtonSubscription = listenMouseSideButtonToBack();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    _proxyRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (vpnAutoSwitchEnabled) {
        unawaited(setNetworkProxy());
      }
    });
    unawaited(notifications.init());
    if (appdata.settings[12] == "1") {
      blockScreenshot();
    }
    PaintingBinding.instance.imageCache.maximumSizeBytes = 200 * 1024 * 1024;
    super.initState();
  }

  @override
  void dispose() {
    unawaited(_mouseButtonSubscription?.cancel().catchError(
      (Object error, StackTrace stack) {
        LogManager.addLog(LogLevel.warning, 'Mouse listener',
            'Cancel failed: ${safeNetworkError(error)}\n$stack');
      },
    ));
    _proxyRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
  }

  (ColorScheme, ColorScheme) _generateColorSchemes(
    ColorScheme? light,
    ColorScheme? dark,
  ) {
    Color? color;
    if (int.parse(appdata.settings[27]) != 0) {
      color = colors[int.parse(appdata.settings[27]) - 1];
    } else {
      color = light?.primary ?? Colors.blueAccent;
    }
    light = ColorScheme.fromSeed(seedColor: color);
    dark = ColorScheme.fromSeed(seedColor: color, brightness: Brightness.dark);
    if (appdata.settings[84] == "1") {
      dark = dark.copyWith(surface: Colors.black).harmonized();
    }
    return (light, dark);
  }

  @override
  Widget build(BuildContext context) {
    if (forceRebuild) {
      forceRebuild = false;
      void rebuild(Element el) {
        el.markNeedsBuild();
        el.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    }
    return DynamicColorBuilder(
      builder: (light, dark) {
        var (lightColor, darkColor) = _generateColorSchemes(light, dark);
        return MaterialApp(
          title: 'Pica Comic',
          debugShowCheckedModeBanner: false,
          navigatorKey: App.navigatorKey,
          theme: ThemeData(
            colorScheme: lightColor,
            useMaterial3: true,
            fontFamily: App.isWindows ? "font" : "",
          ),
          darkTheme: ThemeData(
            colorScheme: darkColor,
            useMaterial3: true,
            fontFamily: App.isWindows ? "font" : "",
            brightness: Brightness.dark,
          ),
          themeMode: appdata.appSettings.darkMode == 2
              ? ThemeMode.dark
              : appdata.appSettings.darkMode == 1
                  ? ThemeMode.light
                  : ThemeMode.system,
          onGenerateRoute: (settings) => AppPageRoute(
            builder: (context) => notFirstUse
                ? (appdata.settings[13] == "1"
                    ? const AuthPage()
                    : const MainPage())
                : const WelcomePage(),
          ),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en', 'US'),
          ],
          builder: (context, widget) {
            ErrorWidget.builder = (details) {
              LogManager.addLog(
                LogLevel.error,
                "Unhandled Exception",
                "${safeNetworkError(details.exception)}\n${details.stack}",
              );
              unawaited(LogManager.flush());
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              widget = OverlayWidget(widget);
              if (App.isDesktop) {
                widget = Shortcuts(
                  shortcuts: {
                    LogicalKeySet(
                      LogicalKeyboardKey.escape,
                    ): VoidCallbackIntent(() {
                      if (App.canPop) {
                        App.globalBack();
                      } else {
                        App.mainNavigatorKey?.currentContext?.pop();
                      }
                    }),
                  },
                  child: WindowFrame(widget),
                );
              }
              return _SystemUiProvider(widget);
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
