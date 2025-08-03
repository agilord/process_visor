# Process Visor

A simple Dart package for managing OS processes with automatic restart capabilities.

## Features

- Start, stop, and restart processes
- Capture stdout/stderr output via callbacks
- Automatic restart on process failure
- Graceful shutdown with force-kill fallback
- Optional startup readiness detection

## Usage

```dart
import 'package:process_visor/process_visor.dart';

final visor = ProcessVisor(
  args: ['ping', '127.0.0.1'],
  logWriter: (record) => print('${record.pid}: ${record.text}'),
  restartOnFailure: true,
);

await visor.start();
// Process runs and outputs logs...
await visor.stop();
visor.close();
```
