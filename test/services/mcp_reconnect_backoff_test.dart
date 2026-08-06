import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/mcp_service.dart';

void main() {
  test('MCP reconnect backoff caps repeated retry delays at 30 seconds', () {
    expect(List.generate(6, McpReconnectBackoff.delayForFailure), const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
      Duration(seconds: 30),
    ]);
  });
}
