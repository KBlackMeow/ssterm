import 'agent_file_search.dart';
import 'agent_output_store.dart';
import 'agent_utf8_page.dart';
import 'file_write_service.dart';

class AgentReadResult {
  const AgentReadResult(this.content, {this.isError = false});

  final String content;
  final bool isError;
}

/// Executes bounded read-only tools independently of the chat panel.
class AgentReadTools {
  const AgentReadTools({required this.outputStore, this.fileSystem});

  final AgentOutputStore outputStore;
  final FileSystemAdapter? fileSystem;

  Future<AgentReadResult> execute(
    String name,
    Map<String, Object?> arguments,
  ) async {
    try {
      switch (name) {
        case 'read_output':
          final id = arguments['id'];
          final offset = arguments['offset'];
          if (id is! String || offset is! int) {
            throw ArgumentError('id and offset are required');
          }
          final page = await outputStore.readPage(
            id,
            offset: offset,
            maxBytes: _maxBytes(arguments),
          );
          return AgentReadResult(
            '[Output artifact $id bytes $offset-${page.nextOffset} '
            'of ${page.storedBytes}]\n${page.content}\n'
            '${page.hasMore ? 'Continue with offset=${page.nextOffset}.' : 'End of stored output.'}',
          );
        case 'read_file':
          final adapter = _availableFileSystem();
          final path = arguments['path'];
          final offset = arguments['offset'];
          if (path is! String || offset is! int) {
            throw ArgumentError('path and offset are required');
          }
          final chunk = await adapter.readRange(
            path,
            offset: offset,
            maxBytes: _maxBytes(arguments),
          );
          final decoded = AgentUtf8Page.decode(
            chunk.bytes,
            hasMore: chunk.hasMore,
          );
          final nextOffset = chunk.offset + decoded.consumed;
          return AgentReadResult(
            '[File $path bytes ${chunk.offset}-$nextOffset '
            'of ${chunk.totalBytes}]\n'
            '${decoded.text}\n'
            '${nextOffset < chunk.totalBytes ? 'Continue with offset=$nextOffset.' : 'End of file.'}',
          );
        case 'grep_file':
          final adapter = _availableFileSystem();
          final path = arguments['path'];
          final pattern = arguments['pattern'];
          if (path is! String || pattern is! String) {
            throw ArgumentError('path and pattern are required');
          }
          return AgentReadResult(
            await AgentFileSearch.search(
              adapter: adapter,
              path: path,
              pattern: pattern,
              ignoreCase: arguments['ignore_case'] == true,
            ),
          );
        default:
          throw ArgumentError('Unknown read tool: $name');
      }
    } catch (error) {
      return AgentReadResult('[$name failed] $error', isError: true);
    }
  }

  FileSystemAdapter _availableFileSystem() {
    final adapter = fileSystem;
    if (adapter == null || !adapter.isAvailable) {
      throw StateError('The active file system is unavailable.');
    }
    return adapter;
  }

  int _maxBytes(Map<String, Object?> arguments) {
    final value = arguments['max_bytes'];
    final maxBytes = value is int ? value : 4096;
    if (maxBytes < 4 || maxBytes > 8192) {
      throw ArgumentError('max_bytes must be between 4 and 8192');
    }
    return maxBytes;
  }
}
