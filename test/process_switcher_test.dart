import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:process_visor/process_switcher.dart';
import 'package:process_visor/process_visor.dart';
import 'package:test/test.dart';

/// Helper function to make HTTP GET requests
Future<Map<String, dynamic>> httpGet(HttpClient client, String url) async {
  final uri = Uri.parse(url);
  final request = await client.getUrl(uri);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return jsonDecode(responseBody) as Map<String, dynamic>;
}

void main() {
  group('ProcessSwitcher', () {
    late ProcessSwitcher switcher;

    setUp(() {
      switcher = ProcessSwitcher();
    });

    tearDown(() async {
      await switcher.stop();
      // Give ports time to be released
      await Future.delayed(Duration(milliseconds: 100));
    });

    test('basic context switching and execution', () async {
      final context1 = HttpServiceSpec(port: 8001);
      final context2 = HttpServiceSpec(port: 8002);

      // Execute with first context
      final result1 = await switcher.withContext(context1, (context) async {
        final data = await httpGet(
          context.client,
          'http://localhost:8001/test',
        );
        return data['path'] as String;
      });
      expect(result1, '/test');

      // Execute with second context (should switch)
      final result2 = await switcher.withContext(context2, (context) async {
        final data = await httpGet(
          context.client,
          'http://localhost:8002/hello',
        );
        return data['path'] as String;
      });
      expect(result2, '/hello');

      // Execute with first context again (should switch back)
      final result3 = await switcher.withContext(context1, (context) async {
        final data = await httpGet(
          context.client,
          'http://localhost:8001/world',
        );
        return data['path'] as String;
      });
      expect(result3, '/world');
    });

    test('multiple requests on same context execute sequentially', () async {
      final context = HttpServiceSpec(port: 8003);
      final started = <int>[];
      final results = <String>[];

      final futures = <Future>[];
      for (var i = 0; i < 5; i++) {
        final future = switcher.withContext(context, (context) async {
          started.add(i);
          final data = await httpGet(
            context.client,
            'http://localhost:8003/task$i?sleep=50',
          );
          final path = data['path'] as String;
          results.add(path);
          return path;
        });
        futures.add(future);
      }

      await Future.wait(futures);
      expect(started, [0, 1, 2, 3, 4]);
      expect(results.toSet(), {
        '/task0',
        '/task1',
        '/task2',
        '/task3',
        '/task4',
      });
    });

    test(
      'higher priority task preempts lower priority preemptable tasks',
      () async {
        final context1 = HttpServiceSpec(port: 8004);
        final context2 = HttpServiceSpec(port: 8005);

        final executionLog = <String>[];
        final completedTasks = <String>[];

        // Start a low-priority, preemptable task with delay
        final lowPriorityFuture = switcher.withContext(
          context1,
          (context) async {
            executionLog.add('1/1');
            final data = await httpGet(
              context.client,
              'http://localhost:8004/low?sleep=1000',
            );
            completedTasks.add('low1');
            executionLog.add('1/2');
            return data['path'] as String;
          },
          priority: 1,
          preemptable: true,
        );

        // Give it time to start
        await Future.delayed(Duration(milliseconds: 50));

        // Start a high-priority task requiring different context
        final highPriorityFuture = switcher.withContext(
          context2,
          (context) async {
            executionLog.add('2/1');
            final data = await httpGet(
              context.client,
              'http://localhost:8005/high?sleep=50',
            );
            completedTasks.add('high');
            executionLog.add('2/2');
            return data['path'] as String;
          },
          priority: 10,
          preemptable: false,
        );

        // Wait for both to complete
        await Future.wait([highPriorityFuture, lowPriorityFuture]);

        expect(completedTasks, ['high', 'low1']);
        expect(executionLog, ['1/1', '2/1', '2/2', '1/1', '1/2']);
      },
    );

    test('concurrent execution with proper concurrency limit', () async {
      final context = HttpServiceSpec(port: 8008, concurrency: 3);

      final futures = <Future>[];

      for (var i = 0; i < 6; i++) {
        final future = switcher.withContext(context, (context) async {
          final data = await httpGet(
            context.client,
            'http://localhost:8008/task$i?sleep=50',
          );
          return data['path'] as String;
        });
        futures.add(future);
      }

      // All 6 tasks should complete
      final results = await Future.wait(futures);

      expect(results.length, 6);
      // Verify all tasks completed successfully
      for (var i = 0; i < 6; i++) {
        expect(results[i], '/task$i');
      }
    });

    test('non-preemptable tasks complete before context switch', () async {
      final context1 = HttpServiceSpec(port: 8009);
      final context2 = HttpServiceSpec(port: 8010);

      final executionLog = <String>[];

      final task1Started = Completer();
      // Start a non-preemptable task with delay
      final task1 = switcher.withContext(
        context1,
        (context) async {
          task1Started.complete();
          executionLog.add('task1_start');
          final data = await httpGet(
            context.client,
            'http://localhost:8009/task1?sleep=400',
          );
          executionLog.add('task1_end');
          return data['path'] as String;
        },
        priority: 1,
        preemptable: false, // Not preemptable
      );

      await task1Started.future;

      // Start high priority task on different context
      final task2 = switcher.withContext(
        context2,
        (context) async {
          executionLog.add('task2_start');
          final data = await httpGet(
            context.client,
            'http://localhost:8010/task2?sleep=50',
          );
          executionLog.add('task2_end');
          return data['path'] as String;
        },
        priority: 10,
        preemptable: false,
      );

      // Wait for both to complete
      await Future.wait([task1, task2]);

      // Task1 should complete before task2 starts (non-preemptable)
      expect(
        executionLog.indexOf('task1_end'),
        lessThan(executionLog.indexOf('task2_start')),
      );
    });

    test('same context accepts requests without switching', () async {
      final context1a = HttpServiceSpec(port: 8011);
      final context1b = HttpServiceSpec(port: 8011); // Same port

      final executionLog = <String>[];

      // First request
      await switcher.withContext(context1a, (context) async {
        executionLog.add('request1');
        await httpGet(context.client, 'http://localhost:8011/test1');
        return 200;
      });

      // Second request with "same" context (should not switch)
      await switcher.withContext(context1b, (context) async {
        executionLog.add('request2');
        await httpGet(context.client, 'http://localhost:8011/test2');
        return 200;
      });

      expect(executionLog, ['request1', 'request2']);
    });

    test('idle timeout stops process after inactivity', () async {
      final idleSwitcher = ProcessSwitcher(
        idleTimeout: Duration(milliseconds: 200),
      );

      try {
        final context = HttpServiceSpec(port: 8012);

        // Execute a task
        await idleSwitcher.withContext(context, (context) async {
          await httpGet(context.client, 'http://localhost:8012/test');
          return 200;
        });

        // Process should be active after task execution
        expect(idleSwitcher.hasActiveProcess, isTrue);

        // Wait for idle timeout to elapse
        await Future.delayed(Duration(milliseconds: 300));

        // Process should have stopped after idle timeout
        expect(idleSwitcher.hasActiveProcess, isFalse);

        // Execute another task - should work even after idle timeout
        await idleSwitcher.withContext(context, (context) async {
          await httpGet(context.client, 'http://localhost:8012/test2');
          return 200;
        });

        // Process should be active again
        expect(idleSwitcher.hasActiveProcess, isTrue);
      } finally {
        await idleSwitcher.stop();
        await Future.delayed(Duration(milliseconds: 100));
      }
    });
  });
}

/// HTTP service context that starts an HTTP server on a specific port
class HttpServiceSpec implements ProcessSpec<HttpServiceContext> {
  final int port;
  final int _concurrency;

  HttpServiceSpec({required this.port, int concurrency = 1})
    : _concurrency = concurrency;

  @override
  bool accept(ProcessSpec pending) {
    if (pending is! HttpServiceSpec) return false;
    return pending.port == port;
  }

  @override
  Future<HttpServiceContext> start() async {
    // Start the HTTP service process
    final process = ProcessVisor(
      args: [Platform.executable, 'test/http_service.dart', port.toString()],
      logWriter: (record) {
        // Optionally log process output for debugging
        // print('[${record.pid}] ${record.text}');
      },
      startIndicator: (record) {
        // Wait for the server to report it's listening
        return record.text.contains('HTTP service listening on port $port');
      },
    );

    await process.start();
    // Wait for the process to be ready (indicated by the startIndicator)
    await process.started;

    // Create HTTP client
    final client = HttpClient();
    return HttpServiceContext._(process, client, concurrency: _concurrency);
  }
}

class HttpServiceContext extends ProcessContext {
  final ProcessVisor _process;
  final HttpClient client;

  HttpServiceContext._(this._process, this.client, {super.concurrency = 1});

  @override
  FutureOr<void> close({bool force = false}) async {
    await _process.stop();
    client.close();
  }
}
