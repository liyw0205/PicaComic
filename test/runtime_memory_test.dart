import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/runtime_memory.dart';

void main() {
  test('memory samples validate and serialize bounded numeric fields', () {
    final sample = RuntimeMemorySnapshot.fromMap({
      'totalPssKb': 100,
      'privateDirtyKb': 40.4,
      'nativePssKb': 20,
      'dalvikPssKb': 30,
      'otherPssKb': 10,
      'javaHeapUsedKb': 50,
      'javaHeapMaxKb': 128,
    });

    expect(sample, isNotNull);
    expect(sample!.privateDirtyKb, 40);
    expect(sample.toJson()['totalPssKb'], 100);
  });

  test('memory samples reject missing, negative, and non-numeric values', () {
    final valid = <Object?, Object?>{
      'totalPssKb': 100,
      'privateDirtyKb': 40,
      'nativePssKb': 20,
      'dalvikPssKb': 30,
      'otherPssKb': 10,
      'javaHeapUsedKb': 50,
      'javaHeapMaxKb': 128,
    };
    expect(RuntimeMemorySnapshot.fromMap({...valid}..remove('otherPssKb')),
        isNull);
    expect(RuntimeMemorySnapshot.fromMap({...valid, 'nativePssKb': -1}), isNull);
    expect(RuntimeMemorySnapshot.fromMap({...valid, 'nativePssKb': '20'}),
        isNull);
  });
}

