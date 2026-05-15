import '../models/known_hosts_store.dart';
import '../models/openssh_known_hosts.dart';
import '../utils/ssh_fingerprint.dart';

/// Resolves trusted keys from `~/.ssterm/known_hosts.json` and `~/.ssh/known_hosts`.
class TrustedHostKeys {
  /// First matching entry for this host and key type (ssterm store wins).
  static Future<KnownHostEntry?> lookup(
    String hostname,
    int port,
    String keyType,
  ) async {
    final ssterm = await KnownHostsStore.lookup(hostname, port);
    if (ssterm != null && ssterm.keyType == keyType) return ssterm;

    final openssh = await OpenSshKnownHosts.lookup(hostname, port, keyType);
    if (openssh.isNotEmpty) return openssh.first;
    return null;
  }

  /// All entries for this host/key type from both stores (deduped by fingerprint).
  static Future<List<KnownHostEntry>> entriesForKeyType(
    String hostname,
    int port,
    String keyType,
  ) async {
    final seen = <String>{};
    final out = <KnownHostEntry>[];

    void add(KnownHostEntry e) {
      final key = '${e.keyType}:${normalizeFingerprint(e.fingerprint)}';
      if (seen.add(key)) out.add(e);
    }

    final ssterm = await KnownHostsStore.lookup(hostname, port);
    if (ssterm != null && ssterm.keyType == keyType) add(ssterm);

    for (final e in await OpenSshKnownHosts.lookup(hostname, port, keyType)) {
      add(e);
    }
    return out;
  }

  static Future<bool> isTrusted(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = await entriesForKeyType(hostname, port, keyType);
    return entries.any((e) => fingerprintsEqual(e.fingerprint, fingerprint));
  }

  static Future<KnownHostEntry?> conflictingEntry(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = await entriesForKeyType(hostname, port, keyType);
    for (final e in entries) {
      if (!fingerprintsEqual(e.fingerprint, fingerprint)) return e;
    }
    return null;
  }

  static Future<void> trust(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    await KnownHostsStore.trust(hostname, port, keyType, fingerprint);
  }
}
