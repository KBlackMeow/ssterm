import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/mcp_server_config.dart';
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

  test('MCP connection failures produce one concise warning', () async {
    final output = <String>[];
    await runZoned(
      () async {
        await McpService.connect(
          McpServerConfig(
            id: 'missing',
            displayName: 'Missing',
            enabled: true,
            command: '__ssterm_missing_mcp_command__',
          ),
        );
        await McpService.shutdown();
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => output.add(line),
      ),
    );

    final warnings = output.where((line) => line.startsWith('[mcp] warn'));
    expect(warnings, hasLength(1));
    expect(
      warnings.single,
      startsWith('[mcp] warn missing: Connection failed:'),
    );
    expect(warnings.single, isNot(contains('\n')));
    expect(warnings.single, isNot(contains('[ERROR]')));
    expect(output, isNot(contains('[mcp] disconnected missing')));
  });

  test('MCP warning formatter removes stacks and caps long messages', () {
    final warning = McpService.conciseWarning(
      'StateError: Bad state: ${List.filled(240, 'x').join()}\nstack trace',
    );

    expect(warning, hasLength(200));
    expect(warning, endsWith('…'));
    expect(warning, isNot(contains('\n')));
    expect(warning, isNot(startsWith('StateError:')));
  });

  test('HTTP MCP failure warnings identify the configured URL', () {
    final warning = McpService.failureWarning(
      McpServerConfig(
        id: 'remote',
        displayName: 'Remote',
        transport: McpTransportType.streamableHttp,
        url: 'https://example.com/mcp',
      ),
      'Connection failed: TimeoutException',
    );

    expect(
      warning,
      'https://example.com/mcp — Connection failed: TimeoutException',
    );
  });
}
