import 'dart:io';

import 'package:process_visor/process_visor.dart';
import 'package:test/test.dart';

void main() {
  group('Ping Test', () {
    late List<LogRecord> logRecords;
    late ProcessVisor visor;

    void logWriter(LogRecord record) {
      logRecords.add(record);
    }

    setUp(() {
      logRecords = [];
    });

    tearDown(() async {
      if (visor.status == ProcessStatus.running) {
        await visor.stop();
      }
      visor.close();
    });

    test(
      'should run ping command for 5 seconds and capture 4-6 log lines',
      () async {
        // Skip test on Windows as it uses different ping syntax
        if (Platform.isWindows) {
          return;
        }

        visor = ProcessVisor(args: ['ping', '127.0.0.1'], logWriter: logWriter);

        // Start the ping process
        await visor.start();
        expect(visor.status, equals(ProcessStatus.running));

        // Let it run for 5 seconds
        await Future.delayed(const Duration(seconds: 5));
        expect(visor.status, equals(ProcessStatus.running));

        // Stop the process
        await visor.stop();
        expect(visor.status, equals(ProcessStatus.absent));

        // Filter out non-ping output logs (startup/shutdown messages)
        final pingOutputLogs = logRecords
            .where(
              (record) =>
                  record.text.contains('64 bytes from') ||
                  record.text.contains('PING') ||
                  record.text.contains('bytes of data'),
            )
            .toList();

        // Expect 4-6 ping-related log lines (typically one per second plus initial output)
        expect(pingOutputLogs.length, inInclusiveRange(4, 6));

        // Verify we have process lifecycle logs
        expect(
          logRecords.any((r) => r.text.contains('Starting process')),
          isTrue,
        );
        expect(
          logRecords.any((r) => r.text.contains('Process started with PID')),
          isTrue,
        );
        expect(
          logRecords.any((r) => r.text.contains('Stopping process')),
          isTrue,
        );

        // Verify PID is exposed and persists after process stops
        expect(visor.pid, isNotNull);
        expect(visor.pid, greaterThan(0));
      },
    );

    test('should expose PID of process', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      visor = ProcessVisor(args: ['echo', 'hello'], logWriter: logWriter);

      // Initially no PID
      expect(visor.pid, isNull);

      // Start process
      await visor.start();
      expect(visor.pid, isNotNull);
      expect(visor.pid, greaterThan(0));

      final originalPid = visor.pid;

      // Wait for echo to complete
      await Future.delayed(const Duration(milliseconds: 100));

      // PID should persist after process exits
      expect(visor.pid, equals(originalPid));
    });

    test('should use start indicator to control running status', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      bool startIndicatorTriggered = false;

      visor = ProcessVisor(
        args: ['ping', '127.0.0.1'],
        logWriter: logWriter,
        startIndicator: (record) {
          // Look for the first ping response to indicate the process is ready
          if (record.text.contains('64 bytes from') &&
              !startIndicatorTriggered) {
            startIndicatorTriggered = true;
            return true;
          }
          return false;
        },
      );

      // Start the process
      await visor.start();

      // Should be in starting state initially (with start indicator)
      expect(visor.status, equals(ProcessStatus.starting));

      // Wait for the first ping response to trigger the start indicator
      await Future.delayed(const Duration(seconds: 2));

      // Should now be running after start indicator triggered
      expect(visor.status, equals(ProcessStatus.running));
      expect(startIndicatorTriggered, isTrue);

      // Verify we have the ready message
      expect(
        logRecords.any(
          (r) => r.text.contains(
            'Process is now ready (start indicator triggered)',
          ),
        ),
        isTrue,
      );

      await visor.stop();
    });

    test(
      'should transition to running immediately without start indicator',
      () async {
        // Skip test on Windows as it uses different ping syntax
        if (Platform.isWindows) {
          return;
        }

        visor = ProcessVisor(
          args: ['ping', '127.0.0.1'],
          logWriter: logWriter,
          // No start indicator provided
        );

        // Start the process
        await visor.start();

        // Should be running immediately (no start indicator)
        expect(visor.status, equals(ProcessStatus.running));

        await visor.stop();
      },
    );
  });
}
