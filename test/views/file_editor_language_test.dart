import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:ssterm/views/file_editor_language.dart';

void main() {
  group('codeEditorLanguageForPath', () {
    test('recognizes common extensions', () {
      final cases = <String, String>{
        '/tmp/x.dart': 'dart',
        '/tmp/x.py': 'python',
        '/tmp/x.js': 'javascript',
        '/tmp/x.mjs': 'javascript',
        '/tmp/x.cjs': 'javascript',
        '/tmp/x.ts': 'typescript',
        '/tmp/x.json': 'json',
        '/tmp/x.yaml': 'yaml',
        '/tmp/x.yml': 'yaml',
        '/tmp/x.sh': 'bash',
        '/tmp/x.bash': 'bash',
        '/tmp/x.zsh': 'bash',
        '/tmp/x.md': 'markdown',
        '/tmp/x.markdown': 'markdown',
        '/tmp/x.html': 'xml',
        '/tmp/x.htm': 'xml',
        '/tmp/x.xml': 'xml',
        '/tmp/x.css': 'css',
        '/tmp/x.sql': 'sql',
        '/tmp/x.toml': 'ini',
        '/tmp/x.conf': 'ini',
        '/tmp/x.ini': 'ini',
        '/tmp/x.cfg': 'ini',
        '/tmp/x.go': 'go',
        '/tmp/x.rs': 'rust',
        '/tmp/x.java': 'java',
        '/tmp/x.c': 'cpp',
        '/tmp/x.h': 'cpp',
        '/tmp/x.cpp': 'cpp',
        '/tmp/x.cc': 'cpp',
        '/tmp/x.hpp': 'cpp',
      };
      for (final entry in cases.entries) {
        final mode = codeEditorLanguageForPath(entry.key);
        expect(mode, isNotNull, reason: '${entry.key} should resolve');
        expect(
          identical(mode, allLanguages[entry.value]),
          isTrue,
          reason:
              '${entry.key} should resolve to the SAME Mode instance as '
              "allLanguages['${entry.value}'], not just an equal-looking one",
        );
      }
    });

    test('is case-insensitive', () {
      final lower = codeEditorLanguageForPath('/tmp/x.py');
      final upper = codeEditorLanguageForPath('/tmp/X.PY');
      expect(identical(lower, upper), isTrue);
    });

    test('returns null for an unrecognized extension', () {
      expect(codeEditorLanguageForPath('/tmp/x.foobar'), isNull);
    });

    test('returns null for a path with no extension', () {
      expect(codeEditorLanguageForPath('/tmp/Makefile'), isNull);
    });

    test('returns null for a path ending in a bare dot', () {
      expect(codeEditorLanguageForPath('/tmp/x.'), isNull);
    });

    test('returns null for a dotfile with no further extension '
        '(e.g. ".bashrc")', () {
      // The LAST dot is what matters — ".bashrc" has its only dot at
      // index 0, so `substring(dot + 1)` is "bashrc", which isn't a
      // key in the extension map (only "bash"/"sh"/"zsh" are). This
      // pins that a leading dotfile name isn't accidentally treated
      // as its own "extension".
      expect(codeEditorLanguageForPath('/tmp/.bashrc'), isNull);
    });
  });
}
