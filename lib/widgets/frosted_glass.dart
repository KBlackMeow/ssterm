import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Shared Liquid Glass styling — gradient borders, specular highlights,
/// blue-ambient shadows. All effects are static GPU paint; zero CPU overhead.
abstract final class FrostedGlassStyle {
  static const panelRadius = 12.0;
  static const menuRadius  = 10.0;
  static const blurSigma   = 26.0;

  // Neutral-dark fills — R=G=B so no colour tint on any dark terminal background.
  static const panelFillFrosted = Color(0xA0141414);
  static const panelFillSolid   = Color(0xEE161616);
  static const menuFillFrosted  = Color(0xAA1A1A1A);
  static const menuFillSolid    = Color(0xF81A1A1A);

  /// Modal dialog fill — pure neutral grey, semi-transparent.
  /// Never derives from terminal theme so dialogs stay consistent across themes.
  static const dialogFill = Color(0xCC1E1E1E);

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
  const AppColors({
    required this.popup,
    required this.foreground,
    required this.foregroundDim,
  });

  /// Fill color for all [PopupSurface] widgets (dialogs, command sheets, etc.).
  final Color popup;

  /// Primary text/icon color that contrasts against [popup].
  final Color foreground;

  /// Secondary/muted text/icon color that contrasts against [popup].
  final Color foregroundDim;

  /// Builds [AppColors] with [foreground] and [foregroundDim] auto-computed
  /// from [bg] luminance — dark bg → light text, light bg → dark text.
  static AppColors fromBackground(Color bg) {
    final isLight = bg.computeLuminance() > 0.5;
    return AppColors(
      popup: bg,
      foreground:    isLight ? const Color(0xFF1A1A1A) : const Color(0xFFD4D4D4),
      foregroundDim: isLight ? const Color(0xFF5A5A5A) : const Color(0xFF8E8E8E),
    );
  }

  static AppColors? maybeOf(BuildContext context) =>
      Theme.of(context).extension<AppColors>();

  @override
  AppColors copyWith({Color? popup, Color? foreground, Color? foregroundDim}) =>
      AppColors(
        popup:        popup        ?? this.popup,
        foreground:    foreground    ?? this.foreground,
        foregroundDim: foregroundDim ?? this.foregroundDim,
      );

  @override
  AppColors lerp(AppColors? other, double t) =>
      AppColors(
        popup:        Color.lerp(popup,        other?.popup,        t) ?? popup,
        foreground:    Color.lerp(foreground,    other?.foreground,    t) ?? foreground,
        foregroundDim: Color.lerp(foregroundDim, other?.foregroundDim, t) ?? foregroundDim,
      );
}

/// Standard popup/dialog surface: solid fill, white border, depth shadow.
/// Fill color is read from [AppColors] in the widget tree when not supplied.
class PopupSurface extends StatelessWidget {
  const PopupSurface({
    super.key,
    required this.child,
    this.color,
    this.radius = 20.0,
    this.backdropBlur = 0,
  });

  final Widget child;
  /// Explicit fill override. If null, uses [AppColors.popup] from context,
  /// falling back to [FrostedGlassStyle.menuFillSolid].
  final Color? color;
  final double radius;
  /// Gaussian blur sigma applied behind the surface via [BackdropFilter].
  /// `0` disables the effect (default). GPU-only — add a single paint layer.
  final double backdropBlur;

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

    // Material(transparency) ensures TextField / InkWell etc. always have a
    // Material ancestor, even when PopupSurface is used instead of Dialog.
    final content = Material(type: MaterialType.transparency, child: child);

    if (backdropBlur > 0) {
      // Shadow lives outside the clip; blur + fill are clipped to the rounded rect.
      return DecoratedBox(
        decoration: BoxDecoration(borderRadius: br, boxShadow: const [_shadow]),
        child: ClipRRect(
          borderRadius: br,
          clipBehavior: Clip.antiAlias,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: backdropBlur, sigmaY: backdropBlur),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: br,
                border: Border.all(color: _border, width: 1),
              ),
              child: content,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: br,
        border: Border.all(color: _border, width: 1),
        boxShadow: const [_shadow],
      ),
      child: ClipRRect(borderRadius: br, child: content),
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

/// Overlay-based frosted popup menu — inserts directly into the overlay stack
/// (no route animation) so [BackdropFilter] blur is immediate, matching
/// [showTransferMenu].
Future<T?> showFrostedMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
  ShapeBorder? shape,
}) {
  final overlayState = Overlay.of(context, rootOverlay: true);
  final screen      = MediaQuery.sizeOf(context);

  // Capture theme colors before entering the OverlayEntry builder,
  // which may not inherit the local Theme.
  final popupColor  = AppColors.maybeOf(context)?.popup ?? FrostedGlassStyle.menuFillFrosted;
  final menuColors  = AppColors.fromBackground(popupColor);
  final parentTheme = Theme.of(context);

  final completer = Completer<T?>();
  OverlayEntry? entry;

  void dismiss([T? value]) {
    if (entry != null && !completer.isCompleted) {
      entry!.remove();
      entry = null;
      completer.complete(value);
    }
  }

  // Only use bounded constraint values; BoxConstraints defaults maxWidth to
  // double.infinity when not set, so guard with isFinite before consuming.
  final minW = (constraints?.minWidth.isFinite  == true) ? constraints!.minWidth  : 200.0;
  final maxW = ((constraints?.maxWidth.isFinite  == true) ? constraints!.maxWidth  : 320.0)
      .clamp(minW, screen.width - 16);
  final maxH = ((constraints?.maxHeight.isFinite == true) ? constraints!.maxHeight : screen.height * 0.75);

  // Callers use a non-standard RelativeRect convention (matching the original
  // showMenu callers in this codebase):
  //   position.left  = button left edge X (from screen left)
  //   position.right = button right edge X (from screen left — NOT from screen right)
  // Prefer left-aligning with the button; flip right-aligned if space is tight.
  final double menuLeft;
  if (position.left + minW > screen.width - 8) {
    menuLeft = (position.right - minW).clamp(8.0, screen.width - minW - 8);
  } else {
    menuLeft = position.left.clamp(8.0, screen.width - minW - 8);
  }

  final menuTop = position.top.clamp(8.0, screen.height - 8.0);
  final availH  = (screen.height - menuTop - 8).clamp(0.0, maxH);

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => dismiss(null),
          ),
        ),
        Positioned(
          left: menuLeft,
          top: menuTop,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth:  minW,
              maxWidth:  maxW.clamp(0, screen.width - menuLeft - 8),
              maxHeight: availH,
            ),
            child: Theme(
              data: parentTheme.copyWith(extensions: {menuColors}),
              child: Material(
                type: MaterialType.transparency,
                child: PopupSurface(
                  color: popupColor,
                  radius: FrostedGlassStyle.menuRadius,
                  backdropBlur: 20,
                  child: _FrostedMenuList<T>(
                    entries: items,
                    maxHeight: availH,
                    onSelected: dismiss,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  overlayState.insert(entry!);
  return completer.future;
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
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
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
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
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
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(child: list),
          ),
        );
      }
    }
    return list;
  }
}
