import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/models/terminal_settings.dart';
import 'package:ssterm/widgets/frosted_glass.dart';
import 'package:ssterm/views/settings/settings_console_shell.dart';
import 'package:ssterm/views/settings/settings_sheet.dart';

void main() {
  testWidgets('desktop shell exposes console destinations', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const _Harness(width: 1100));

    expect(find.byKey(const Key('settings-console-rail')), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.byKey(const Key('settings-tab-strip')), findsNothing);
    expect(find.text('SYSTEM / READY'), findsNothing);
    expect(find.text('READY'), findsNothing);
  });

  testWidgets('rail selection updates the shared tab controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const _Harness(width: 1100));

    await tester.tap(find.text('Agent'));
    await tester.pumpAndSettle();

    expect(find.text('Agent content'), findsOneWidget);
  });

  testWidgets('rail selection replaces content without a TabBarView', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const _Harness(width: 1100));

    expect(find.byType(TabBarView), findsNothing);
    await tester.tap(find.text('Agent'));
    await tester.pump();
    expect(find.text('Agent content'), findsOneWidget);
  });

  testWidgets('narrow shell keeps the tab strip', (tester) async {
    await tester.pumpWidget(const _Harness(width: 700));

    expect(find.byKey(const Key('settings-console-rail')), findsNothing);
    expect(find.byKey(const Key('settings-tab-strip')), findsOneWidget);
  });

  testWidgets('settings page uses the desktop rail', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          settings: TerminalSettings(),
          onChanged: (_) {},
          agent: AgentConfig(),
        ),
      ),
    );

    expect(find.byKey(const Key('settings-console-rail')), findsOneWidget);
  });

  testWidgets('skills and MCP are independent settings destinations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          settings: TerminalSettings(),
          onChanged: (_) {},
          agent: AgentConfig(),
        ),
      ),
    );

    expect(find.text('Skills'), findsOneWidget);
    expect(find.text('MCP'), findsOneWidget);
  });

  testWidgets('appearance starts with a compact terminal preview panel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          settings: TerminalSettings(),
          onChanged: (_) {},
          agent: AgentConfig(),
        ),
      ),
    );

    expect(
      find.byKey(const Key('settings-appearance-preview')),
      findsOneWidget,
    );
    expect(find.text('TERMINAL THEME'), findsOneWidget);
  });

  testWidgets('agent MCP section uses the console surface', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          settings: TerminalSettings(),
          onChanged: (_) {},
          agent: AgentConfig(),
        ),
      ),
    );

    await tester.tap(find.text('MCP'));
    await tester.pump();

    expect(find.byKey(const Key('settings-mcp-section')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-mcp-section')),
        matching: find.byType(FrostedGlassSurface),
      ),
      findsNothing,
    );
  });
}

class _Harness extends StatefulWidget {
  const _Harness({required this.width});

  final double width;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: widget.width,
        height: 600,
        child: SettingsConsoleShell(
          controller: _controller,
          destinations: const [
            SettingsConsoleDestination(
              label: 'Appearance',
              icon: Icons.palette_outlined,
            ),
            SettingsConsoleDestination(
              label: 'Agent',
              icon: Icons.smart_toy_outlined,
            ),
          ],
          tabBar: TabBar(
            key: const Key('settings-tab-strip'),
            controller: _controller,
            tabs: const [
              Tab(text: 'Appearance'),
              Tab(text: 'Agent'),
            ],
          ),
          tabViews: const [Text('Appearance content'), Text('Agent content')],
        ),
      ),
    ),
  );
}
