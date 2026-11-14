import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('indexed history pages keep object allocation bounded at 50k rows',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('pica_database_perf_');
    try {
      for (final count in [1000, 10000, 50000]) {
        final path = '${directory.path}/$count.db';
        final manager = HistoryManager.create();
        await manager.init(databasePath: path, importLegacy: false);
        manager.close();
        final fixture = sqlite3.open(path);
        final groups = List.generate(50, (i) => '($i)').join(',');
        const digits = '(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)';
        fixture.execute('''
          WITH groups(g) AS (VALUES $groups), digits(d) AS (VALUES $digits),
          sequence(n) AS (
            SELECT g * 1000 + a.d * 100 + b.d * 10 + c.d
            FROM groups CROSS JOIN digits a CROSS JOIN digits b CROSS JOIN digits c
          )
          INSERT INTO history(target,title,subtitle,cover,time,type,ep,page,readEpisode,max_page)
          SELECT 'target_' || n, 'Title', 'Author', '', 1700000000000 + n,
            0, 1, 1, '1', 10 FROM sequence WHERE n < $count;
        ''');
        final plan = fixture.select('''
          explain query plan select * from history
          order by time DESC, target ASC limit 60;
        ''').map((row) => row['detail']).join(' ');
        expect(plan, contains('history_time_target'));
        expect(plan, isNot(contains('TEMP B-TREE')));
        fixture.dispose();
        await manager.init(databasePath: path, importLegacy: false);
        manager.getPage();
        manager.getAll();
        final pageTimes = <int>[];
        final allTimes = <int>[];
        for (var sample = 0; sample < 5; sample++) {
          final stopwatch = Stopwatch()..start();
          final page = manager.getPage();
          pageTimes.add(stopwatch.elapsedMicroseconds);
          expect(page.length, 60);
          stopwatch.reset();
          final all = manager.getAll();
          allTimes.add(stopwatch.elapsedMicroseconds);
          stopwatch.stop();
          expect(all.length, count);
        }
        pageTimes.sort();
        allTimes.sort();
        // Synchronous isolate time includes SQL decoding and History allocation.
        print('history rows=$count page60 p50_us=${pageTimes[2]} '
            'p95_us=${pageTimes[4]} full p50_us=${allTimes[2]} '
            'p95_us=${allTimes[4]} plan=$plan');
        manager.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
