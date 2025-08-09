import 'package:process_visor/process_visor.dart';

void main() async {
  final visor = ProcessVisor(
    args: ['ping', '127.0.0.1'],
    logWriter: (record) => print('${record.pid}: ${record.text}'),
    restartOnFailure: true,
  );

  // Monitor status changes
  visor.statusChanges.listen((status) => print('Status changed to: $status'));

  await visor.start();
  print('Process starting...');

  // Wait for process to be ready
  await visor.started;
  print('Process is now running!');

  // Let it run for a few seconds
  await Future.delayed(Duration(seconds: 3));

  await visor.stop();
  visor.close();
}
