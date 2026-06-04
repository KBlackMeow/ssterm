import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Shared Liquid Glass styling — gradient borders, specular highlights,
/// blue-ambient shadows. All effects are static GPU paint; zero CPU overhead.
abstract final class FrostedGlassStyle {
  static const panelRadius = 12.0;
  static const menuRadius  = 10.0;
  static const blurSigma   = 26.0;

  // Neutral-dark fills — no blue tint so they sit naturally on any dark
  // terminal background (black, near-black, dark grey).
  static const panelFillFrosted = Color(0xA0141416);
  static const panelFillSolid   = Color(0xEE161618);
  static const menuFillFrosted  = Color(0xAA181820);
  static const menuFillSolid    = Color(0xF8181820);

  // Divider between menu items — slightly blue-dark
  static const divider = Color(0xFF252525);

  // Gradient border: bright top-left → dim bottom-right (simulates glass edge)
  static const _borderBright = Color(0x50FFFFFF);
  static const _borderDim    = Color(0x0CFFFFFF);

  // Shadows: depth black
  static const _shadowDepth = BoxShadow(
    color: Color(0x45000000),
    blurRadius: 20,
    offset: Offset(0, 6),
  );
  static const _shadowInner = BoxShadow(
    color: Color(0x18000000),
    blurRadius: 8,
    offset: Offset(0, 2),
    spreadRadius: -2,
  );

  static BoxDecoration borderDecoration(double radius) => BoxDecoration(
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [_borderBright, _borderDim],
    ),
    borderRadius: BorderRadius.circular(radius),
    boxShadow: const [_shadowDepth, _shadowInner],
  );
}

/// Theme extension that carries app-wide color tokens.
/// Inject once near the root; [PopupSurface] and dialogs read from it.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({required this.popup});

  /// Fill color for all [PopupSurface] widgets (dialogs, command sheets, etc.).
  final Color popup;

  static AppColors? maybeOf(BuildContext context) =>
      Theme.of(context).extension<AppColors>();

  @override
  AppColors copyWith({Color? popup}) =>
      AppColors(popup: popup ?? this.popup);

  @override
  AppColors lerp(AppColors? other, double t) =>
      AppColors(popup: Color.lerp(popup, other?.popup, t) ?? popup);
}

/// Standard popup/dialog surface: solid fill, white border, depth shadow.
/// Fill color is read from [AppColors] in the widget tree when not supplied.
class PopupSurface extends StatelessWidget {
  const PopupSurface({
    super.key,
    required this.child,
    this.color,
    this.radius = 20.0,
  });

  final Widget child;
  /// Explicit fill override. If null, uses [AppColors.popup] from context,
  /// falling back to [FrostedGlassStyle.menuFillSolid].
  final Color? color;
  final double radius;

  static const _border = Color(0x28FFFFFF);
  static const _shadow = BoxShadow(
    color: Color(0x30000000),
    blurRadius: 4,
    offset: Offset(0, 2),
  );

  @override
  Widget build(BuildContext context) {
    final fill = color ??
        AppColors.maybeOf(context)?.popup ??
        FrostedGlassStyle.menuFillSolid;
    final br = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: br,
        border: Border.all(color: _border, width: 1),
        boxShadow: const [_shadow],
      ),
      child: ClipRRect(borderRadius: br, child: child),
    );
  }
}

/// Liquid-Glass surface: gradient border, specular top-edge highlight,
/// bottom refraction shadow, optional [BackdropFilter] blur.
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
    final innerR = (borderRadius - 1.0).clamp(0.0, double.infinity);
    final innerRadius = BorderRadius.circular(innerR);

    final fill = fillColor ??
        (frosted
            ? FrostedGlassStyle.menuFillFrosted
            : FrostedGlassStyle.menuFillSolid);

    // Three foreground paint layers stacked via DecorationPosition.foreground
    // (zero layout cost — all GPU paint, no extra RenderObject):
    //   1. Top specular strip  — white glow fading from top edge
    //   2. Bottom refraction   — dark absorption at bottom edge
    //   3. Fill color          — base glass tint
    Widget core = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end:   Alignment.bottomCenter,
          colors: [Color(0x1AFFFFFF), Color(0x00FFFFFF)],
          stops:  [0.0, 0.30],
        ),
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end:   Alignment.topCenter,
            colors: [Color(0x14000000), Color(0x00000000)],
            stops:  [0.0, 0.20],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: fill),
          child: child,
        ),
      ),
    );

    final useBlur = blur ?? frosted;
    if (useBlur) {
      core = BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: FrostedGlassStyle.blurSigma,
          sigmaY: FrostedGlassStyle.blurSigma,
        ),
        child: core,
      );
    }

    // Outer ring = gradient painted as 1 px border via Padding trick.
    // BoxShadow lives here so it sits outside the clip.
    return DecoratedBox(
      decoration: FrostedGlassStyle.borderDecoration(borderRadius),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: innerRadius,
          clipBehavior: Clip.antiAlias,
          child: core,
        ),
      ),
    );
  }
}

/// [showMenu] wrapper: PopupSurface chrome (solid fill, white border, depth shadow).
Future<T?> showFrostedMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
  ShapeBorder? shape,
}) {
  final menuShape = shape ??
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FrostedGlassStyle.menuRadius),
        side: BorderSide.none,
      );

  final themeColor = AppColors.maybeOf(context)?.popup;

  // showMenu wraps items in a SingleChildScrollView with 8 px top + 8 px bottom
  // padding, and FrostedGlassSurface adds a 1 px Padding on every side.
  // Subtract these from the effective max-height so the glass surface and its
  // rounded corners are never clipped by the popup route's constraint box.
  const double kHeightOverhead = 8.0 * 2 + 1.0 * 2; // 18 px

  BoxConstraints? innerConstraints;
  if (constraints != null && constraints.hasBoundedHeight) {
    innerConstraints = BoxConstraints(
      minWidth:  constraints.minWidth,
      maxWidth:  constraints.maxWidth,
      minHeight: constraints.minHeight,
      maxHeight: (constraints.maxHeight - kHeightOverhead)
          .clamp(0.0, double.infinity),
    );
  }

  final effectiveConstraints = innerConstraints ?? constraints;
  final shellHeight = _frostedMenuShellHeight(items, effectiveConstraints);
  final fixedHeight = effectiveConstraints != null &&
      effectiveConstraints.hasBoundedHeight &&
      effectiveConstraints.minHeight == effectiveConstraints.maxHeight;

  return showMenu<T>(
    context: context,
    position: position,
    constraints: constraints,
    color: Colors.transparent,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    clipBehavior: Clip.none,
    shape: menuShape,
    items: [
      PopupMenuItem<T>(
        enabled: false,
        padding: EdgeInsets.zero,
        height: shellHeight,
        child: PopupSurface(
          color: themeColor ?? FrostedGlassStyle.menuFillFrosted,
          radius: FrostedGlassStyle.menuRadius,
          child: _FrostedMenuList<T>(
            entries: items,
            maxHeight: fixedHeight ? null : effectiveConstraints?.maxHeight,
            onSelected: (value) => Navigator.of(context).pop<T>(value),
          ),
        ),
      ),
    ],
  );
}

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
    if (constraints.minHeight == maxH && maxH.isFinite) return maxH;
    if (maxH.isFinite && total > maxH) return maxH;
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
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Divider(
            height: entry.height,
            thickness: 0.5,
            color: FrostedGlassStyle.divider,
          ),
        ));
        continue;
      }

      if (entry is! PopupMenuItem<T>) continue;
      final item   = entry;
      final height = item.height;
      final padding =
          (item.padding ?? const EdgeInsets.symmetric(horizontal: 14))
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
            overlayColor: WidgetStateProperty.all(const Color(0x14FFFFFF)),
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
