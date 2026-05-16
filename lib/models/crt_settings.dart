import 'package:flutter/widgets.dart';

enum CrtPhosphor { green, amber, white }

extension CrtPhosphorX on CrtPhosphor {
  Color get color => switch (this) {
        CrtPhosphor.green => const Color(0xFF00FF41),
        CrtPhosphor.amber => const Color(0xFFFFB000),
        CrtPhosphor.white => const Color(0xFFE8F0FF),
      };

  String get label => switch (this) {
        CrtPhosphor.green => 'Green (P1)',
        CrtPhosphor.amber => 'Amber (P3)',
        CrtPhosphor.white => 'White (P4)',
      };

  String get id => name;

  static CrtPhosphor fromId(String? id) => switch (id) {
        'amber' => CrtPhosphor.amber,
        'white' => CrtPhosphor.white,
        _ => CrtPhosphor.green,
      };
}

class CrtSettings {
  const CrtSettings({
    this.enabled = false,
    this.phosphor = CrtPhosphor.green,
    this.scanlineOpacity = 0.25,
    this.glowIntensity = 0.45,
    this.vignette = 0.40,
    this.curvature = 0.20,
    this.flickerIntensity = 0.12,
    this.noiseIntensity = 0.07,
  });

  final bool enabled;
  final CrtPhosphor phosphor;

  /// Darkness of each horizontal scanline row (0–0.6).
  final double scanlineOpacity;

  /// Phosphor electron-beam spread; blurs the image slightly (0–1).
  final double glowIntensity;

  /// Edge-darkening vignette strength (0–1).
  final double vignette;

  /// Screen corner rounding; 0 = square, 1 = heavily rounded (0–1).
  final double curvature;

  /// Brightness oscillation depth (0–1).
  final double flickerIntensity;

  /// Static-noise grain density (0–1).
  final double noiseIntensity;

  CrtSettings copyWith({
    bool? enabled,
    CrtPhosphor? phosphor,
    double? scanlineOpacity,
    double? glowIntensity,
    double? vignette,
    double? curvature,
    double? flickerIntensity,
    double? noiseIntensity,
  }) =>
      CrtSettings(
        enabled: enabled ?? this.enabled,
        phosphor: phosphor ?? this.phosphor,
        scanlineOpacity: scanlineOpacity ?? this.scanlineOpacity,
        glowIntensity: glowIntensity ?? this.glowIntensity,
        vignette: vignette ?? this.vignette,
        curvature: curvature ?? this.curvature,
        flickerIntensity: flickerIntensity ?? this.flickerIntensity,
        noiseIntensity: noiseIntensity ?? this.noiseIntensity,
      );

  static CrtSettings fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CrtSettings();
    return CrtSettings(
      enabled: json['enabled'] as bool? ?? false,
      phosphor: CrtPhosphorX.fromId(json['phosphor'] as String?),
      scanlineOpacity: (json['scanlineOpacity'] as num?)?.toDouble() ?? 0.25,
      glowIntensity: (json['glowIntensity'] as num?)?.toDouble() ?? 0.45,
      vignette: (json['vignette'] as num?)?.toDouble() ?? 0.40,
      curvature: (json['curvature'] as num?)?.toDouble() ?? 0.20,
      flickerIntensity: (json['flickerIntensity'] as num?)?.toDouble() ?? 0.12,
      noiseIntensity: (json['noiseIntensity'] as num?)?.toDouble() ?? 0.07,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'phosphor': phosphor.id,
        'scanlineOpacity': scanlineOpacity,
        'glowIntensity': glowIntensity,
        'vignette': vignette,
        'curvature': curvature,
        'flickerIntensity': flickerIntensity,
        'noiseIntensity': noiseIntensity,
      };
}
