A Dart package for managing OS processes with automatic restart capabilities.

Also a process switcher, where higher-priority tasks may interrupt background processing.

## Managing a process

- Start, stop, and restart processes
- Capture stdout/stderr output via callbacks
- Automatic restart on process failure
- Graceful shutdown with force-kill fallback
- Startup readiness detection
- Reactive status monitoring via stream
- Await process startup completion

## Process switcher

- Context- and compatibility-aware process switching
- Priority-based scheduling and preemption
- Stops process after configured idle duration

## Usage

```dart
import 'package:process_visor/process_visor.dart';

final visor = ProcessVisor(
  args: ['ping', '127.0.0.1'],
  logWriter: (record) => print('${record.pid}: ${record.text}'),
  restartOnFailure: true,
);

await visor.start();
await visor.started; // Wait for process to be ready

// Monitor status changes
visor.statusChanges.listen((status) => print('Status: $status'));

// Process runs and outputs logs...
await visor.stop();
visor.close();
```

### ProcessSwitcher

Manage multiple process contexts with automatic switching:

```dart
import 'package:process_visor/process_switcher.dart';

final switcher = ProcessSwitcher<MyProcess>();

// Execute with priority-based context switching
await switcher.withContext(
  mySpec,
  (context) async => await context.doWork(),
  priority: 10,
  preemptable: true,
);

await switcher.stop();
```
