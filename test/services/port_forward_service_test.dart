import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/port_forward_rule.dart';
import 'package:ssterm/services/port_forward_service.dart';

void main() {
  group('PortForwardException', () {
    test('renders all failed rule labels', () {
      const rule = PortForwardRule(
        type: ForwardType.local,
        localPort: 8080,
        remoteHost: '127.0.0.1',
        remotePort: 80,
      );
      final e = PortForwardException(['${rule.label}: address in use']);

      expect(e.toString(), contains('L 8080'));
      expect(e.toString(), contains('address in use'));
    });
  });
}
