import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/skill.dart';
import 'package:ssterm/services/bundled_skills.dart';
import 'package:ssterm/services/skill_service.dart';

void main() {
  // Asset-backed skills (assets/skills/…) require Flutter's rootBundle,
  // which only works under a widget test binding.  We initialise once
  // here so every test in this file can call `SkillService.init()` if
  // needed, but the cases below mostly exercise filters + user-dir
  // scanning that don't touch the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkillService.filterEnabled', () {
    setUp(() async {
      // Each test gets a clean registry + service state so assertions
      // about catalogue size aren't poisoned by sibling tests.
      BundledSkillRegistry.debugReset();
      SkillService.debugUserSkillsDirOverride = null;
      // Stub two synthetic bundled skills so we don't depend on the
      // real asset bundle in a unit-test context.
      BundledSkillRegistry.register(BundledSkillDef(
        id: 'alpha',
        description: 'first synthetic skill',
        buildBody: () async => 'alpha-body',
      ));
      BundledSkillRegistry.register(BundledSkillDef(
        id: 'beta',
        description: 'second synthetic skill',
        buildBody: () async => 'beta-body',
      ));
      await SkillService.init();
    });

    test('null whitelist returns every installed skill', () {
      final out = SkillService.filterEnabled(null);
      final ids = out.map((s) => s.id).toSet();
      expect(ids.containsAll({'alpha', 'beta'}), isTrue);
    });

    test('empty whitelist disables everything', () {
      final out = SkillService.filterEnabled(<String>{});
      expect(out, isEmpty);
    });

    test('explicit whitelist returns the matching subset only', () {
      final out = SkillService.filterEnabled({'alpha'});
      expect(out.map((s) => s.id), equals(['alpha']));
    });

    test('unknown ids in the whitelist are silently ignored', () {
      // Defensive: prevents a stale config (skill that was uninstalled
      // since last save) from crashing the agent loop.
      final out = SkillService.filterEnabled({'alpha', 'ghost'});
      expect(out.map((s) => s.id), equals(['alpha']));
    });

    test('preserves stable id-sorted order', () {
      // Used by buildPromptCatalogue — reordering across turns would
      // bust Anthropic prefix caching since the system-reminder body
      // would change byte-for-byte.
      final out = SkillService.filterEnabled({'beta', 'alpha'});
      expect(out.map((s) => s.id), equals(['alpha', 'beta']));
    });
  });

  group('SkillService user-dir scan', () {
    late Directory tempRoot;

    setUp(() async {
      BundledSkillRegistry.debugReset();
      tempRoot = await Directory.systemTemp.createTemp('ssterm-skill-test-');
      SkillService.debugUserSkillsDirOverride = tempRoot.path;
    });

    tearDown(() async {
      SkillService.debugUserSkillsDirOverride = null;
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('loads a well-formed user SKILL.md', () async {
      final dir = Directory('${tempRoot.path}/sample-user-skill')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync('''
---
name: sample-user-skill
description: A user-installed sample skill for testing.
when_to_use: never in production, this is a fixture.
---

# Sample user skill body
This is the body the agent would see when it loads me.
''');

      await SkillService.init();

      final hit = SkillService.skills
          .where((s) => s.id == 'sample-user-skill')
          .toList();
      expect(hit, hasLength(1));
      expect(hit.first.source, equals(SkillSource.user));
      expect(hit.first.description,
          equals('A user-installed sample skill for testing.'));
      expect(hit.first.whenToUse,
          equals('never in production, this is a fixture.'));

      final body = await SkillService.loadBody('sample-user-skill');
      expect(body, contains('Sample user skill body'));
    });

    test('skips a user dir with missing SKILL.md', () async {
      Directory('${tempRoot.path}/empty-skill').createSync(recursive: true);
      await SkillService.init();
      expect(
        SkillService.skills.where((s) => s.id == 'empty-skill'),
        isEmpty,
      );
    });

    test('skips a user SKILL.md with broken frontmatter', () async {
      final dir = Directory('${tempRoot.path}/broken-skill')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync(
        'no frontmatter at all, just markdown — should be skipped\n',
      );

      await SkillService.init();
      expect(
        SkillService.skills.where((s) => s.id == 'broken-skill'),
        isEmpty,
      );
    });

    test('user dir overlay does not crash when the root is absent', () async {
      // Point at a non-existent path; init should still complete and
      // expose any bundled / asset skills it discovered.
      SkillService.debugUserSkillsDirOverride =
          '${tempRoot.path}/definitely-not-here';
      await tempRoot.delete(recursive: true);
      await SkillService.init();
      // No throw === pass.
      expect(SkillService.isInitialized, isTrue);
    });

    test('bundled skill of the same id wins over user dir (shadowing)',
        () async {
      BundledSkillRegistry.register(BundledSkillDef(
        id: 'shadowed',
        description: 'bundled version',
        buildBody: () async => 'bundled-body',
      ));
      final dir = Directory('${tempRoot.path}/shadowed')
        ..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync('''
---
name: shadowed
description: user version that should NOT win.
---
user-body
''');

      await SkillService.init();

      final hits = SkillService.skills.where((s) => s.id == 'shadowed').toList();
      expect(hits, hasLength(1));
      expect(hits.first.source, equals(SkillSource.bundled));
      expect(hits.first.description, equals('bundled version'));
    });
  });
}
