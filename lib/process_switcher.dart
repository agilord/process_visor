import 'dart:async';

/// Describes the active process context and may provide additional methods to
/// interact with it.
abstract class ProcessContext {
  /// How much tasks may be calling the client concurrently.
  final int concurrency;

  /// Optional idle timeout for this context. If specified, overrides the
  /// ProcessSwitcher's global idle timeout for this specific context.
  final Duration? idleTimeout;

  ProcessContext({required this.concurrency, this.idleTimeout});

  /// Closes the context and releases resources.
  ///
  /// When [force] is set, the implementation should use no delay to
  /// stop everything.
  FutureOr<void> close({bool force = false});
}

/// Abstract interface for context-aware process configuration.
abstract class ProcessSpec<C extends ProcessContext> {
  /// Return true if the current context can serve (equals or superset of) [pending],
  /// and no process restart is needed.
  bool accept(ProcessSpec pending);

  /// Starts a background process with the current settings and also creates a
  /// client context object that can interact with the process.
  Future<C> start();
}

/// Callback method that recieves the process context to access the currently running instance.
typedef ContextFn<C extends ProcessContext, K> = Future<K> Function(C context);

/// Base class for process handler with context switching logic.
class ProcessSwitcher {
  _Entry? _current;
  Future<void>? _switchingFuture;
  final _pendingTasks = <_PendingTask>[];
  final Duration? idleTimeout;
  Timer? _idleTimer;

  ProcessSwitcher({this.idleTimeout});

  /// Returns true if there is an active process running.
  bool get hasActiveProcess => _current != null;

  /// Execute a function with the specified context loaded
  ///
  /// If the context is already loaded and accepting requests, executes immediately
  /// via the current client. Otherwise, waits for pending requests to complete,
  /// switches to the new context, and then executes the function.
  ///
  /// If the task has higher priority than all other pending tasks and requires
  /// a different context, triggers a context switch immediately.
  ///
  /// If [preemptable] is true and this task is preempted by a higher priority
  /// task requiring a different context, the task will be re-scheduled rather
  /// than failing.
  Future<K> withContext<C extends ProcessContext, K>(
    ProcessSpec<C> spec,
    ContextFn<C, K> fn, {
    int priority = 0,
    bool preemptable = false,
  }) async {
    final task = _PendingTask(
      spec: spec,
      contextFn: (c) => fn(c as C),
      priority: priority,
      preemptable: preemptable,
    );
    _pendingTasks.add(task);

    // Wait if currently switching contexts
    while (_switchingFuture != null) {
      await _switchingFuture;
    }

    // If current context matches and accepting requests, use it
    final c = _current;
    if (c != null && c.acceptingRequests && _accept(c.spec, spec)) {
      _cancelIdleTimer();
      _current!.scheduleExecution();
      return await task.completer.future;
    }

    // Check if this task should trigger a context switch
    // (different context needed AND highest priority among all pending tasks)
    final shouldSwitch = _shouldSwitchContext(task);

    if (shouldSwitch) {
      // Need to switch contexts - create switching future for coordination
      final completer = Completer<void>();
      final switchFuture = completer.future;
      _switchingFuture = switchFuture;

      void markSwitchCompleted() {
        if (!completer.isCompleted) {
          completer.complete();
        }
        if (_switchingFuture == switchFuture) {
          _switchingFuture = null;
        }
      }

      try {
        // Stop accepting new requests on current context
        if (_current != null) {
          _current!.stopAcceptingRequests();

          if (_current?.isPreemptable ?? false) {
            // Preempt: kill process immediately and re-schedule pending tasks
            _current!.markPreempting();
            await _stopProcess(); // Kill immediately without waiting
          } else {
            // Wait for pending requests to complete gracefully
            await _current!.waitForPending();
            await _stopProcess();
          }
        }

        await _switchToContext(spec);
        markSwitchCompleted();

        // Execute the request
        _current!.scheduleExecution();
        return await task.completer.future;
      } finally {
        markSwitchCompleted();
      }
    } else {
      // Wait for the task to be picked up eventually
      _current?.scheduleExecution();
      return await task.completer.future;
    }
  }

  /// Check if a task should trigger a context switch
  bool _shouldSwitchContext(_PendingTask task) {
    // If no current context, always switch
    if (_current == null) return true;

    // If same context, no switch needed
    if (_accept(_current!.spec, task.spec)) return false;

    // Different context needed - check if this task has highest priority
    final otherTasks = _pendingTasks.where((t) => t != task).toList();
    if (otherTasks.isEmpty) return true;

    final maxOtherPriority = otherTasks
        .map((t) => t.priority)
        .reduce((a, b) => a > b ? a : b);

    return task.priority > maxOtherPriority;
  }

  /// Re-add a task to the pending queue (used when preempting)
  void _requeueTask(_PendingTask task) {
    _pendingTasks.add(task);
    // Check if we need to switch contexts for the requeued task
    _checkPendingTasksForSwitch();
  }

  /// Check if there are pending tasks that need a context switch
  void _checkPendingTasksForSwitch() {
    if (_switchingFuture != null) return; // Already switching

    if (_pendingTasks.isEmpty) return;

    // Find the highest priority task that needs a different context
    final tasksNeedingSwitch = _pendingTasks.where((task) {
      if (_current == null) return true;
      return !_accept(_current!.spec, task.spec);
    }).toList();

    if (tasksNeedingSwitch.isEmpty) return;

    // Get the highest priority task's context
    final highestPriorityTask = tasksNeedingSwitch.reduce(
      (a, b) => a.priority > b.priority ? a : b,
    );
    final targetContext = highestPriorityTask.spec;

    // Do NOT remove the task - let scheduleExecution find it in _pendingTasks

    // Mark that we're switching immediately to prevent duplicate switches
    final completer = Completer<void>();
    _switchingFuture = completer.future;

    // Schedule the switch asynchronously
    scheduleMicrotask(() async {
      void markSwitchCompleted() {
        if (!completer.isCompleted) {
          _switchingFuture = null;
          completer.complete();
        }
      }

      try {
        // Stop current context if exists
        if (_current != null) {
          _current!.stopAcceptingRequests();

          if (_current?.isPreemptable ?? false) {
            _current!.markPreempting();
            await _stopProcess();
          } else {
            await _current!.waitForPending();
            await _stopProcess();
          }
        }

        await _switchToContext(targetContext);
        markSwitchCompleted();

        _current!.scheduleExecution();
      } finally {
        markSwitchCompleted();
      }
    });
  }

  /// Called when there are no more tasks for the current context
  void _onNoMoreTasks() {
    _checkPendingTasksForSwitch();
    _startIdleTimer();
  }

  /// Start the idle timer if configured
  void _startIdleTimer() {
    if (_pendingTasks.isNotEmpty) return;
    if (_current == null) return;

    // Use context-specific timeout if available, otherwise use switcher timeout
    final timeout = _current!.context.idleTimeout ?? idleTimeout;
    if (timeout == null) return;

    _cancelIdleTimer();
    _idleTimer = Timer(timeout, () async {
      if (_pendingTasks.isEmpty && _current != null) {
        await _stopProcess();
      }
    });
  }

  /// Cancel the idle timer
  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// Get the next task for the current context (highest priority)
  _PendingTask? _getNextTask(ProcessSpec context) {
    final tasksForContext = _pendingTasks
        .where((t) => _accept(context, t.spec))
        .toList();

    if (tasksForContext.isEmpty) return null;

    // Find highest priority task
    final task = tasksForContext.reduce(
      (a, b) => a.priority >= b.priority ? a : b,
    );
    _pendingTasks.remove(task);
    return task;
  }

  /// Switch to a different context, starting/stopping processes as needed
  Future<void> _switchToContext(ProcessSpec context) async {
    final c = _current?.spec;
    if (c != null && _accept(c, context)) {
      return; // Already using the correct context
    }

    await _stopProcess();
    final cc = await context.start();
    _current = _Entry(this, context, cc, _onNoMoreTasks);
  }

  /// Stop the current llama.cpp process and cleanup
  Future<void> _stopProcess() async {
    final c = _current;
    _current = null;
    await c?.stop();
  }

  /// Stop all processes and cleanup resources
  Future<void> stop() async {
    _cancelIdleTimer();
    await _stopProcess();
  }
}

class _Entry<C extends ProcessContext> {
  final ProcessSwitcher _switcher;
  final ProcessSpec spec;
  final C context;
  final void Function() _onNoMoreTasks;
  final _runningFutures = <Future>[];
  bool _acceptingRequests = true;
  bool _preempting = false;
  int _preemptBlockCounter = 0;

  _Entry(this._switcher, this.spec, this.context, this._onNoMoreTasks);

  bool get acceptingRequests => _acceptingRequests;

  bool get isPreemptable => _preemptBlockCounter == 0;

  /// Mark this entry as being preempted
  void markPreempting() {
    _preempting = true;
  }

  /// Schedule execution of pending tasks from the handler's queue
  void scheduleExecution() {
    if (!_acceptingRequests) {
      return;
    }
    if (_runningFutures.length >= context.concurrency) {
      return;
    }

    scheduleMicrotask(() async {
      final task = _switcher._getNextTask(spec);
      if (task == null) {
        // No more tasks for this context, notify the switcher
        if (_runningFutures.isEmpty && _acceptingRequests) {
          _onNoMoreTasks();
        }
        return;
      }
      final done = Completer();
      final doneFuture = done.future;
      _runningFutures.add(doneFuture);
      if (!task.preemptable) {
        _preemptBlockCounter++;
      }
      try {
        final result = await task.contextFn(context);
        task.completer.complete(result);
      } catch (e, stack) {
        // If we're preempting and the task is preemptable, re-queue it
        if (_preempting && task.preemptable) {
          _switcher._requeueTask(task);
        } else {
          // Otherwise, complete with error
          task.completer.completeError(e, stack);
        }
      } finally {
        if (!task.preemptable) {
          _preemptBlockCounter--;
        }
        _runningFutures.remove(doneFuture);
        done.complete();
        scheduleExecution();
      }
    });
  }

  /// Stop accepting new requests (existing ones continue)
  void stopAcceptingRequests() {
    _acceptingRequests = false;
  }

  /// Wait for all pending requests to complete
  Future<void> waitForPending() async {
    if (_runningFutures.isEmpty) return;
    await Future.wait(_runningFutures);
  }

  Future<void> stop() async {
    _acceptingRequests = false;
    await context.close();
  }
}

class _PendingTask {
  final ProcessSpec spec;
  final ContextFn contextFn;
  final int priority;
  final bool preemptable;
  final completer = Completer();

  _PendingTask({
    required this.spec,
    required this.contextFn,
    required this.priority,
    required this.preemptable,
  });
}

bool _accept(ProcessSpec c1, ProcessSpec c2) {
  return c1 == c2 || c1.accept(c2);
}
