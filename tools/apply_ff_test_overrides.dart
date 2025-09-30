import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Usage:
///   dart run tools/apply_ff_test_overrides.dart [--root .] [--config tools/ff_test_overrides.yaml] [--dry-run] [--verbose]
///
/// Supported steps (in YAML):
///   - ensure_import: { import, after_import? }
///   - ensure_line_after_match: { match, lines: [...], unique?: true }
///   - ensure_setup_all: { insert_lines_at_start: [...] }
///   - ensure_function: { name, if_missing_append }
///   - replace_all: { pattern, replacement }
///   - replace_first_after_match: { anchor, within_lines: 8, pattern, replacement }
///   - replace_in_test_named: { test_name_regex, pattern, replacement, limit?: "first"|"all"|"N" }
///   - replace_nth_occurrence: { pattern, replacement, nth: [2,4] }

void main(List<String> args) async {
  // Parse command-line arguments.
  final argMap = _parseArgs(args);
  final root = _normalizeDirPath(argMap['--root'] ?? Directory.current.path);
  final configPath = argMap['--config'] ?? 'tools/ff_test_overrides.yaml';
  final dryRun = argMap.containsKey('--dry-run');
  final verbose = argMap.containsKey('--verbose');

  // Load the configuration file.
  final configFile = File(configPath);
  if (!configFile.existsSync()) {
    stderr.writeln('Config not found: $configPath');
    exit(1);
  }
  final config = loadYaml(await configFile.readAsString()) as YamlMap;

  // Get the target file patterns and modification steps from the config.
  final targets = (config['targets'] as YamlList?)?.cast<String>() ?? <String>[];
  final steps = (config['steps'] as YamlList?)?.toList() ?? <dynamic>[];

  if (targets.isEmpty || steps.isEmpty) {
    stderr.writeln('Config must contain non-empty "targets" and "steps".');
    exit(1);
  }

  if (verbose) {
    stdout.writeln('Root: $root');
    stdout.writeln('Config: $configPath');
    stdout.writeln('Targets: ${targets.join(', ')}');
  }

  // Convert glob patterns to regular expressions and find matching files.
  final regexes = targets.map(_globToRegExp).toList(growable: false);
  final files = await _collectMatchingFiles(root: root, regexes: regexes);

  if (files.isEmpty) {
    stdout.writeln('No target files matched. Root: $root');
    if (verbose) {
      await _debugListDartUnderIntegrationTest(root);
    }
    return;
  }

  if (verbose) {
    stdout.writeln('Matched ${files.length} file(s):');
    for (final f in files) {
      stdout.writeln(' - ${f.path}');
    }
  }

  stdout.writeln('Patching ${files.length} file(s)${dryRun ? ' (dry-run)' : ''}');

  // Process each matched file.
  for (final file in files) {
    await _processFile(file, steps, dryRun: dryRun, verbose: verbose);
  }

  stdout.writeln('Done.');
}

/* ------------------------------ File matching ----------------------------- */

/// Recursively finds all Dart files in a directory that match the given regular expressions.
Future<List<File>> _collectMatchingFiles({
  required String root,
  required List<RegExp> regexes,
}) async {
  final result = <File>[];
  final dir = Directory(root);
  if (!await dir.exists()) return result;

  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;

    final rel = _relativePath(root, entity.path).replaceAll('\\', '/'); // normalize
    final matches = regexes.any((re) => re.hasMatch(rel));
    if (matches) result.add(File(entity.path));
  }

  return result;
}

/// Converts a glob pattern to a regular expression.
RegExp _globToRegExp(String pattern) {
  // Normalize path separators in pattern to match our rel paths
  var p = pattern.replaceAll('\\', '/');

  // Escape regex meta chars, then bring back globs
  const meta = r'.^$+{}()=!|,';
  final buf = StringBuffer('^');
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (c == '*') {
      // If next is also *, consume both and translate to .*
      final isDouble = (i + 1 < p.length && p[i + 1] == '*');
      if (isDouble) {
        buf.write('.*');
        i++;
      } else {
        buf.write('[^/]*');
      }
    } else if (c == '?') {
      buf.write('[^/]');
    } else if (c == '/') {
      buf.write('/');
    } else {
      if (meta.contains(c)) buf.write('\\');
      buf.write(c);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

/// Normalizes a directory path by removing any trailing slashes.
String _normalizeDirPath(String p) {
  if (p.endsWith('/') || p.endsWith('\\')) return p.substring(0, p.length - 1);
  return p;
}

/// Calculates the relative path of a file from a root directory.
String _relativePath(String root, String fullPath) {
  final rootNorm = root.replaceAll('\\', '/');
  final fullNorm = fullPath.replaceAll('\\', '/');
  if (fullNorm.startsWith('$rootNorm/')) {
    return fullNorm.substring(rootNorm.length + 1);
  }
  return _stripCommonPrefix(fullNorm, rootNorm);
}

/// Strips the common prefix from two paths.
String _stripCommonPrefix(String aPath, String bPath) {
  final a = aPath.split('/');
  final b = bPath.split('/');
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) i++;
  return a.sublist(i).join('/');
}

/* --------------------------------- Patch --------------------------------- */

/// Applies a series of modifications to a single file.
Future<void> _processFile(File file, List steps, {required bool dryRun, required bool verbose}) async {
  final original = await file.readAsString();
  var src = original;

  // Create a one-time backup of the original file.
  final bak = File('${file.path}.bak');
  if (!dryRun && !bak.existsSync()) {
    await bak.writeAsString(original);
    if (verbose) stdout.writeln('Backup created: ${bak.path}');
  }

  for (final step in steps) {
    if (step is! YamlMap) continue;
    final key = step.keys.first.toString();
    final spec = step[key] as YamlMap;

    if (verbose) stdout.writeln('Applying step: $key');

    switch (key) {
      case 'ensure_import':
        src = _ensureImport(
          src,
          importLine: spec['import'] as String,
          afterImport: spec['after_import'] as String?,
        );
        break;

      case 'ensure_line_after_match':
        src = _ensureLineAfterMatch(
          src,
          matchPattern: spec['match'] as String,
          lines: (spec['lines'] as YamlList).cast<String>().toList(),
          unique: (spec['unique'] ?? true) as bool,
        );
        break;

      case 'ensure_setup_all':
        src = _ensureSetUpAll(
          src,
          insertAtStart: (spec['insert_lines_at_start'] as YamlList?)
              ?.cast<String>()
              .toList() ??
              const <String>[],
        );
        break;

      case 'replace_all':
        src = _replaceAll(
          src,
          pattern: spec['pattern'] as String,
          replacement: spec['replacement'] as String,
        );
        break;

      case 'ensure_function':
        src = _ensureFunction(
          src,
          name: spec['name'] as String,
          ifMissingAppend: (spec['if_missing_append'] as String).trim(),
        );
        break;

      case 'replace_first_after_match':
        src = _replaceFirstAfterMatch(
          src,
          anchorPattern: spec['anchor'] as String,
          withinLines: (spec['within_lines'] ?? 8) as int,
          pattern: spec['pattern'] as String,
          replacement: spec['replacement'] as String,
        );
        break;

      case 'replace_in_test_named':
        src = _replaceInTestNamed(
          src,
          testNameRegex: spec['test_name_regex'] as String,
          pattern: spec['pattern'] as String,
          replacement: spec['replacement'] as String,
          limitSpec: spec['limit']?.toString(),
        );
        break;

      case 'replace_nth_occurrence':
        src = _replaceNthOccurrence(
          src,
          pattern: spec['pattern'] as String,
          replacement: spec['replacement'] as String,
          nthList: (spec['nth'] as YamlList)
              .cast()
              .map((e) => int.parse(e.toString()))
              .toList(),
        );
        break;

      default:
        stderr.writeln('Unknown step: $key (skipped)');
        break;
    }
  }

  // If the file has not been changed, do nothing.
  if (src == original) {
    if (verbose) stdout.writeln('No changes: ${file.path}');
    return;
  }

  // If this is a dry run, print the diff instead of writing the file.
  if (dryRun) {
    stdout.writeln('Would change: ${file.path}');
    _printUnifiedDiff(original, src, file.path);
  } else {
    await file.writeAsString(src);
    stdout.writeln('Patched: ${file.path}');
  }
}

/* -------------------------------- Helpers -------------------------------- */

/// Ensures that a given import statement is present in the file.
String _ensureImport(String src, {required String importLine, String? afterImport}) {
  final importStmt = "import '$importLine';";
  if (src.contains(importStmt)) return src;

  final importRegex = RegExp(
    r'''^import\s+['"]([^'"]+)['"];\s*$''',
    multiLine: true,
  );

  if (afterImport != null) {
    final anchor = "import '$afterImport';";
    final idx = src.indexOf(anchor);
    if (idx >= 0) {
      final insertPos = src.indexOf('\n', idx);
      if (insertPos >= 0) {
        return src.replaceRange(insertPos + 1, insertPos + 1, '$importStmt\n');
      }
    }
  }

  final matches = importRegex.allMatches(src).toList();
  if (matches.isNotEmpty) {
    final last = matches.last;
    final insertPos = last.end;
    return src.replaceRange(insertPos, insertPos, '\n$importStmt');
  }

  return '$importStmt\n$src';
}

/// Ensures that a given line is present after a matched pattern.
String _ensureLineAfterMatch(String src, {required String matchPattern, required List<String> lines, required bool unique}) {
  final re = RegExp(matchPattern, dotAll: true, multiLine: true);
  final match = re.firstMatch(src);
  if (match == null) return src;

  final insertion = lines.where((l) => !unique || !src.contains(l)).join('\n');
  if (insertion.isEmpty) return src;

  final insertPos = match.end;
  return src.replaceRange(insertPos, insertPos, '\n$insertion');
}

/// Ensures that a `setUpAll` block is present and contains the given lines.
String _ensureSetUpAll(String src, {required List<String> insertAtStart}) {
  final setUpRe = RegExp(r'setUpAll\(\s*\(\)\s*async\s*\{\s*', multiLine: true);
  final existing = setUpRe.firstMatch(src);
  if (existing != null) {
    final inject = insertAtStart.where((l) => !src.contains(l)).join('\n');
    if (inject.isEmpty) return src;
    final pos = existing.end;
    return src.replaceRange(pos, pos, '$inject\n');
  }

  final testRe = RegExp(r'testWidgets\(', multiLine: true);
  final m = testRe.firstMatch(src);
  if (m != null) {
    final insert = 'setUpAll(() async {\n${insertAtStart.join('\n')}\n});\n\n';
    return src.replaceRange(m.start, m.start, insert);
  }

  final mainBlockRe = RegExp(r'void\s+main\(\)\s*async\s*\{([\s\S]*?)\}', multiLine: true);
  final mainBlock = mainBlockRe.firstMatch(src);
  if (mainBlock != null) {
    final insertPos = mainBlock.end - 1;
    final insert = '\n\n  setUpAll(() async {\n${insertAtStart.join('\n')}\n  });\n';
    return src.replaceRange(insertPos, insertPos, insert);
  }

  return src;
}

/// Replaces all occurrences of a pattern with a replacement string.
String _replaceAll(String src, {required String pattern, required String replacement}) {
  final re = RegExp(pattern, multiLine: true);
  return src.replaceAll(re, replacement);
}

/// Ensures that a function with the given name exists in the file.
String _ensureFunction(String src, {required String name, required String ifMissingAppend}) {
  final re = RegExp(r'\b' + RegExp.escape(name) + r'\s*\(');
  if (re.hasMatch(src)) return src;

  final needsNL = src.endsWith('\n') ? '' : '\n';
  return '$src$needsNL\n$ifMissingAppend\n';
}

/// Replaces the first occurrence of a pattern after a given anchor.
String _replaceFirstAfterMatch(
    String src, {
      required String anchorPattern,
      required int withinLines,
      required String pattern,
      required String replacement,
    }) {
  final anchorRe = RegExp(anchorPattern, multiLine: true);
  final m = anchorRe.firstMatch(src);
  if (m == null) return src;

  final startIdx = m.end;
  final endIdx = _indexAfterLines(src, startIdx, withinLines);

  final window = src.substring(startIdx, endIdx);
  final targetRe = RegExp(pattern, multiLine: true);
  final hit = targetRe.firstMatch(window);
  if (hit == null) return src;

  final absStart = startIdx + hit.start;
  final absEnd = startIdx + hit.end;
  return src.replaceRange(absStart, absEnd, replacement);
}

/// Finds the index of the character after a given number of lines.
int _indexAfterLines(String s, int from, int lines) {
  var count = 0;
  for (var i = from; i < s.length; i++) {
    if (s.codeUnitAt(i) == 10) { // '\n'
      count++;
      if (count >= lines) return i + 1;
    }
  }
  return s.length;
}

/// Replaces occurrences of a pattern within a `testWidgets` block with a given name.
String _replaceInTestNamed(
    String src, {
      required String testNameRegex,
      required String pattern,
      required String replacement,
      String? limitSpec,
    }) {
  final nameRe = RegExp(testNameRegex);
  final testHeaderRe = RegExp(
    r"testWidgets\s*\(\s*'([^']+)'\s*,\s*\(WidgetTester\s+tester\)\s*async\s*\{\s*",
    multiLine: true,
  );
  final matches = testHeaderRe.allMatches(src).toList();
  if (matches.isEmpty) return src;

  var out = src;

  for (final m in matches) {
    final name = m.group(1) ?? '';
    if (!nameRe.hasMatch(name)) continue;

    final bodyStart = m.end;
    final bodyEnd = _findMatchingBrace(out, bodyStart - 1);
    if (bodyEnd == -1) continue;

    final body = out.substring(bodyStart, bodyEnd);
    final newBody = _regexReplaceWithLimit(body, pattern, replacement, limitSpec);
    if (newBody == body) continue;

    out = out.replaceRange(bodyStart, bodyEnd, newBody);
  }

  return out;
}

/// Finds the index of the matching closing brace for a given opening brace.
int _findMatchingBrace(String s, int openBraceIndex) {
  var i = openBraceIndex;
  while (i >= 0 && s[i] != '{') i--;
  if (i < 0) return -1;

  var depth = 0;
  for (var j = i; j < s.length; j++) {
    final ch = s[j];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return j;
    }
  }
  return -1;
}

/// Replaces occurrences of a pattern with a replacement string, with an optional limit.
String _regexReplaceWithLimit(
    String input,
    String pattern,
    String replacement,
    String? limitSpec,
    ) {
  final re = RegExp(pattern, multiLine: true);
  if (limitSpec == null || limitSpec == 'all') {
    return input.replaceAll(re, replacement);
  }
  if (limitSpec == 'first') {
    final m = re.firstMatch(input);
    if (m == null) return input;
    return input.replaceRange(m.start, m.end, replacement);
  }
  final count = int.tryParse(limitSpec);
  if (count == null || count <= 0) return input;

  var remaining = count;
  return input.replaceAllMapped(re, (m) {
    if (remaining > 0) {
      remaining--;
      return replacement;
    }
    return m[0]!;
  });
}

/// Replaces the nth occurrence of a pattern with a replacement string.
String _replaceNthOccurrence(
    String src, {
      required String pattern,
      required String replacement,
      required List<int> nthList,
    }) {
  final re = RegExp(pattern, multiLine: true);
  final hits = re.allMatches(src).toList();
  if (hits.isEmpty) return src;

  final toChange = nthList.toSet();
  final buf = StringBuffer();
  var last = 0;

  for (var i = 0; i < hits.length; i++) {
    final h = hits[i];
    if (toChange.contains(i + 1)) { // 1-based
      buf..write(src.substring(last, h.start))..write(replacement);
      last = h.end;
    }
  }
  buf.write(src.substring(last));
  return buf.toString();
}

/// Prints a unified diff of the changes to a file.
void _printUnifiedDiff(String before, String after, String path) {
  final beforeLines = const LineSplitter().convert(before);
  final afterLines = const LineSplitter().convert(after);
  stdout.writeln('--- $path');
  stdout.writeln('+++ $path');
  final max = beforeLines.length > afterLines.length ? beforeLines.length : afterLines.length;
  for (var i = 0; i < max; i++) {
    final a = i < beforeLines.length ? beforeLines[i] : '';
    final b = i < afterLines.length ? afterLines[i] : '';
    if (a == b) continue;
    if (a.isNotEmpty) stdout.writeln('- $a');
    if (b.isNotEmpty) stdout.writeln('+ $b');
  }
}

/// Prints a list of all Dart files in the `integration_test` directory for debugging.
Future<void> _debugListDartUnderIntegrationTest(String root) async {
  stdout.writeln('Debug: scanning $root/integration_test for .dart files');
  final dir = Directory('$root/integration_test');
  if (!await dir.exists()) {
    stdout.writeln('No integration_test folder at $root');
    return;
  }
  final entries = await dir.list(recursive: true).where((e) => e.path.endsWith('.dart')).toList();
  if (entries.isEmpty) {
    stdout.writeln('No .dart files under $root/integration_test');
    return;
  }
  for (final e in entries) {
    stdout.writeln(' - ${e.path}');
  }
}

/// Parses command-line arguments into a map.
Map<String, String> _parseArgs(List<String> args) {
  final map = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--dry-run' || a == '--verbose') {
      map[a] = 'true';
    } else if (a.startsWith('--')) {
      final next = (i + 1) < args.length ? args[i + 1] : null;
      if (next != null && !next.startsWith('--')) {
        map[a] = next;
        i++;
      } else {
        map[a] = 'true';
      }
    }
  }
  return map;
}
