import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  ComicReadingPageLogic createLogic() => ComicReadingPageLogic(
        1,
        PicacgReadingData('Orientation fixture', 'orientation-fixture', []),
        1,
        () {},
      );

  void disposeLogic(ComicReadingPageLogic logic) {
    logic.releaseImageTasks();
    logic.pageController.dispose();
    logic.scrollController.dispose();
    logic.focusNode.dispose();
    logic.clearPhotoViewControllers();
  }

  test('disabling fixed orientation releases the lock and clears rotation',
      () async {
    final logic = createLogic()..rotation = true;
    addTearDown(() => disposeLogic(logic));

    await logic.applyFixedOrientation(0);

    expect(logic.rotation, isNull);
    expect(calls, hasLength(1));
    expect(
      calls.single,
      isMethodCall(
        'SystemChrome.setPreferredOrientations',
        arguments: DeviceOrientation.values
            .map((orientation) => orientation.toString())
            .toList(),
      ),
    );
  });

  test('fixed orientations apply the selected lock and clear rotation',
      () async {
    final logic = createLogic();
    addTearDown(() => disposeLogic(logic));

    await logic.applyFixedOrientation(1);
    expect(logic.rotation, isNull);
    expect(
      calls.last,
      isMethodCall(
        'SystemChrome.setPreferredOrientations',
        arguments: [
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ],
      ),
    );

    logic.rotation = false;
    await logic.applyFixedOrientation(2);
    expect(logic.rotation, isNull);
    expect(
      calls.last,
      isMethodCall(
        'SystemChrome.setPreferredOrientations',
        arguments: [
          'DeviceOrientation.portraitUp',
          'DeviceOrientation.portraitDown',
        ],
      ),
    );
  });

  test('rejects unsupported fixed orientation settings', () async {
    final logic = createLogic();
    addTearDown(() => disposeLogic(logic));

    expect(() => logic.applyFixedOrientation(3), throwsArgumentError);
    expect(calls, isEmpty);
  });
}
