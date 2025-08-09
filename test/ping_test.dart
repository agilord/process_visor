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

    test(
      'started future should complete when process reaches running',
      () async {
        // Skip test on Windows as it uses different ping syntax
        if (Platform.isWindows) {
          return;
        }

        visor = ProcessVisor(args: ['echo', 'hello'], logWriter: logWriter);

        // Start process and await started future
        await visor.start();
        await visor.started;

        // Should be running after started completes
        expect(visor.status, equals(ProcessStatus.running));
      },
    );

    test('started future should complete with start indicator', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      visor = ProcessVisor(
        args: ['ping', '127.0.0.1'],
        logWriter: logWriter,
        startIndicator: (record) => record.text.contains('64 bytes from'),
      );

      // Start process
      await visor.start();
      expect(visor.status, equals(ProcessStatus.starting));

      // Await started future - should complete when start indicator triggers
      await visor.started;
      expect(visor.status, equals(ProcessStatus.running));
    });

    test(
      'started future should error when ProcessVisor is closed before starting',
      () async {
        visor = ProcessVisor(
          args: ['ping', '127.0.0.1'],
          logWriter: logWriter,
          startIndicator: (record) => record.text.contains('64 bytes from'),
        );

        await visor.start();
        expect(visor.status, equals(ProcessStatus.starting));

        // Close before process reaches running
        visor.close();

        // Started future should complete with error
        await expectLater(
          visor.started,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('ProcessVisor was closed before process started'),
            ),
          ),
        );
      },
    );

    test('started future should error when accessed before start', () async {
      visor = ProcessVisor(args: ['echo', 'hello'], logWriter: logWriter);

      // Accessing started before calling start() should return error
      await expectLater(
        visor.started,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Process not started'),
          ),
        ),
      );
    });

    test('statusChanges stream should emit status transitions', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      visor = ProcessVisor(
        args: ['ping', '127.0.0.1'],
        logWriter: logWriter,
        startIndicator: (record) => record.text.contains('64 bytes from'),
      );

      final statusEvents = <ProcessStatus>[];
      final subscription = visor.statusChanges.listen(statusEvents.add);

      try {
        // Start process
        await visor.start();
        expect(statusEvents.contains(ProcessStatus.starting), isTrue);

        // Wait for running status
        await visor.started;
        expect(statusEvents.contains(ProcessStatus.running), isTrue);

        // Stop process
        await visor.stop();

        // Wait a bit for all status changes to be emitted
        await Future.delayed(const Duration(milliseconds: 100));

        expect(statusEvents.contains(ProcessStatus.stopping), isTrue);
        expect(statusEvents.contains(ProcessStatus.absent), isTrue);

        // Verify the expected sequence
        expect(statusEvents.length, greaterThanOrEqualTo(4));
        expect(statusEvents[0], equals(ProcessStatus.starting));
        expect(statusEvents.contains(ProcessStatus.running), isTrue);
        expect(statusEvents.contains(ProcessStatus.stopping), isTrue);
        expect(statusEvents.last, equals(ProcessStatus.absent));
      } finally {
        await subscription.cancel();
      }
    });

    test('statusChanges stream should work with multiple listeners', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      visor = ProcessVisor(args: ['echo', 'hello'], logWriter: logWriter);

      final statusEvents1 = <ProcessStatus>[];
      final statusEvents2 = <ProcessStatus>[];

      final subscription1 = visor.statusChanges.listen(statusEvents1.add);
      final subscription2 = visor.statusChanges.listen(statusEvents2.add);

      try {
        await visor.start();
        await visor.started;
        await visor.stop();

        // Both listeners should receive the same events
        expect(statusEvents1.length, greaterThan(0));
        expect(statusEvents2.length, equals(statusEvents1.length));
        expect(statusEvents1, equals(statusEvents2));
      } finally {
        await subscription1.cancel();
        await subscription2.cancel();
      }
    });

    test('started future should be unique per start attempt', () async {
      // Skip test on Windows as it uses different ping syntax
      if (Platform.isWindows) {
        return;
      }

      visor = ProcessVisor(args: ['echo', 'hello'], logWriter: logWriter);

      // First start
      await visor.start();
      final firstStarted = visor.started;
      await firstStarted;
      await visor.stop();

      // Second start - should get new future
      await visor.start();
      final secondStarted = visor.started;
      await secondStarted;

      // Should be different futures
      expect(identical(firstStarted, secondStarted), isFalse);
    });
  });
}
