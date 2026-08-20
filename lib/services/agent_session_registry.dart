import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../utils/app_dir.dart';

class AgentSessionDescriptor {
  const AgentSessionDescriptor({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  AgentSessionDescriptor copyWith({String? title, DateTime? updatedAt}) =>
      AgentSessionDescriptor(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, String> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory AgentSessionDescriptor.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid agent session');
    final id = raw['id'];
    final title = raw['title'];
    final createdAt = raw['createdAt'];
    final updatedAt = raw['updatedAt'];
    if (id is! String ||
        title is! String ||
        createdAt is! String ||
        updatedAt is! String) {
      throw const FormatException('Invalid agent session');
    }
    final created = DateTime.tryParse(createdAt);
    final updated = DateTime.tryParse(updatedAt);
    if (created == null || updated == null) {
      throw const FormatException('Invalid agent session time');
    }
    return AgentSessionDescriptor(
      id: id,
      title: title,
      createdAt: created.toUtc(),
      updatedAt: updated.toUtc(),
    );
  }
}

class AgentSessionUnavailableException implements Exception {
  const AgentSessionUnavailableException(this.sessionId);
  final String sessionId;

  @override
  String toString() => 'Agent session is unavailable: $sessionId';
}

class AgentSessionLease {
  AgentSessionLease._(this._registry, this.session, this._token);

  final AgentSessionRegistry _registry;
  final AgentSessionDescriptor session;
  final String _token;
  var _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _registry._release(session.id, _token);
  }
}

class AgentSessionRegistry {
  AgentSessionRegistry({this.indexFile});

  static const _schemaVersion = 1;
  static final Map<String, Map<String, String>> _leasesByIndex = {};
  final File? indexFile;

  Future<AgentSessionLease> createAndAcquire() async {
    final sessions = await _read();
    final now = DateTime.now().toUtc();
    final session = AgentSessionDescriptor(
      id: _newId(),
      title: 'New session',
      createdAt: now,
      updatedAt: now,
    );
    sessions.add(session);
    await _write(sessions);
    return _acquire(session);
  }

  Future<List<AgentSessionDescriptor>> listAvailable() async {
    final sessions = await _read();
    final leases = _leasesFor(await _index());
    return sessions.where((session) => !leases.containsKey(session.id)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<AgentSessionLease> acquire(String id) async {
    final sessions = await _read();
    final session = sessions.where((session) => session.id == id).firstOrNull;
    if (session == null) throw AgentSessionUnavailableException(id);
    return _acquire(session);
  }

  Future<void> touch(String id, {String? title}) async {
    final sessions = await _read();
    final index = sessions.indexWhere((session) => session.id == id);
    if (index == -1) throw AgentSessionUnavailableException(id);
    sessions[index] = sessions[index].copyWith(
      title: title == null || title.isEmpty ? null : title,
      updatedAt: DateTime.now().toUtc(),
    );
    await _write(sessions);
  }

  Future<void> delete(String id) async {
    final index = await _index();
    if (_leasesFor(index).containsKey(id)) {
      throw AgentSessionUnavailableException(id);
    }
    final sessions = await _read();
    final remaining = sessions.where((session) => session.id != id).toList();
    if (remaining.length == sessions.length) {
      throw AgentSessionUnavailableException(id);
    }
    await _write(remaining);
  }

  Future<AgentSessionLease> _acquire(AgentSessionDescriptor session) async {
    final leases = _leasesFor(await _index());
    if (leases.containsKey(session.id)) {
      throw AgentSessionUnavailableException(session.id);
    }
    final token = _newToken();
    leases[session.id] = token;
    return AgentSessionLease._(this, session, token);
  }

  void _release(String id, String token) {
    for (final leases in _leasesByIndex.values) {
      if (leases[id] == token) {
        leases.remove(id);
        return;
      }
    }
  }

  Future<List<AgentSessionDescriptor>> _read() async {
    final file = await _index();
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != _schemaVersion) {
        throw const FormatException('Unsupported agent session registry');
      }
      final sessions = decoded['sessions'];
      if (sessions is! List) throw const FormatException('Invalid registry');
      return [
        for (final session in sessions)
          AgentSessionDescriptor.fromJson(session),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<AgentSessionDescriptor> sessions) async {
    final file = await _index();
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': _schemaVersion,
          'sessions': sessions.map((session) => session.toJson()).toList(),
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<File> _index() async {
    final override = indexFile;
    if (override != null) return override;
    final data = await appDataDir();
    return File('${data.path}/agent-sessions/index.json');
  }

  Map<String, String> _leasesFor(File index) =>
      _leasesByIndex.putIfAbsent(index.absolute.path, () => {});

  String _newId() => 'session-${_hex(12)}';
  String _newToken() => _hex(16);

  String _hex(int bytes) => List<int>.generate(
    bytes,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
