import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error returned by the box (see PROTOCOL.md error codes) or a network failure.
class BoxError implements Exception {
  BoxError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// One connection to a box. Same messages over every transport (PROTOCOL.md).
abstract class BoxApi {
  /// Shown to the user, e.g. "SyncLight-AB12" or "192.168.1.70".
  String get label;

  Future<Map<String, dynamic>> call(
    String cmd, [
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 8),
  ]);

  void close();
}

/// Talks to synclight-agent over HTTP: POST /api/v1/rpc with {id, cmd, args}.
class HttpBoxApi implements BoxApi {
  HttpBoxApi(this.host, {this.port = 8484});

  final String host;
  final int port;
  final http.Client _client = http.Client();
  int _id = 0;

  Uri get _uri => Uri(scheme: 'http', host: host, port: port, path: '/api/v1/rpc');

  @override
  String get label => host;

  @override
  Future<Map<String, dynamic>> call(
    String cmd, [
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 8),
  ]) async {
    final id = ++_id;
    final http.Response resp;
    try {
      resp = await _client
          .post(
            _uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id': id, 'cmd': cmd, 'args': args}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw BoxError('timeout', 'The box did not answer in time.');
    } catch (e) {
      throw BoxError('offline', 'Cannot reach the box at $host.');
    }

    final dynamic body;
    try {
      body = jsonDecode(resp.body);
    } catch (_) {
      throw BoxError('bad_reply', 'The box sent an unexpected reply.');
    }
    if (body is Map && body['ok'] == true) {
      final data = body['data'];
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
    throw errorFromReply(body);
  }

  @override
  void close() => _client.close();
}

BoxError errorFromReply(dynamic body) {
  final err = (body is Map && body['error'] is Map) ? body['error'] as Map : const {};
  return BoxError('${err['code'] ?? 'error'}', '${err['message'] ?? 'Unknown error'}');
}

/// Friendly text for common error codes.
String explainError(Object e) {
  if (e is BoxError) {
    switch (e.code) {
      case 'offline':
      case 'timeout':
        return 'Can\'t reach the SyncLight box. Is it powered on and nearby?';
      case 'wled_unavailable':
        return 'The LED controller isn\'t responding. Check that it has power.';
      case 'hyperion_unavailable':
        return 'The light engine on the box is starting up. Try again in a moment.';
      case 'hyperion_auth':
        return 'The box can\'t save settings (Hyperion password). See the box setup.';
      case 'busy':
        return 'Finish or cancel the TV setup first.';
      default:
        return e.message;
    }
  }
  return e.toString();
}
