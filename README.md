# Process Visor

A simple Dart package for managing OS processes with automatic restart capabilities.

## Features

- Start, stop, and restart processes
- Capture stdout/stderr output via callbacks
- Automatic restart on process failure
- Graceful shutdown with force-kill fallback
- Optional startup readiness detection
- Reactive status monitoring via stream
- Await process startup completion

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
