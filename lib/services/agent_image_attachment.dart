import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A validated image that can be represented in every supported provider's
/// vision-input wire format.
class AgentImageAttachment {
  final String mimeType;
  final String base64Data;
  final String displayName;

  const AgentImageAttachment({
    required this.mimeType,
    required this.base64Data,
    required this.displayName,
  });
}

class AgentImageAttachmentException implements Exception {
  final String message;
  const AgentImageAttachmentException(this.message);

  @override
  String toString() => message;
}

/// Validates and reads local image files before they enter a model request.
class AgentImageAttachmentReader {
  AgentImageAttachmentReader._();

  static const maxBytes = 10 * 1024 * 1024;

  static const _mimeTypes = <String, String>{
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bmp': 'image/bmp',
  };

  static Future<AgentImageAttachment> read({
    required String path,
    String? workspaceRoot,
  }) async {
    final requested = File(path);
    final target = await requested.resolveSymbolicLinks();
    if (workspaceRoot != null) {
      final root = await Directory(workspaceRoot).resolveSymbolicLinks();
      if (target != root && !p.isWithin(root, target)) {
        throw const AgentImageAttachmentException(
          'Image path must be inside the current workspace.',
        );
      }
    }
    final extension = p.extension(target).toLowerCase();
    final mimeType = _mimeTypes[extension];
    if (mimeType == null) {
      throw AgentImageAttachmentException('Unsupported image type: $extension');
    }
    final file = File(target);
    final length = await file.length();
    if (length > maxBytes) {
      throw AgentImageAttachmentException(
        'Image is larger than the ${maxBytes ~/ (1024 * 1024)} MB limit.',
      );
    }
    return AgentImageAttachment(
      mimeType: mimeType,
      base64Data: base64Encode(await file.readAsBytes()),
      displayName: p.basename(target),
    );
  }
}
