import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart http_service.dart <port>');
    exit(1);
  }

  final port = int.parse(args[0]);
  final server = await HttpServer.bind('localhost', port);

  print('HTTP service listening on port $port');

  await for (final request in server) {
    await _handleRequest(request);
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  try {
    // Check for sleep query parameter
    final sleepParam = request.uri.queryParameters['sleep'];
    if (sleepParam != null) {
      final sleepMs = int.tryParse(sleepParam) ?? 0;
      if (sleepMs > 0) {
        await Future.delayed(Duration(milliseconds: sleepMs));
      }
    }

    // Read request body
    final body = await utf8.decoder.bind(request).join();

    // Convert headers to map
    final headers = <String, List<String>>{};
    request.headers.forEach((name, values) {
      headers[name] = values;
    });

    // Create echo response
    final response = {
      'method': request.method,
      'path': request.uri.path,
      'query': request.uri.queryParameters,
      'headers': headers,
      'body': body,
    };

    // Send response
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response));
    await request.response.close();
  } catch (e) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error: $e');
    await request.response.close();
  }
}
