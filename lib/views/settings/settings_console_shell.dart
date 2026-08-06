import 'package:flutter/material.dart';

const _consoleBackground = Color(0xFF0B0F16);
const _consoleRail = Color(0xFF0F1621);
const _consoleBorder = Color(0xFF263443);
const _consoleSignal = Color(0xFF56C8FF);
const _consoleMuted = Color(0xFF8090A5);
const _consoleForeground = Color(0xFFE4EDF8);

class SettingsConsoleDestination {
  const SettingsConsoleDestination({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class SettingsConsoleShell extends StatelessWidget {
  const SettingsConsoleShell({
    super.key,
    required this.controller,
    required this.destinations,
    required this.tabBar,
    required this.tabViews,
    this.header,
  });

  final TabController controller;
  final List<SettingsConsoleDestination> destinations;
  final Widget tabBar;
  final List<Widget> tabViews;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            children: [
              tabBar,
              Expanded(child: _content()),
            ],
          );
        }
        return Row(
          children: [
            _SettingsConsoleRail(
              controller: controller,
              destinations: destinations,
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: _consoleBorder,
            ),
            Expanded(child: _content()),
          ],
        );
      },
    );
  }

  Widget _content() => Column(
    children: [
      ?header,
      Expanded(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) =>
              IndexedStack(index: controller.index, children: tabViews),
        ),
      ),
    ],
  );
}

class _SettingsConsoleRail extends StatelessWidget {
  const _SettingsConsoleRail({
    required this.controller,
    required this.destinations,
  });

  final TabController controller;
  final List<SettingsConsoleDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('settings-console-rail'),
      width: 192,
      child: Material(
        color: _consoleRail,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) => ListView(
            padding: EdgeInsets.zero,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 20, 18, 16),
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: _consoleSignal),
                    SizedBox(width: 8),
                    Text(
                      'SETTINGS',
                      style: TextStyle(
                        color: _consoleForeground,
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _consoleBorder),
              const SizedBox(height: 10),
              for (var index = 0; index < destinations.length; index++)
                _ConsoleRailItem(
                  destination: destinations[index],
                  selected: controller.index == index,
                  onTap: () => controller.animateTo(index),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsoleRailItem extends StatelessWidget {
  const _ConsoleRailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final SettingsConsoleDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _consoleForeground : _consoleMuted;
    return InkWell(
      onTap: onTap,
      hoverColor: Colors.transparent,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      focusColor: Colors.transparent,
      child: Container(
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? _consoleSignal.withValues(alpha: .12) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(
              color: selected ? _consoleSignal : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(destination.icon, size: 17, color: color),
            const SizedBox(width: 10),
            Text(
              destination.label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsConsoleHeader extends StatelessWidget {
  const SettingsConsoleHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _consoleBackground,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _consoleForeground,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -.3,
            ),
          ),
        ],
      ),
    );
  }
}
