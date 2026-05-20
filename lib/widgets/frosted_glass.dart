import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Shared frosted-glass styling for SFTP panel and popup menus.
abstract final class FrostedGlassStyle {
  static const panelRadius = 12.0;
  static const menuRadius = 8.0;
  static const blurSigma = 18.0;

  static const panelFillFrosted = Color(0x991C1C1C);
  static const panelFillSolid = Color(0xD91C1C1C);
  static const menuFillFrosted = Color(0x992B2B2B);
  static const menuFillSolid = Color(0xFF2B2B2B);
  static const border = Color(0x1FFFFFFF);
  static const divider = Color(0xFF3A3A3A);
}

/// Rounded surface with optional [BackdropFilter] blur.
class FrostedGlassSurface extends StatelessWidget {
  const FrostedGlassSurface({
    super.key,
    required this.frosted,
    required this.child,
    this.borderRadius = FrostedGlassStyle.menuRadius,
    this.fillColor,
    this.blur,
  });

  final bool frosted;
  final Widget child;
  final double borderRadius;
  final Color? fillColor;

  /// Backdrop blur; defaults to [frosted]. Disable for live-updating overlays
  /// (e.g. transfer panel over SFTP) to avoid compositor/layout issues.
  final bool? blur;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final fill = fillColor ??
        (frosted
            ? FrostedGlassStyle.menuFillFrosted
            : FrostedGlassStyle.menuFillSolid);

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: FrostedGlassStyle.border),
        borderRadius: radius,
      ),
      child: child,
    );

    final useBlur = blur ?? frosted;

    return ClipRRect(
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: useBlur
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: FrostedGlassStyle.blurSigma,
                sigmaY: FrostedGlassStyle.blurSigma,
              ),
              child: decorated,
            )
          : decorated,
    );
  }
}

/// [showMenu] wrapper: frosted blur when [frostedGlass] is true.
Future<T?> showFrostedMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  bool frostedGlass = true,
  BoxConstraints? constraints,
  ShapeBorder? shape,
}) {
  final menuShape = shape ??
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FrostedGlassStyle.menuRadius),
        side: frostedGlass
            ? BorderSide.none
            : const BorderSide(color: FrostedGlassStyle.divider),
      );

  if (!frostedGlass) {
    return showMenu<T>(
      context: context,
      position: position,
      constraints: constraints,
      color: FrostedGlassStyle.menuFillSolid,
      shape: menuShape,
      items: items,
    );
  }

  final shellHeight = _frostedMenuShellHeight(items, constraints);
  final fixedHeight = constraints != null &&
      constraints.hasBoundedHeight &&
      constraints.minHeight == constraints.maxHeight;

  return showMenu<T>(
    context: context,
    position: position,
    constraints: constraints,
    color: Colors.transparent,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    clipBehavior: Clip.antiAlias,
    shape: menuShape,
    items: [
      PopupMenuItem<T>(
        enabled: false,
        padding: EdgeInsets.zero,
        height: shellHeight,
        child: FrostedGlassSurface(
          frosted: true,
          borderRadius: FrostedGlassStyle.menuRadius,
          fillColor: FrostedGlassStyle.menuFillFrosted,
          child: _FrostedMenuList<T>(
            entries: items,
            maxHeight: fixedHeight ? null : constraints?.maxHeight,
            onSelected: (value) => Navigator.of(context).pop<T>(value),
          ),
        ),
      ),
    ],
  );
}

/// Height for the single [showMenu] shell item so the route matches real content.
double _frostedMenuShellHeight<T>(
  List<PopupMenuEntry<T>> entries,
  BoxConstraints? constraints,
) {
  var total = 0.0;
  for (final entry in entries) {
    if (entry is PopupMenuDivider) {
      total += entry.height;
    } else if (entry is PopupMenuItem<T>) {
      total += entry.height;
    }
  }

  if (constraints != null && constraints.hasBoundedHeight) {
    final maxH = constraints.maxHeight;
    if (constraints.minHeight == maxH && maxH.isFinite) {
      return maxH;
    }
    if (maxH.isFinite && total > maxH) {
      return maxH;
    }
  }

  return total > 0 ? total : kMinInteractiveDimension;
}

double _entriesTotalHeight<T>(List<PopupMenuEntry<T>> entries) {
  var total = 0.0;
  for (final entry in entries) {
    if (entry is PopupMenuDivider) {
      total += entry.height;
    } else if (entry is PopupMenuItem<T>) {
      total += entry.height;
    }
  }
  return total;
}

class _FrostedMenuList<T> extends StatelessWidget {
  const _FrostedMenuList({
    required this.entries,
    this.maxHeight,
    required this.onSelected,
  });

  final List<PopupMenuEntry<T>> entries;
  final double? maxHeight;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];

    for (final entry in entries) {
      if (entry is PopupMenuDivider) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Divider(
            height: entry.height,
            thickness: 1,
            color: FrostedGlassStyle.divider,
          ),
        ));
        continue;
      }

      if (entry is! PopupMenuItem<T>) continue;
      final item = entry;
      final height = item.height;
      final padding =
          (item.padding ?? const EdgeInsets.symmetric(horizontal: 12))
              .resolve(Directionality.of(context));

      if (!item.enabled) {
        rows.add(
          SizedBox(
            height: height,
            width: double.infinity,
            child: Padding(
              padding: padding,
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: item.child,
              ),
            ),
          ),
        );
        continue;
      }

      rows.add(
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () {
              item.onTap?.call();
              onSelected(item.value);
            },
            child: SizedBox(
              height: height,
              child: Padding(
                padding: padding,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: item.child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final list = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );

    final maxH = maxHeight;
    if (maxH != null && maxH.isFinite) {
      final contentHeight = _entriesTotalHeight(entries);
      if (contentHeight > maxH) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(child: list),
        );
      }
    }
    return list;
  }
}
