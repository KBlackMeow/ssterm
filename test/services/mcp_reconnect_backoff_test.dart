import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/mcp_service.dart';

void main() {
  test('MCP reconnect retries every three seconds after any failure', () {
    expect(List.generate(6, McpReconnectBackoff.delayForFailure), const [
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 3),
    ]);
  });
}
