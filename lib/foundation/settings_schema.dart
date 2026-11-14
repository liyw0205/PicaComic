class SettingsSchema {
  static const version = 1;

  static List<String> decode(Object? value, List<String> defaults,
      {bool strict = false}) {
    if (value is! List || value.isEmpty || value.any((e) => e is! String)) {
      throw const FormatException('Invalid settings list');
    }
    final result = List<String>.from(defaults);
    for (var i = 0; i < value.length && i < result.length; i++) {
      result[i] = value[i] as String;
    }
    void check(int index, bool valid) {
      if (valid) return;
      if (strict) throw FormatException('Invalid setting at index $index');
      result[index] = defaults[index];
    }

    void range(int index, int min, int max) {
      final n = int.tryParse(result[index]);
      check(index, n != null && n >= min && n <= max);
    }

    for (final i in [
      0,
      2,
      3,
      4,
      5,
      6,
      7,
      10,
      11,
      12,
      13,
      14,
      15,
      18,
      20,
      25,
      29,
      30,
      36,
      38,
      42,
      43,
      47,
      49,
      52,
      53,
      55,
      57,
      60,
      61,
      64,
      66,
      70,
      72,
      73,
      78,
      80,
      81,
      83,
      84,
      88,
      91,
    ]) {
      range(i, 0, 1);
    }
    check(1, const ['dd', 'da', 'ld', 'vd'].contains(result[1]));
    range(9, 1, 4);
    range(16, 0, 10);
    range(17, 0, 99);
    range(19, 0, 10);
    range(23, 0, 4);
    range(27, 0, 12);
    check(26, RegExp(r'^[0-3][01]$').hasMatch(result[26]));
    check(28,
        const ['0', '1', '2', '3', '4', '5', '10', '15'].contains(result[28]));
    range(32, 0, 2);
    range(33, 1, 60);
    range(34, 0, 1000000);
    range(35, 0, 1048576);
    range(37, 0, 99);
    range(39, 0, 10);
    range(40, 0, 50);
    range(41, 0, 2);
    range(46, 0, 9007199254740991);
    range(54, 0, 2);
    range(63, 0, 10000);
    range(65, 0, 10000);
    range(69, 0, 2);
    range(71, 1, 99);
    range(76, 0, 2);
    check(79, const ['1', '2', '4', '6', '8', '16'].contains(result[79]));
    check(50, const ['', 'cn', 'tw', 'en'].contains(result[50]));
    check(82, RegExp(r'^[01]{6}$').hasMatch(result[82]));
    final size = double.tryParse(result[74]);
    check(74, size != null && size.isFinite && size >= 0.5 && size <= 3);
    final tile = result[44].split(',');
    final scale = tile.length == 2 ? double.tryParse(tile[1]) : null;
    check(
        44,
        tile.length == 2 &&
            const ['0', '1'].contains(tile[0]) &&
            scale != null &&
            scale.isFinite &&
            scale >= 0.5 &&
            scale <= 3);
    return result;
  }
}
