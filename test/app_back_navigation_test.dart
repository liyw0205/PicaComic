import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/app_shortcuts.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/pages/accounts_page.dart';
import 'package:pica_comic/tools/mouse_listener.dart';
import 'package:pica_comic/tools/translations.dart';

class _RouteObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

class _PopupAccountSource extends ComicSource {
  _PopupAccountSource()
      : super.named(
          name: 'Test account',
          key: 'popup-account-test',
          filePath: 'built-in',
          account: AccountConfig.named(
              logout: () {},
              login: (_, __) async {
                throw StateError('Login is not part of this navigation test');
              }),
        );

  int saves = 0;

  @override
  Future<void> saveData() async {
    saves++;
  }
}

Widget _page(String text, {Widget Function(Widget)? wrap}) {
  final body = Focus(autofocus: true, child: Center(child: Text(text)));
  return Scaffold(body: wrap?.call(body) ?? body);
}

void main() {
  AppTranslation.translations = const {};
  late GlobalKey<NavigatorState>? previousNavigator;
  late GlobalKey<NavigatorState> childNavigator;
  late _RouteObserver rootObserver;
  late _RouteObserver childObserver;

  setUp(() {
    previousNavigator = App.mainNavigatorKey;
    childNavigator = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = childNavigator;
    rootObserver = _RouteObserver();
    childObserver = _RouteObserver();
  });

  tearDown(() => App.mainNavigatorKey = previousNavigator);

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [rootObserver],
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => AppShortcuts(child: child!),
      home: Navigator(
        key: childNavigator,
        observers: [childObserver],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _page('Home'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester, String input) async {
    if (input == 'escape') {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    } else if (input == 'framework') {
      await tester.binding.handlePopRoute();
    } else if (input == 'barrier') {
      await tester.tapAt(const Offset(10, 10));
    } else if (input == 'title') {
      await tester.tap(find.byIcon(Icons.arrow_back_sharp));
    } else {
      mouseSideButtonCallback();
    }
    await tester.pumpAndSettle();
  }

  Future<void> openPane(WidgetTester tester,
      {bool onRootPage = false, Widget Function(Widget)? wrapHome}) async {
    final paneObserver = NaviObserver();
    final pane = NaviPane(
      paneItems: [
        PaneItemEntry(
          label: 'Library',
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
      ],
      paneActions: const [],
      observer: paneObserver,
      pageBuilder: (_) => Navigator(
        key: childNavigator,
        observers: [paneObserver, childObserver],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _page('Home', wrap: wrapHome),
        ),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      navigatorObservers: [rootObserver],
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: onRootPage ? _page('Outside pane') : pane,
    ));
    await tester.pumpAndSettle();
    if (onRootPage) {
      App.navigatorKey.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => pane,
      ));
      await tester.pumpAndSettle();
    }
  }

  group('navigation pane framework back', () {
    late int systemPops;

    setUp(() {
      systemPops = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') systemPops++;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('pops one child route and preserves the root', (tester) async {
      await openPane(tester);
      for (final title in ['Details', 'More details']) {
        childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
          builder: (_) => _page(title),
        ));
        await tester.pumpAndSettle();
      }

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Details'), findsOneWidget);
      expect(find.text('More details'), findsNothing);
      expect(childObserver.popped, hasLength(1));
      expect(rootObserver.popped, isEmpty);
      expect(systemPops, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('respects child PopScope until its guard is released',
        (tester) async {
      await openPane(tester);
      final pops = <bool>[];
      final allowPop = ValueNotifier(false);
      addTearDown(allowPop.dispose);
      childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: allowPop,
          builder: (_, value, child) => PopScope<void>(
            canPop: value,
            onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
            child: child!,
          ),
          child: _page('Protected'),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Protected'), findsOneWidget);
      expect(pops, [false]);
      expect(childObserver.popped, isEmpty);
      expect(rootObserver.popped, isEmpty);
      expect(systemPops, 0);

      allowPop.value = true;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(pops, [false, true]);
      expect(childObserver.popped, hasLength(1));
      expect(systemPops, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('closes root dialogs before child details', (tester) async {
      await openPane(tester);
      childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => _page('Details'),
      ));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: childNavigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Root dialog')),
      );
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Root dialog'), findsNothing);
      expect(find.text('Details'), findsOneWidget);
      expect(rootObserver.popped, hasLength(1));
      expect(childObserver.popped, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(childObserver.popped, hasLength(1));
      expect(systemPops, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('delegates the final route back to the system once',
        (tester) async {
      await openPane(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(rootObserver.popped, isEmpty);
      expect(childObserver.popped, isEmpty);
      expect(systemPops, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('honors a guard on the only child route before system exit',
        (tester) async {
      final pops = <bool>[];
      final allowPop = ValueNotifier(false);
      addTearDown(allowPop.dispose);
      await openPane(tester,
          wrapHome: (child) => ValueListenableBuilder<bool>(
                valueListenable: allowPop,
                builder: (_, value, child) => PopScope<void>(
                  canPop: value,
                  onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
                  child: child!,
                ),
                child: child,
              ));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(pops, [false]);
      expect(systemPops, 0);

      allowPop.value = true;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(rootObserver.popped, isEmpty);
      expect(childObserver.popped, isEmpty);
      expect(systemPops, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('popping an outer pane route does not request system exit',
        (tester) async {
      await openPane(tester, onRootPage: true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Outside pane'), findsOneWidget);
      expect(rootObserver.popped, hasLength(1));
      expect(childObserver.popped, isEmpty);
      expect(systemPops, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an explicit outer pop does not also pop a child route',
        (tester) async {
      await openPane(tester, onRootPage: true);
      childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => _page('Details'),
      ));
      await tester.pumpAndSettle();

      App.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.text('Outside pane'), findsOneWidget);
      expect(rootObserver.popped, hasLength(1));
      expect(childObserver.popped, isEmpty);
      expect(systemPops, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('popup navigation', () {
    Widget popupPage(String title) => PopUpWidgetScaffold(
          title: title,
          body: const Focus(autofocus: true, child: SizedBox.expand()),
        );

    for (final input in ['barrier', 'framework', 'escape', 'mouse', 'title']) {
      testWidgets('$input respects the only popup page guard', (tester) async {
        await open(tester);
        final allowPop = ValueNotifier(false);
        addTearDown(allowPop.dispose);
        final pops = <bool>[];
        final route = PopUpWidget<void>(ValueListenableBuilder<bool>(
          valueListenable: allowPop,
          builder: (_, value, child) => PopScope<void>(
            canPop: value,
            onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
            child: child!,
          ),
          child: popupPage('Protected popup'),
        ));
        App.navigatorKey.currentState!.push<void>(route);
        await tester.pumpAndSettle();

        await back(tester, input);
        expect(find.text('Protected popup'), findsOneWidget);
        expect(pops, [false]);
        expect(rootObserver.popped, isEmpty);
        expect(childObserver.popped, isEmpty);
        expect(route.popGestureEnabled, isFalse);

        allowPop.value = true;
        await tester.pumpAndSettle();
        expect(route.popGestureEnabled, isTrue);
        await back(tester, input);
        expect(find.text('Protected popup'), findsNothing);
        expect(find.text('Home'), findsOneWidget);
        expect(pops, [false]);
        expect(rootObserver.popped, [route]);
        expect(childObserver.popped, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('$input returns one popup page before closing',
          (tester) async {
        await open(tester);
        final route = PopUpWidget<void>(popupPage('Popup home'));
        App.navigatorKey.currentState!.push<void>(route);
        await tester.pumpAndSettle();
        final navigator = Navigator.of(tester.element(find.text('Popup home')));
        final innerPops = <bool>[];
        navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => PopScope<void>(
            onPopInvokedWithResult: (didPop, _) => innerPops.add(didPop),
            child: popupPage('Popup details'),
          ),
        ));
        await tester.pumpAndSettle();

        await back(tester, input);
        expect(find.text('Popup home'), findsOneWidget);
        expect(find.text('Popup details'), findsNothing);
        expect(innerPops, [true]);
        expect(rootObserver.popped, isEmpty);
        expect(childObserver.popped, isEmpty);
        expect(navigator.canPop(), isFalse);

        await back(tester, input);
        expect(find.text('Popup home'), findsNothing);
        expect(rootObserver.popped, [route]);
        expect(innerPops, [true]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('popup title returns to its hosting child navigator',
        (tester) async {
      await openPane(tester, onRootPage: true);
      childNavigator.currentState!.push<void>(
        PopUpWidget<void>(popupPage('Child popup')),
      );
      await tester.pumpAndSettle();

      await back(tester, 'title');
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Child popup'), findsNothing);
      expect(childObserver.popped, hasLength(1));
      expect(rootObserver.popped, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('root dialog closes before guarded popup content',
        (tester) async {
      await open(tester);
      final pops = <bool>[];
      final route = PopUpWidget<void>(PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
        child: popupPage('Protected popup'),
      ));
      App.navigatorKey.currentState!.push<void>(route);
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.text('Protected popup')),
        builder: (_) => const AlertDialog(content: Text('New dialog')),
      );
      await tester.pumpAndSettle();

      await back(tester, 'framework');
      expect(find.text('New dialog'), findsNothing);
      expect(find.text('Protected popup'), findsOneWidget);
      expect(pops, isEmpty);
      expect(rootObserver.popped, hasLength(1));
      await back(tester, 'framework');
      expect(pops, [false]);
      expect(find.text('Protected popup'), findsOneWidget);

      App.globalBack();
      await tester.pumpAndSettle();
      expect(find.text('Protected popup'), findsNothing);
      expect(rootObserver.popped, hasLength(2));
      expect(pops, [false]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('accounts login returns inside the popup first',
        (tester) async {
      final previousSources = ComicSource.sources;
      addTearDown(() => ComicSource.sources = previousSources);
      final source = _PopupAccountSource();
      ComicSource.sources = [source];
      await open(tester);
      showPopUpWidget<void>(
          App.navigatorKey.currentContext!, const AccountsPage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));

      await back(tester, 'framework');
      expect(find.text('账号管理'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(rootObserver.popped, isEmpty);
      expect(source.saves, 1);
      await back(tester, 'title');
      expect(find.text('Home'), findsOneWidget);
      expect(rootObserver.popped, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('popup resizing preserves its inner navigation stack',
      (tester) async {
    await open(tester);
    App.navigatorKey.currentState!.push<void>(
      PopUpWidget<void>(_page('Popup home')),
    );
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.text('Popup home')));
    navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => _page('Popup details'),
    ));
    await tester.pumpAndSettle();

    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.text('Popup details'), findsOneWidget);
    expect(Navigator.of(tester.element(find.text('Popup details'))), navigator);
    await back(tester, 'framework');
    expect(find.text('Popup home'), findsOneWidget);
    expect(rootObserver.popped, isEmpty);
    await back(tester, 'framework');
    expect(find.text('Home'), findsOneWidget);
    expect(rootObserver.popped, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit popup completion preserves its result', (tester) async {
    await open(tester);
    final pops = <bool>[];
    final result = showPopUpWidget<String>(
      App.navigatorKey.currentContext!,
      PopScope<String>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
        child: _page('Protected popup'),
      ),
    );
    await tester.pumpAndSettle();

    App.navigatorKey.currentState!.pop('Saved');
    await tester.pumpAndSettle();
    expect(await result, 'Saved');
    expect(pops, isEmpty);
    expect(find.text('Home'), findsOneWidget);
    expect(rootObserver.popped, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final input in ['escape', 'mouse']) {
    testWidgets('$input preserves the last root and child routes',
        (tester) async {
      await open(tester);
      await back(tester, input);
      await back(tester, input);

      expect(find.text('Home'), findsOneWidget);
      expect(rootObserver.popped, isEmpty);
      expect(childObserver.popped, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$input closes child details once', (tester) async {
      await open(tester);
      childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => _page('Details'),
      ));
      await tester.pumpAndSettle();
      await back(tester, input);

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Details'), findsNothing);
      expect(rootObserver.popped, isEmpty);
      expect(childObserver.popped, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$input closes root dialogs before child details',
        (tester) async {
      await open(tester);
      childNavigator.currentState!.push<void>(MaterialPageRoute<void>(
        builder: (_) => _page('Details'),
      ));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: childNavigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Root dialog')),
      );
      await tester.pumpAndSettle();
      await back(tester, input);

      expect(find.text('Root dialog'), findsNothing);
      expect(find.text('Details'), findsOneWidget);
      expect(rootObserver.popped, hasLength(1));
      expect(childObserver.popped, isEmpty);
      await back(tester, input);
      expect(find.text('Home'), findsOneWidget);
      expect(childObserver.popped, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final root in [false, true]) {
      testWidgets('$input respects ${root ? 'root' : 'child'} route PopScope',
          (tester) async {
        await open(tester);
        final pops = <bool>[];
        final navigator = root
            ? App.navigatorKey.currentState!
            : childNavigator.currentState!;
        navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => _page('Protected',
              wrap: (body) => PopScope<void>(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) => pops.add(didPop),
                    child: body,
                  )),
        ));
        await tester.pumpAndSettle();
        await back(tester, input);

        expect(find.text('Protected'), findsOneWidget);
        expect(pops, [false]);
        expect(rootObserver.popped, isEmpty);
        expect(childObserver.popped, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('$input is harmless when app navigation is unavailable',
        (tester) async {
      App.mainNavigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        builder: (_, child) => AppShortcuts(child: child!),
        home: _page('Standalone'),
      ));
      await tester.pumpAndSettle();
      await back(tester, input);

      expect(find.text('Standalone'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
