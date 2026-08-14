import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import 'agent_tool_contract.dart';

/// A versioned, inert transcript snapshot. It intentionally excludes native
/// tool calls/results: those may contain commands, paths, or provider payloads
/// and must never become executable state after an app restart.
class AgentSessionSnapshot {
  const AgentSessionSnapshot({
    required this.sessionId,
    required this.savedAt,
    required this.items,
  });

  static const schemaVersion = 1;
  static const maxItems = 64;
  static const maxItemCharacters = 12000;

  final String sessionId;
  final DateTime savedAt;
  final List<AgentSessionTranscriptItem> items;

  factory AgentSessionSnapshot.fromHistory({
    required String sessionId,
    required Iterable<AgentConversationItem> history,
    DateTime? savedAt,
  }) {
    final items = <AgentSessionTranscriptItem>[];
    for (final item in history) {
      if (item.toolCalls.isNotEmpty || item.toolResults.isNotEmpty) continue;
      final role = item.role;
      final content = item.content;
      if (role == null || content == null || !_isSafeRole(role)) continue;
      items.add(
        AgentSessionTranscriptItem(role: role, content: _truncate(content)),
      );
    }
    final start = items.length > maxItems ? items.length - maxItems : 0;
    return AgentSessionSnapshot(
      sessionId: sessionId,
      savedAt: (savedAt ?? DateTime.now()).toUtc(),
      items: List.unmodifiable(items.sublist(start)),
    );
  }

  factory AgentSessionSnapshot.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Snapshot must be an object');
    if (raw['version'] != schemaVersion) {
      throw const FormatException('Unsupported agent session snapshot version');
    }
    final sessionId = raw['sessionId'];
    final savedAt = raw['savedAt'];
    final rawItems = raw['items'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        savedAt is! String ||
        rawItems is! List ||
        rawItems.length > maxItems) {
      throw const FormatException('Invalid agent session snapshot');
    }
    final parsedSavedAt = DateTime.tryParse(savedAt);
    if (parsedSavedAt == null) throw const FormatException('Invalid save time');
    return AgentSessionSnapshot(
      sessionId: sessionId,
      savedAt: parsedSavedAt.toUtc(),
      items: List.unmodifiable([
        for (final item in rawItems) AgentSessionTranscriptItem.fromJson(item),
      ]),
    );
  }

  Map<String, Object> toJson() => {
    'version': schemaVersion,
    'sessionId': sessionId,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };

  static bool _isSafeRole(String role) => role == 'user' || role == 'assistant';

  static String _truncate(String value) {
    if (value.length <= maxItemCharacters) return value;
    return '${value.substring(0, maxItemCharacters)}\n[Persisted transcript truncated]';
  }
}

class AgentSessionTranscriptItem {
  const AgentSessionTranscriptItem({required this.role, required this.content});

  final String role;
  final String content;

  factory AgentSessionTranscriptItem.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid transcript item');
    final role = raw['role'];
    final content = raw['content'];
    if (role is! String ||
        !AgentSessionSnapshot._isSafeRole(role) ||
        content is! String ||
        content.length > AgentSessionSnapshot.maxItemCharacters + 64) {
      throw const FormatException('Invalid transcript item');
    }
    return AgentSessionTranscriptItem(role: role, content: content);
  }

  AgentConversationItem toConversationItem() =>
      AgentConversationItem.text(role: role, content: content);

  Map<String, String> toJson() => {'role': role, 'content': content};
}

enum AgentSessionLoadState { empty, restored, discarded }

class AgentSessionLoadResult {
  const AgentSessionLoadResult._(this.state, this.snapshot);

  const AgentSessionLoadResult.empty()
    : this._(AgentSessionLoadState.empty, null);
  const AgentSessionLoadResult.discarded()
    : this._(AgentSessionLoadState.discarded, null);
  const AgentSessionLoadResult.restored(AgentSessionSnapshot snapshot)
    : this._(AgentSessionLoadState.restored, snapshot);

  final AgentSessionLoadState state;
  final AgentSessionSnapshot? snapshot;
}

/// File-backed agent snapshots. Every write uses a sibling temporary file and
/// rename so an interruption cannot leave a half-written live snapshot.
class AgentSessionStore {
  AgentSessionStore({this.file, this.sessionId = 'default'});

  final File? file;
  final String sessionId;

  Future<AgentSessionLoadResult> load() async {
    final target = await _file();
    if (!await target.exists()) return const AgentSessionLoadResult.empty();
    try {
      final decoded = jsonDecode(await target.readAsString());
      final snapshot = AgentSessionSnapshot.fromJson(decoded);
      if (snapshot.sessionId != sessionId) {
        throw const FormatException('Session id mismatch');
      }
      return AgentSessionLoadResult.restored(snapshot);
    } catch (_) {
      await _quarantine(target);
      return const AgentSessionLoadResult.discarded();
    }
  }

  Future<void> save(AgentSessionSnapshot snapshot) async {
    if (snapshot.sessionId != sessionId) {
      throw ArgumentError.value(snapshot.sessionId, 'snapshot.sessionId');
    }
    final encoded = const JsonEncoder().convert(snapshot.toJson());
    if (utf8.encode(encoded).length > 256 * 1024) {
      throw const FormatException('Agent session snapshot is too large');
    }
    final target = await _file();
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> clear() async {
    final target = await _file();
    if (await target.exists()) await target.delete();
  }

  Future<File> _file() async {
    final override = file;
    if (override != null) return override;
    final dir = await appDataDir();
    return File('${dir.path}/agent-sessions/$sessionId.json');
  }

  Future<void> _quarantine(File target) async {
    try {
      final quarantined = File(
        '${target.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
      );
      await target.rename(quarantined.path);
    } catch (_) {
      // A best-effort quarantine must never make startup fail.
    }
  }
}
