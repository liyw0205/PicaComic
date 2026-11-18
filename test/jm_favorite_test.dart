import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/res.dart';

class _FavoriteNetwork extends JmNetwork {
  _FavoriteNetwork(this.responses) : super.create();

  final List<Res<dynamic>> responses;
  final requests = <String>[];

  @override
  Future<Res<dynamic>> post(String url, String data) async {
    requests.add('$url?$data');
    return responses.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling a favorite propagates a failed toggle', () async {
    final network = _FavoriteNetwork([
      const Res.error('session expired'),
    ]);

    final result = await network.favorite('123', null);

    expect(result.success, isFalse);
    expect(result.errorMessage, 'session expired');
    expect(network.requests, hasLength(1));
  });

  test('cancelling an existing favorite succeeds without a second toggle',
      () async {
    final network = _FavoriteNetwork([
      const Res<dynamic>({'type': 'del'}),
    ]);

    final result = await network.favorite('123', null);

    expect(result.success, isTrue);
    expect(result.data, isFalse);
    expect(network.requests, hasLength(1));
  });

  test('cancelling an unfavorited item retries the toggle', () async {
    final network = _FavoriteNetwork([
      const Res<dynamic>({'type': 'add'}),
      const Res<dynamic>({'type': 'del'}),
    ]);

    final result = await network.favorite('123', null);

    expect(result.success, isTrue);
    expect(result.data, isFalse);
    expect(network.requests, hasLength(2));
  });
}
