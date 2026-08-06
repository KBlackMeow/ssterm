# Settings Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give desktop Settings a dense terminal-console presentation while retaining every setting and its current behaviour.

**Architecture:** `SettingsPage` remains the state owner and keeps the current `TabController` and tab bodies. A new responsive shell renders a desktop rail driven by that controller; at narrow widths it renders the existing horizontal `TabBar`. Existing settings groups share new console surface tokens.

**Tech Stack:** Flutter, Material widgets, existing `FrostedGlassSurface`, `flutter_test`.

## Global Constraints

- Do not change `TerminalSettings`, `AgentConfig`, persistence services, or callbacks.
- Keep all eight categories reachable through the shared `TabController`.
- Desktop is primary; widths below 820px retain horizontal navigation.
- Use cyan-blue only for focused/active signal states and reuse Liquid Glass sparingly.

---

## File Structure

- Create `lib/views/settings/settings_console_shell.dart`: responsive shell, rail, destination model.
- Modify `lib/views/settings/settings_sheet.dart`: shell wiring, console tokens, compact Appearance preview.
- Modify `lib/views/settings/settings_sheet_agent.dart`, `settings_sheet_commands.dart`, `settings_sheet_safety.dart`: shared group surfaces.
- Create `test/views/settings_console_shell_test.dart`: responsive layout and navigation tests.

### Task 1: Add a tested responsive navigation shell

**Files:**
- Create: `lib/views/settings/settings_console_shell.dart`
- Create: `test/views/settings_console_shell_test.dart`

**Interfaces:**
- Produces `SettingsConsoleDestination({required String label, required IconData icon})`.
- Produces `SettingsConsoleShell({required TabController controller, required List<SettingsConsoleDestination> destinations, required Widget tabBar, required Widget tabViews})`.

- [ ] **Step 1: Write failing desktop test**

```dart
testWidgets('desktop shell exposes console destinations', (tester) async {
  await tester.pumpWidget(_harness(width: 1100));
  expect(find.byKey(const Key('settings-console-rail')), findsOneWidget);
  expect(find.text('Appearance'), findsOneWidget);
  expect(find.text('Agent'), findsOneWidget);
  expect(find.byKey(const Key('settings-tab-strip')), findsNothing);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/views/settings_console_shell_test.dart --plain-name "desktop shell exposes console destinations"`

Expected: FAIL because the shell does not exist.

- [ ] **Step 3: Implement minimum shell**

```dart
class SettingsConsoleDestination {
  const SettingsConsoleDestination({required this.label, required this.icon});
  final String label;
  final IconData icon;
}

class SettingsConsoleShell extends StatelessWidget {
  const SettingsConsoleShell({super.key, required this.controller,
    required this.destinations, required this.tabBar, required this.tabViews});
  final TabController controller;
  final List<SettingsConsoleDestination> destinations;
  final Widget tabBar;
  final Widget tabViews;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, box) => box.maxWidth >= 820
      ? Row(children: [_SettingsConsoleRail(controller: controller,
          destinations: destinations), const VerticalDivider(width: 1),
          Expanded(child: tabViews)])
      : Column(children: [tabBar, Expanded(child: tabViews)]),
  );
}
```

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/views/settings_console_shell_test.dart --plain-name "desktop shell exposes console destinations"`

Expected: PASS.

- [ ] **Step 5: Add failing selection and narrow tests**

```dart
testWidgets('rail selection updates the controller', (tester) async {
  final controller = TabController(length: 2, vsync: const TestVSync());
  addTearDown(controller.dispose);
  await tester.pumpWidget(_harness(width: 1100, controller: controller));
  await tester.tap(find.text('Agent'));
  await tester.pumpAndSettle();
  expect(controller.index, 1);
});

testWidgets('narrow shell keeps the tab strip', (tester) async {
  await tester.pumpWidget(_harness(width: 700));
  expect(find.byKey(const Key('settings-console-rail')), findsNothing);
  expect(find.byKey(const Key('settings-tab-strip')), findsOneWidget);
});
```

- [ ] **Step 6: Implement selection and fallback**

```dart
onTap: () => controller.animateTo(index),
// Give the rail Key('settings-console-rail') and the supplied TabBar
// Key('settings-tab-strip'). Use ListenableBuilder(controller: controller)
// so active rail state follows swipe and click selection.
```

- [ ] **Step 7: Run and commit**

Run: `flutter test test/views/settings_console_shell_test.dart`

Expected: PASS.

```bash
git add lib/views/settings/settings_console_shell.dart test/views/settings_console_shell_test.dart
git commit -m "feat: add responsive settings console shell"
```

### Task 2: Wire the shell into the existing settings page

**Files:**
- Modify: `lib/views/settings/settings_sheet.dart:1-241`
- Test: `test/views/settings_console_shell_test.dart`

**Interfaces:**
- Consumes `SettingsConsoleShell` and `SettingsConsoleDestination` from Task 1.
- Produces desktop navigation that only drives the pre-existing `_tabController`.

- [ ] **Step 1: Write failing page-integration test**

```dart
testWidgets('settings page rail opens Agent', (tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: SettingsPage(
    settings: TerminalSettings(), onChanged: (_) {}, agent: AgentConfig(),
  )));
  await tester.tap(find.text('Agent'));
  await tester.pumpAndSettle();
  expect(find.text('Default Provider'), findsOneWidget);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/views/settings_console_shell_test.dart --plain-name "settings page rail opens Agent"`

Expected: FAIL because desktop `SettingsPage` has no rail.

- [ ] **Step 3: Implement controller-backed destinations**

```dart
final destinations = const [
  SettingsConsoleDestination(label: 'Appearance', icon: Icons.palette_outlined),
  SettingsConsoleDestination(label: 'Font', icon: Icons.text_fields),
  SettingsConsoleDestination(label: 'Cursor', icon: Icons.edit_outlined),
  SettingsConsoleDestination(label: 'SSH', icon: Icons.dns_outlined),
  SettingsConsoleDestination(label: 'Commands', icon: Icons.terminal_outlined),
  SettingsConsoleDestination(label: 'Agent', icon: Icons.smart_toy_outlined),
  SettingsConsoleDestination(label: 'Safety', icon: Icons.shield_outlined),
  SettingsConsoleDestination(label: 'About', icon: Icons.info_outline),
];
// Pass current TabBar and TabBarView unchanged into SettingsConsoleShell.
```

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/views/settings_console_shell_test.dart`

Expected: PASS.

```bash
git add lib/views/settings/settings_sheet.dart test/views/settings_console_shell_test.dart
git commit -m "feat: use console navigation for desktop settings"
```

### Task 3: Restyle settings groups and compact Appearance

**Files:**
- Modify: `lib/views/settings/settings_sheet.dart:31-900`
- Modify: `lib/views/settings/settings_sheet_agent.dart`
- Modify: `lib/views/settings/settings_sheet_commands.dart`
- Modify: `lib/views/settings/settings_sheet_safety.dart`
- Test: `test/views/settings_console_shell_test.dart`

**Interfaces:**
- Produces `_consoleSurface({required Widget child})` and a keyed Appearance preview.
- Preserves all existing settings-widget callbacks.

- [ ] **Step 1: Write failing structural test**

```dart
testWidgets('appearance starts with compact preview panel', (tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: SettingsPage(
    settings: TerminalSettings(), onChanged: (_) {}, agent: AgentConfig(),
  )));
  expect(find.byKey(const Key('settings-appearance-preview')), findsOneWidget);
  expect(find.text('TERMINAL THEME'), findsOneWidget);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/views/settings_console_shell_test.dart --plain-name "appearance starts with compact preview panel"`

Expected: FAIL because preview is currently global and header reads `Theme`.

- [ ] **Step 3: Add reusable console styling and compact preview**

```dart
const _kConsoleBg = Color(0xFF0B0F16);
const _kConsoleSurface = Color(0xD9121823);
const _kSignal = Color(0xFF56C8FF);

Widget _consoleSurface({required Widget child}) => FrostedGlassSurface(
  frosted: false, fillColor: _kConsoleSurface, borderRadius: 10, child: child,
);

KeyedSubtree(key: const Key('settings-appearance-preview'), child:
  _consoleSurface(child: Padding(padding: const EdgeInsets.all(10),
    child: TerminalPreview(settings: _s))),
)
```

- [ ] **Step 4: Apply shared group surfaces**

Replace each setting-group `Container` using `_kSurface` and `_kDivider` in
the settings sheet part files with `_consoleSurface`; retain its exact child,
padding, handlers, and conditions. Update `_sectionTitle` to render uppercase
10px `JetBrainsMono` labels with a small cyan marker.

- [ ] **Step 5: Verify GREEN and commit**

Run: `flutter test test/views/settings_console_shell_test.dart && flutter analyze`

Expected: widget tests PASS and `flutter analyze` reports no issues.

```bash
git add lib/views/settings/settings_sheet.dart lib/views/settings/settings_sheet_agent.dart lib/views/settings/settings_sheet_commands.dart lib/views/settings/settings_sheet_safety.dart test/views/settings_console_shell_test.dart
git commit -m "feat: style settings as a terminal console"
```

### Task 4: Verify the completed change

**Files:**
- Verify: every file modified by Tasks 1-3.

- [ ] **Step 1: Format source**

Run: `dart format lib/views/settings/settings_console_shell.dart lib/views/settings/settings_sheet.dart lib/views/settings/settings_sheet_agent.dart lib/views/settings/settings_sheet_commands.dart lib/views/settings/settings_sheet_safety.dart test/views/settings_console_shell_test.dart`

Expected: exit code 0.

- [ ] **Step 2: Run full regression checks**

Run: `flutter test && flutter analyze`

Expected: all tests PASS and analyzer outputs `No issues found!`.

- [ ] **Step 3: Manually validate layouts**

Run: `flutter run -d macos`

At desktop width, select Appearance and Agent from the rail and confirm labels,
preview, and Agent form fit without clipping. Resize below 820px and confirm
the horizontal tabs select the same pages.

## Plan Self-Review

- Coverage: Tasks 1-2 implement responsive desktop rail and all category access; Task 3 implements console styling, compact preview, and unchanged setting actions; Task 4 verifies desktop and narrow behaviour.
- Placeholder scan: no TBD/TODO or unspecified handler changes.
- Type consistency: Task 1 defines the only shell/destination types used by Tasks 2-4.

