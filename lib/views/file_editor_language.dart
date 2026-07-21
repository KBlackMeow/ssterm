import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/all.dart' show allLanguages;

/// Maps a file extension to the `package:highlight` language-name key
/// used in [allLanguages]. Extensions not listed here fall back to
/// plain, uncolored text in the editor — never an error.
const _kExtensionToHighlightName = <String, String>{
  'dart': 'dart',
  'py': 'python',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'md': 'markdown',
  'markdown': 'markdown',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'css': 'css',
  'sql': 'sql',
  'toml': 'ini',
  'conf': 'ini',
  'ini': 'ini',
  'cfg': 'ini',
  'go': 'go',
  'rs': 'rust',
  'java': 'java',
  'c': 'cpp',
  'h': 'cpp',
  'cpp': 'cpp',
  'cc': 'cpp',
  'hpp': 'cpp',
};

/// Returns the `package:highlight` [Mode] for [path]'s extension
/// (case-insensitive), or `null` when the extension is missing or not
/// recognized — the editor then shows plain, uncolored text.
///
/// Matches on the LAST `.` in the path, so a dotfile with no further
/// extension (e.g. `.bashrc`) correctly returns `null` rather than
/// treating "bashrc" as an extension.
Mode? codeEditorLanguageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  final name = _kExtensionToHighlightName[ext];
  if (name == null) return null;
  return allLanguages[name];
}
