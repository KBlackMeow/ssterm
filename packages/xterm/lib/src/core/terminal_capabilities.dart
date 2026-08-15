/// Immutable facts the terminal reports in response to capability queries.
///
/// The values deliberately describe only functionality implemented by xterm.
/// They are independent of the transport, so local PTYs and SSH sessions
/// produce identical replies on every host platform.
class TerminalCapabilities {
  const TerminalCapabilities({
    this.backgroundRgb = 0x1e1e1e,
    this.termName = 'SSTerm',
  }) : assert(backgroundRgb >= 0 && backgroundRgb <= 0xffffff);

  /// The active display background as an sRGB `0xRRGGBB` value.
  final int backgroundRgb;

  /// The honest terminal identifier returned by XTVERSION.
  final String termName;

  /// iTerm2's public feature-reporting encoding.
  ///
  /// `T3` means both compatible and colon-form 24-bit SGR are supported;
  /// `Sc6` covers all DECSCUSR cursor shapes SSTerm renders; `Ts2` means title
  /// setting (but not title stacks). The remaining letters represent the
  /// implemented mouse and bracketed-paste protocols.
  static const featureReport = 'T3MSc6Ts2B';

  TerminalCapabilities copyWith({int? backgroundRgb, String? termName}) {
    return TerminalCapabilities(
      backgroundRgb: backgroundRgb ?? this.backgroundRgb,
      termName: termName ?? this.termName,
    );
  }

  String get backgroundColorReport {
    final red = (backgroundRgb >> 16) & 0xff;
    final green = (backgroundRgb >> 8) & 0xff;
    final blue = backgroundRgb & 0xff;
    return 'rgb:${_component(red)}/${_component(green)}/${_component(blue)}';
  }

  static String _component(int value) {
    // OSC color reports use 16-bit components. Replicate the 8-bit sRGB
    // component so applications can round-trip it without losing precision.
    final expanded = (value << 8) | value;
    return expanded.toRadixString(16).padLeft(4, '0');
  }
}
