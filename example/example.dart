import 'package:process_visor/process_visor.dart';

void main() async {
  final visor = ProcessVisor(
    args: ['ping', '127.0.0.1'],
    logWriter: (record) => print('${record.pid}: ${record.text}'),
    restartOnFailure: true,
  );

  await visor.start();
  // Process runs and outputs logs...
  await visor.stop();
  visor.close();
}
