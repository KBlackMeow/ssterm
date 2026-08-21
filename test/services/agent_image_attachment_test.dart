import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_image_attachment.dart';

void main() {
  test(
    'loads an image within the allowed workspace as a vision attachment',
    () async {
      final root = await Directory.systemTemp.createTemp('ssterm-image-root-');
      addTearDown(() => root.delete(recursive: true));
      final image = File('${root.path}/diagram.png');
      await image.writeAsBytes([137, 80, 78, 71]);

      final attachment = await AgentImageAttachmentReader.read(
        path: image.path,
        workspaceRoot: root.path,
      );

      expect(attachment.mimeType, 'image/png');
      expect(attachment.displayName, 'diagram.png');
      expect(attachment.base64Data, 'iVBORw==');
    },
  );

  test('rejects a path outside the allowed workspace', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-image-root-');
    final outside = await Directory.systemTemp.createTemp('ssterm-image-out-');
    addTearDown(() async {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    });
    final image = File('${outside.path}/diagram.png');
    await image.writeAsBytes([137, 80, 78, 71]);

    await expectLater(
      AgentImageAttachmentReader.read(
        path: image.path,
        workspaceRoot: root.path,
      ),
      throwsA(isA<AgentImageAttachmentException>()),
    );
  });
}
