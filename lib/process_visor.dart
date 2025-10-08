import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The current status of the managed process.
enum ProcessStatus {
  /// Process has not been started or has been stopped.
  absent,

  /// Process has been launched but is not yet considered ready.
  /// This state is used when a [StartIndicator] is provided.
  starting,

  /// Process is running and ready (or immediately ready if no [StartIndicator]).
  running,

  /// Process is being stopped.
  stopping,
}

/// A log record containing process output or internal messages.
///
/// - [pid]: The process ID, or null for internal messages
/// - [isError]: Whether this is an error message (stderr) or normal output
/// - [text]: The actual log message text
typedef LogRecord = ({int? pid, bool isError, String text});

/// A function that handles log records from the process or internal operations.
///
/// This callback receives all output from the managed process (stdout/stderr)
/// as well as internal status messages from ProcessVisor itself.
typedef LogWriter = void Function(LogRecord record);

/// A function that determines when a starting process should be considered "running".
///
/// This callback is invoked for each [LogRecord] while the process status is
/// [ProcessStatus.starting]. When it returns `true`, the status transitions to
/// [ProcessStatus.running].
///
/// If no [StartIndicator] is provided, the process transitions to running immediately
/// after being spawned.
typedef StartIndicator = bool Function(LogRecord record);

/// A process supervisor that can start, stop, restart, and monitor an OS process.
///
/// ProcessVisor manages the lifecycle of a single process, providing:
/// - Process spawning with configurable working directory and environment
/// - Stream handling for stdout/stderr output via [LogWriter] callbacks
/// - Automatic restart on process failure (configurable)
/// - Graceful shutdown with fallback to force kill
/// - Optional startup readiness detection via [StartIndicator]
///
/// Example usage:
/// ```dart
/// final visor = ProcessVisor(
///   args: ['ping', '127.0.0.1'],
///   logWriter: (record) => print('${record.pid}: ${record.text}'),
///   restartOnFailure: true,
///   startIndicator: (record) => record.text.contains('64 bytes'),
/// );
///
/// await visor.start();
/// // Process runs and logs output...
/// await visor.stop();
/// visor.close(); // Clean up resources
/// ```
class ProcessVisor {
  final List<String> _args;
  final String? _workingDirectory;
  final Map<String, String>? _environment;
  final bool _restartOnFailure;
  final LogWriter _logWriter;
  final StartIndicator? _startIndicator;

  Process? _process;
  ProcessStatus _status = ProcessStatus.absent;
  final _statusController = StreamController<ProcessStatus>.broadcast();
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  bool _closed = false;
  Completer<void>? _stopCompleter;
  Completer<void>? _startedCompleter;
  int? _pid;

  /// Creates a new ProcessVisor to manage a process.
  ///
  /// - [args]: Command and arguments to execute (first element is the executable)
  /// - [workingDirectory]: Working directory for the process (defaults to current)
  /// - [environment]: Environment variables for the process (defaults to inherited)
  /// - [restartOnFailure]: Whether to automatically restart on non-zero exit codes
  /// - [logWriter]: Callback to handle all log output from process and internal messages
  /// - [startIndicator]: Optional callback to determine when process is ready
  ///
  /// The [startIndicator] is useful for processes that need initialization time.
  /// If provided, the process status remains [ProcessStatus.starting] until the
  /// indicator returns `true` for a log record.
  ProcessVisor({
    required List<String> args,
    String? workingDirectory,
    Map<String, String>? environment,
    bool restartOnFailure = false,
    required LogWriter logWriter,
    StartIndicator? startIndicator,
  }) : _args = args,
       _workingDirectory = workingDirectory,
       _environment = environment,
       _restartOnFailure = restartOnFailure,
       _logWriter = logWriter,
       _startIndicator = startIndicator;

  /// The current status of the managed process.
  ///
  /// Returns one of:
  /// - [ProcessStatus.absent]: No process running
  /// - [ProcessStatus.starting]: Process launched but not yet ready
  /// - [ProcessStatus.running]: Process is ready and running
  /// - [ProcessStatus.stopping]: Process is being terminated
  ProcessStatus get status => _status;

  /// A stream of status changes for the managed process.
  ///
  /// Emits a new [ProcessStatus] value whenever the process status changes.
  /// This is useful for reactive monitoring of the process lifecycle.
  Stream<ProcessStatus> get statusChanges => _statusController.stream;

  /// A future that completes when the process reaches its first running status.
  ///
  /// This future completes successfully when the process status first transitions
  /// to [ProcessStatus.running]. If the ProcessVisor is closed before the process
  /// starts, the future completes with a [StateError].
  ///
  /// Each call to [start] creates a new future, so this represents the startup
  /// of the current process attempt.
  Future<void> get started =>
      _startedCompleter?.future ??
      Future.error(StateError('Process not started'));

  /// The process ID (PID) of the currently running or last ran process.
  ///
  /// Returns `null` if no process has been started yet.
  /// Once a process is started, this value persists even after the process
  /// exits or is stopped, until a new process is started.
  int? get pid => _pid;

  /// Starts the managed process.
  ///
  /// If the process is already running or starting, this method returns without
  /// taking any action. Otherwise, it spawns the process and sets up monitoring.
  ///
  /// The process status transitions:
  /// - If no [StartIndicator]: [ProcessStatus.absent] → [ProcessStatus.starting] → [ProcessStatus.running]
  /// - If [StartIndicator] provided: [ProcessStatus.absent] → [ProcessStatus.starting] → waits for indicator → [ProcessStatus.running]
  ///
  /// Throws [ProcessException] if the process cannot be started.
  /// Throws [StateError] if the ProcessVisor has been closed.
  Future<void> start() async {
    if (_closed) throw StateError('ProcessVisor has been closed');
    if (_status == ProcessStatus.running || _status == ProcessStatus.starting) {
      return;
    }

    // Create new started completer for this start attempt
    _completeStartedIfNeeded();
    _startedCompleter = Completer<void>();

    _updateStatus(ProcessStatus.starting);
    _logWriter((
      pid: null,
      isError: false,
      text: 'Starting process: ${_args.join(' ')}',
    ));

    try {
      _process = await Process.start(
        _args.first,
        _args.skip(1).toList(),
        workingDirectory: _workingDirectory,
        environment: _environment,
      );

      _pid = _process!.pid;
      _logWriter((
        pid: _process!.pid,
        isError: false,
        text: 'Process started with PID: ${_process!.pid}',
      ));

      _connectStreams();
      _monitorProcess();

      // If no start indicator, immediately transition to running
      if (_startIndicator == null) {
        _updateStatus(ProcessStatus.running);
      }
    } catch (e) {
      _updateStatus(ProcessStatus.absent);
      _logWriter((
        pid: null,
        isError: true,
        text: 'Failed to start process: $e',
      ));
      rethrow;
    }
  }

  /// Stops the managed process gracefully.
  ///
  /// If the process is not running, this method returns without taking any action.
  /// Otherwise, it:
  /// 1. Sends SIGTERM to the process
  /// 2. Waits up to 5 seconds for graceful shutdown
  /// 3. If still running, sends SIGKILL to force termination
  /// 4. Cleans up all resources and sets status to [ProcessStatus.absent]
  ///
  /// This method is safe to call multiple times.
  Future<void> stop() async {
    if (_status != ProcessStatus.running && _status != ProcessStatus.starting) {
      return;
    }

    _updateStatus(ProcessStatus.stopping);
    _logWriter((pid: _process?.pid, isError: false, text: 'Stopping process'));

    if (_process != null) {
      try {
        _process!.kill(ProcessSignal.sigterm);

        final result = await _process!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _logWriter((
              pid: _process?.pid,
              isError: false,
              text: 'Force killing process',
            ));
            _process!.kill(ProcessSignal.sigkill);
            return _process!.exitCode;
          },
        );

        _logWriter((
          pid: _process?.pid,
          isError: false,
          text: 'Process stopped with exit code: $result',
        ));
      } catch (e) {
        _logWriter((
          pid: _process?.pid,
          isError: true,
          text: 'Error stopping process: $e',
        ));
      }
    }

    await _cleanup();
    _updateStatus(ProcessStatus.absent);

    if (_stopCompleter != null && !_stopCompleter!.isCompleted) {
      _stopCompleter!.complete();
    }
  }

  /// Restarts the managed process by stopping it and starting it again.
  ///
  /// This method:
  /// 1. Calls [stop] to gracefully terminate the current process
  /// 2. Calls [start] to spawn a new process
  ///
  /// Throws [ProcessException] if the new process cannot be started.
  /// Throws [StateError] if the ProcessVisor has been closed.
  Future<void> restart() async {
    await stop();
    await start();
  }

  /// Closes the ProcessVisor and releases all resources.
  ///
  /// This method stops any running process and cancels all stream subscriptions.
  /// Once closed, the ProcessVisor cannot be reused - calling [start], [stop],
  /// or [restart] will throw a [StateError].
  ///
  /// If auto-restart is enabled, closing the ProcessVisor will prevent any
  /// further restart attempts even if the process fails after this call.
  ///
  /// It's safe to call this method multiple times.
  void close() {
    if (_closed) return;
    _closed = true;

    if (_status == ProcessStatus.running || _status == ProcessStatus.starting) {
      stop();
    }

    _completeStartedIfNeeded();
    _statusController.close();
  }

  /// Complete started completer with error if not yet completed
  void _completeStartedIfNeeded() {
    if (_startedCompleter != null && !_startedCompleter!.isCompleted) {
      _startedCompleter!.completeError(
        StateError('ProcessVisor was closed before process started'),
      );
    }
  }

  void _connectStreams() {
    if (_process == null) return;

    StreamSubscription connect(Stream<List<int>> stream, bool isError) {
      return stream
          .transform(Utf8Decoder(allowMalformed: true))
          .transform(LineSplitter())
          .listen(
            (text) {
              text = text.trim();
              if (text.isNotEmpty) {
                final record = (
                  pid: _process!.pid,
                  isError: isError,
                  text: text,
                );
                _logWriter(record);
                _checkStartIndicator(record);
              }
            },
            onError: (error) {
              final record = (
                pid: _process?.pid,
                isError: true,
                text: '${isError ? 'stderr' : 'stdout'} error: $error',
              );
              _logWriter(record);
              _checkStartIndicator(record);
            },
          );
    }

    _stdoutSubscription = connect(_process!.stdout, false);
    _stderrSubscription = connect(_process!.stderr, true);
  }

  void _monitorProcess() {
    if (_process == null) return;

    _process!.exitCode
        .then((exitCode) async {
          _logWriter((
            pid: _process?.pid,
            isError: exitCode != 0,
            text: 'Process exited with code: $exitCode',
          ));

          await _cleanup();

          if (_closed) {
            _updateStatus(ProcessStatus.absent);
            return;
          }

          if (_restartOnFailure && exitCode != 0) {
            _logWriter((
              pid: null,
              isError: false,
              text: 'Restarting process due to failure',
            ));
            _updateStatus(ProcessStatus.absent);
            await Future.delayed(const Duration(seconds: 1));
            await start();
          } else {
            _updateStatus(ProcessStatus.absent);
          }
        })
        .catchError((error) {
          _logWriter((
            pid: _process?.pid,
            isError: true,
            text: 'Process monitoring error: $error',
          ));
          _updateStatus(ProcessStatus.absent);
        });
  }

  void _updateStatus(ProcessStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      if (!_statusController.isClosed) {
        _statusController.add(newStatus);
      }

      final isCompleted = _startedCompleter?.isCompleted ?? false;
      if (!isCompleted) {
        switch (newStatus) {
          case ProcessStatus.starting:
            break;
          case ProcessStatus.running:
            _startedCompleter!.complete();
            break;
          case ProcessStatus.stopping:
          case ProcessStatus.absent:
            _completeStartedIfNeeded();
        }
      }
    }
  }

  void _checkStartIndicator(LogRecord record) {
    if (_startIndicator != null && _status == ProcessStatus.starting) {
      if (_startIndicator(record)) {
        _updateStatus(ProcessStatus.running);
        _logWriter((
          pid: _process?.pid,
          isError: false,
          text: 'Process is now ready (start indicator triggered)',
        ));
      }
    }
  }

  Future<void> _cleanup() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
  }
}
