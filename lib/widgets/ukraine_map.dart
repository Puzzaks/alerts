import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/alerts_mesh_service.dart';
import '../services/ukrainian_locations.dart';
import 'ukraine_map_data.dart';

/// Unified alert severity tier for a Ukrainian oblast polygon on [UkraineOblastsMap].
enum OblastAlertStatus {
  clear,
  yellow,
  red,
}

/// Computed alert status for a single [UkraineOblastPolygon].
class OblastMapStatus {
  final UkraineOblastPolygon polygon;
  final OblastAlertStatus status;
  final int alertCount;
  final bool isDefaultRegion;

  const OblastMapStatus({
    required this.polygon,
    required this.status,
    required this.alertCount,
    required this.isDefaultRegion,
  });

  bool get isClear => status == OblastAlertStatus.clear;

  bool get isYellow => status == OblastAlertStatus.yellow;

  bool get isRed => status == OblastAlertStatus.red;

  bool get hasYellowOnly => status == OblastAlertStatus.yellow;
}

/// Interactive pure-Flutter Material 3 map of Ukraine's 27 top-level regions
/// (24 oblasts, AR Crimea, Kyiv City, and Sevastopol City).
///
/// Colors each region polygon strictly vivid Red, vivid Yellow, or Clear
/// regardless of whether alerts are oblast-wide or sub-oblast (hromada/raion),
/// outlines `defaultRegion` with a `2px` primary border, animates color updates,
/// and supports tap hit-testing via [Path.contains] (enclaves tested first).
class UkraineOblastsMap extends StatefulWidget {
  final List<AlertItem> alerts;
  final List<String> affectedOblasts;
  final String defaultRegion;
  final VoidCallback? onTap;
  final bool? allowPolygonSelection;
  final double? maxHeight;
  final EdgeInsetsGeometry padding;
  final bool showOverlayChip;
  final String? selectedIsoCode;
  final ValueChanged<OblastMapStatus?>? onOblastSelected;
  final bool isUkrainian;
  final OblastOverlayStrings? overlayStrings;

  static const Color redAlertColor = Color(0xFFE53935);
  static const Color yellowAlertColor = Color(0xFFFFD600);

  const UkraineOblastsMap({
    super.key,
    required this.alerts,
    this.affectedOblasts = const <String>[],
    this.defaultRegion = '',
    this.onTap,
    this.allowPolygonSelection,
    this.maxHeight = 260,
    this.padding = const EdgeInsets.all(14),
    this.showOverlayChip = true,
    this.selectedIsoCode,
    this.onOblastSelected,
    this.isUkrainian = false,
    this.overlayStrings,
  });

  static bool _isKyivCityText(String normalized) {
    return normalized == 'м. київ' ||
        normalized == 'київ' ||
        normalized == 'місто київ' ||
        normalized == 'kyiv city' ||
        normalized == 'kyiv' ||
        normalized == 'kiev' ||
        normalized == 'kiev city';
  }

  static bool _isSevastopolCityText(String normalized) {
    return normalized == 'м. севастополь' ||
        normalized == 'севастополь' ||
        normalized == 'місто севастополь' ||
        normalized == 'sevastopol city' ||
        normalized == 'sevastopol';
  }

  static bool _isKyivCityAlert(AlertItem alert) {
    final title = _normalize(alert.locationTitle);
    final titleEn = _normalize(alert.locationTitleEn ?? '');
    final oblast = _normalize(alert.locationOblast);
    return _isKyivCityText(title) ||
        _isKyivCityText(oblast) ||
        _isKyivCityText(titleEn);
  }

  static bool _isSevastopolCityAlert(AlertItem alert) {
    final title = _normalize(alert.locationTitle);
    final titleEn = _normalize(alert.locationTitleEn ?? '');
    final oblast = _normalize(alert.locationOblast);
    return _isSevastopolCityText(title) ||
        _isSevastopolCityText(oblast) ||
        _isSevastopolCityText(titleEn);
  }

  /// Computes per-region statuses from [alerts], [affectedOblasts], and [defaultRegion].
  static List<OblastMapStatus> computeStatuses({
    required List<AlertItem> alerts,
    required List<String> affectedOblasts,
    required String defaultRegion,
  }) {
    final trimmedDefault = defaultRegion.trim();
    final defaultLoc = trimmedDefault.isEmpty
        ? null
        : UkrainianLocations.findByCanonicalOrAlias(trimmedDefault);
    final String? defaultOblastCanonical = defaultLoc?.oblastCanonicalName;
    final String normDefaultFallback = _normalize(trimmedDefault);
    final normalizedAffected = affectedOblasts.map(_normalize).toList();

    return ukraineOblastPolygons.map((poly) {
      final polyTerms = _termsForPolygon(poly);
      final ukNorm = _normalize(poly.ukName);
      final enNorm = _normalize(poly.enName);

      final bool isDefault;
      if (defaultOblastCanonical != null) {
        isDefault = defaultOblastCanonical == poly.ukName;
      } else if (normDefaultFallback.isNotEmpty) {
        isDefault =
            ukNorm == normDefaultFallback || enNorm == normDefaultFallback;
      } else {
        isDefault = false;
      }

      final bool isKyivCityPoly =
          poly.ukName == UkrainianLocations.kyivCityCanonical;
      final bool isSevastopolPoly =
          poly.ukName == UkrainianLocations.sevastopolCityCanonical;

      int count = 0;
      bool hasRed = false;
      bool hasYellow = false;

      for (final alert in alerts) {
        final bool alertIsKyivCity = _isKyivCityAlert(alert);
        final bool alertIsSevastopol = _isSevastopolCityAlert(alert);

        final bool matches;
        if (isKyivCityPoly) {
          matches = alertIsKyivCity;
        } else if (isSevastopolPoly) {
          matches = alertIsSevastopol;
        } else if (alertIsKyivCity || alertIsSevastopol) {
          matches = false;
        } else {
          final oblastField = _normalize(alert.locationOblast);
          final titleField = _normalize(alert.locationTitle);
          final target = oblastField.isNotEmpty ? oblastField : titleField;
          matches = target.isNotEmpty &&
              polyTerms.any(
                (term) => term.isNotEmpty && target.contains(term),
              );
        }

        if (!matches) {
          continue;
        }

        count++;
        final isYellow = alert.alertLevel?.trim().toLowerCase() == 'yellow';
        if (isYellow) {
          hasYellow = true;
        } else {
          hasRed = true;
        }
      }

      if (count == 0 && normalizedAffected.isNotEmpty) {
        final affectedMatch = normalizedAffected.any((name) {
          if (name.isEmpty) return false;
          if (isKyivCityPoly) return _isKyivCityText(name);
          if (isSevastopolPoly) return _isSevastopolCityText(name);
          if (_isKyivCityText(name) || _isSevastopolCityText(name)) {
            return false;
          }
          return polyTerms.any((term) => term.isNotEmpty && name.contains(term));
        });
        if (affectedMatch) {
          hasRed = true;
        }
      }

      final OblastAlertStatus status;
      if (hasRed) {
        status = OblastAlertStatus.red;
      } else if (hasYellow) {
        status = OblastAlertStatus.yellow;
      } else {
        status = OblastAlertStatus.clear;
      }

      return OblastMapStatus(
        polygon: poly,
        status: status,
        alertCount: count,
        isDefaultRegion: isDefault,
      );
    }).toList(growable: false);
  }

  static final Map<String, Path> _normalizedPaths = <String, Path>{};

  /// Returns the cached immutable normalized [Path] in `[0..1, 0..ukraineMapNormalizedHeight]`
  /// coordinates for [polygon].
  static Path normalizedPathFor(UkraineOblastPolygon polygon) {
    return _normalizedPaths.putIfAbsent(polygon.isoCode, () {
      final Path path = Path();
      if (polygon.points.isEmpty) return path;

      final Offset first = polygon.points.first;
      path.moveTo(first.dx, first.dy);
      for (int i = 1; i < polygon.points.length; i++) {
        final Offset pt = polygon.points[i];
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      return path;
    });
  }

  static ({double scale, double offsetX, double offsetY}) _mapTransform(
    Size size,
  ) {
    final double scale = math.min(
      size.width,
      size.height / ukraineMapNormalizedHeight,
    );
    final double offsetX = (size.width - scale) * 0.5;
    final double offsetY =
        (size.height - scale * ukraineMapNormalizedHeight) * 0.5;
    return (scale: scale, offsetX: offsetX, offsetY: offsetY);
  }

  /// Builds the scaled canvas [Path] for [polygon] inside a box of [size].
  static Path buildPolygonPath(UkraineOblastPolygon polygon, Size size) {
    final t = _mapTransform(size);
    final Float64List matrix = Float64List.fromList(<double>[
      t.scale,
      0.0,
      0.0,
      0.0,
      0.0,
      t.scale,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      t.offsetX,
      t.offsetY,
      0.0,
      1.0,
    ]);
    return normalizedPathFor(polygon).transform(matrix);
  }

  static final Map<String, Set<String>> _cachedPolyTerms =
      <String, Set<String>>{};

  static Set<String> _termsForPolygon(UkraineOblastPolygon poly) {
    return _cachedPolyTerms.putIfAbsent(
      poly.isoCode,
      () => <String>{
        ...AlertsMeshService.expandRegionTerms(poly.ukName),
        ...AlertsMeshService.expandRegionTerms(poly.enName),
      },
    );
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll('`', "'")
        .replaceAll(RegExp(r'[\s_]+'), ' ')
        .trim();
  }

  @override
  State<UkraineOblastsMap> createState() => _UkraineOblastsMapState();
}

class _UkraineOblastsMapState extends State<UkraineOblastsMap>
    with TickerProviderStateMixin {
  String? _internalSelectedIsoCode;
  Size _lastCanvasSize = Size.zero;

  late final AnimationController _colorController;
  late final Animation<double> _colorAnimation;

  late List<OblastMapStatus> _statuses;
  Map<String, _PolygonVisualStyle> _fromStyles =
      <String, _PolygonVisualStyle>{};
  Map<String, _PolygonVisualStyle> _targetStyles =
      <String, _PolygonVisualStyle>{};
  ColorScheme? _lastScheme;

  bool get _canSelectPolygon =>
      widget.allowPolygonSelection ?? (widget.onTap == null);

  String? get _effectiveSelectedIsoCode => widget.onOblastSelected != null
      ? widget.selectedIsoCode
      : _internalSelectedIsoCode;

  @override
  void initState() {
    super.initState();
    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _colorAnimation = CurvedAnimation(
      parent: _colorController,
      curve: Curves.easeInOutCubic,
    );
    _statuses = _computeCurrentStatuses();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scheme = Theme.of(context).colorScheme;
    if (_lastScheme != scheme) {
      final bool isInitial = _lastScheme == null;
      _lastScheme = scheme;
      _syncTargetStyles(scheme, animate: !isInitial);
    }
  }

  @override
  void didUpdateWidget(covariant UkraineOblastsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alerts != widget.alerts ||
        oldWidget.affectedOblasts != widget.affectedOblasts ||
        oldWidget.defaultRegion != widget.defaultRegion ||
        oldWidget.selectedIsoCode != widget.selectedIsoCode ||
        oldWidget.allowPolygonSelection != widget.allowPolygonSelection ||
        oldWidget.onTap != widget.onTap ||
        oldWidget.onOblastSelected != widget.onOblastSelected) {
      _statuses = _computeCurrentStatuses();
      final scheme = _lastScheme ?? Theme.of(context).colorScheme;
      _syncTargetStyles(scheme, animate: true);
    }
  }

  @override
  void dispose() {
    _colorController.dispose();
    super.dispose();
  }

  List<OblastMapStatus> _computeCurrentStatuses() {
    return UkraineOblastsMap.computeStatuses(
      alerts: widget.alerts,
      affectedOblasts: widget.affectedOblasts,
      defaultRegion: widget.defaultRegion,
    );
  }

  Map<String, _PolygonVisualStyle> _buildTargetStyles(ColorScheme scheme) {
    final activeIso = _canSelectPolygon ? _effectiveSelectedIsoCode : null;
    final bool isDark = scheme.brightness == Brightness.dark;
    final Color alertBorderColor = isDark
        ? scheme.surface.withValues(alpha: 0.88)
        : const Color(0xFF1C1B1F).withValues(alpha: 0.48);

    final styles = <String, _PolygonVisualStyle>{};
    for (final status in _statuses) {
      final Color fill;
      final Color border;
      final double borderWidth;
      switch (status.status) {
        case OblastAlertStatus.red:
          fill = UkraineOblastsMap.redAlertColor;
          border = alertBorderColor;
          borderWidth = 1.25;
        case OblastAlertStatus.yellow:
          fill = UkraineOblastsMap.yellowAlertColor;
          border = alertBorderColor;
          borderWidth = 1.25;
        case OblastAlertStatus.clear:
          fill = scheme.surfaceContainerHighest;
          border = scheme.outlineVariant;
          borderWidth = 1.0;
      }

      final bool isSelected = status.polygon.isoCode == activeIso;
      styles[status.polygon.isoCode] = _PolygonVisualStyle(
        fill: fill,
        border: border,
        borderWidth: borderWidth,
        defaultBorder: status.isDefaultRegion
            ? scheme.primary
            : scheme.primary.withValues(alpha: 0.0),
        defaultBorderWidth: status.isDefaultRegion ? 2.1 : 0.0,
        selectedBorder: isSelected
            ? scheme.onSurface
            : scheme.onSurface.withValues(alpha: 0.0),
        selectedBorderWidth: isSelected ? 2.3 : 0.0,
      );
    }
    return styles;
  }

  void _syncTargetStyles(ColorScheme scheme, {required bool animate}) {
    final nextTargets = _buildTargetStyles(scheme);
    if (!animate || _targetStyles.isEmpty) {
      _fromStyles = nextTargets;
      _targetStyles = nextTargets;
      _colorController.value = 1.0;
      return;
    }

    bool changed = false;
    for (final entry in nextTargets.entries) {
      if (_targetStyles[entry.key] != entry.value) {
        changed = true;
        break;
      }
    }
    if (!changed) return;

    final double currentT = _colorAnimation.value;
    final snapshot = <String, _PolygonVisualStyle>{};
    for (final entry in nextTargets.entries) {
      final from = _fromStyles[entry.key] ?? entry.value;
      final to = _targetStyles[entry.key] ?? entry.value;
      snapshot[entry.key] = _PolygonVisualStyle.lerp(from, to, currentT);
    }
    _fromStyles = snapshot;
    _targetStyles = nextTargets;
    _colorController.forward(from: 0.0);
  }

  List<_PaintedPolygon> _resolvePaintedPolygons(double t) {
    return <_PaintedPolygon>[
      for (final status in _statuses)
        _PaintedPolygon(
          polygon: status.polygon,
          style: _PolygonVisualStyle.lerp(
            _fromStyles[status.polygon.isoCode] ??
                _targetStyles[status.polygon.isoCode]!,
            _targetStyles[status.polygon.isoCode]!,
            t,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_lastScheme != scheme) {
      _lastScheme = scheme;
      _syncTargetStyles(scheme, animate: _targetStyles.isNotEmpty);
    }

    final statuses = _statuses;
    final String? activeIso = _effectiveSelectedIsoCode;
    OblastMapStatus? selectedStatus;
    if (activeIso != null) {
      for (final status in statuses) {
        if (status.polygon.isoCode == activeIso) {
          selectedStatus = status;
          break;
        }
      }
    }

    Widget aspectCanvas = AspectRatio(
      aspectRatio: ukraineMapAspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          _lastCanvasSize = canvasSize;

          final paint = RepaintBoundary(
            child: AnimatedBuilder(
              animation: _colorAnimation,
              builder: (context, _) {
                final paintedPolygons =
                    _resolvePaintedPolygons(_colorAnimation.value);
                return CustomPaint(
                  size: canvasSize,
                  isComplex: true,
                  willChange: _colorController.isAnimating,
                  painter: _UkraineMapPainter(
                    polygons: paintedPolygons,
                  ),
                );
              },
            ),
          );

          if (!_canSelectPolygon) {
            return paint;
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _handleTap(details.localPosition, statuses),
            child: paint,
          );
        },
      ),
    );

    if (widget.maxHeight != null) {
      aspectCanvas = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: aspectCanvas,
      );
    }

    Widget mapBody = Padding(
      padding: widget.padding,
      child: Center(child: aspectCanvas),
    );

    if (widget.onTap != null) {
      mapBody = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: mapBody,
      );
    }

    if (!widget.showOverlayChip ||
        !_canSelectPolygon ||
        selectedStatus == null) {
      return mapBody;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        mapBody,
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: OblastOverlayChip(
                status: selectedStatus,
                onClose: () => _updateSelection(null),
                isUkrainian: widget.isUkrainian,
                overlayStrings: widget.overlayStrings,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _updateSelection(OblastMapStatus? status) {
    if (widget.onOblastSelected != null) {
      widget.onOblastSelected!(status);
    } else {
      setState(() {
        _internalSelectedIsoCode = status?.polygon.isoCode;
        final scheme = _lastScheme ?? Theme.of(context).colorScheme;
        _syncTargetStyles(scheme, animate: true);
      });
    }
  }

  void _handleTap(Offset localPosition, List<OblastMapStatus> statuses) {
    if (_lastCanvasSize.isEmpty) return;

    final t = UkraineOblastsMap._mapTransform(_lastCanvasSize);
    if (t.scale <= 0.0) return;
    final Offset normPoint = Offset(
      (localPosition.dx - t.offsetX) / t.scale,
      (localPosition.dy - t.offsetY) / t.scale,
    );

    OblastMapStatus? hitStatus;
    // Iterate in reverse paint order so enclaves (Kyiv City, Sevastopol)
    // drawn on top of surrounding oblasts hit-test first.
    for (int i = statuses.length - 1; i >= 0; i--) {
      final status = statuses[i];
      final path = UkraineOblastsMap.normalizedPathFor(status.polygon);
      if (path.contains(normPoint)) {
        hitStatus = status;
        break;
      }
    }

    if (hitStatus == null ||
        hitStatus.polygon.isoCode == _effectiveSelectedIsoCode) {
      _updateSelection(null);
    } else {
      _updateSelection(hitStatus);
    }
  }
}

class _PolygonVisualStyle {
  final Color fill;
  final Color border;
  final double borderWidth;
  final Color defaultBorder;
  final double defaultBorderWidth;
  final Color selectedBorder;
  final double selectedBorderWidth;

  const _PolygonVisualStyle({
    required this.fill,
    required this.border,
    required this.borderWidth,
    required this.defaultBorder,
    required this.defaultBorderWidth,
    required this.selectedBorder,
    required this.selectedBorderWidth,
  });

  static _PolygonVisualStyle lerp(
    _PolygonVisualStyle a,
    _PolygonVisualStyle b,
    double t,
  ) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;
    return _PolygonVisualStyle(
      fill: Color.lerp(a.fill, b.fill, t)!,
      border: Color.lerp(a.border, b.border, t)!,
      borderWidth: a.borderWidth + (b.borderWidth - a.borderWidth) * t,
      defaultBorder: Color.lerp(a.defaultBorder, b.defaultBorder, t)!,
      defaultBorderWidth: a.defaultBorderWidth +
          (b.defaultBorderWidth - a.defaultBorderWidth) * t,
      selectedBorder: Color.lerp(a.selectedBorder, b.selectedBorder, t)!,
      selectedBorderWidth: a.selectedBorderWidth +
          (b.selectedBorderWidth - a.selectedBorderWidth) * t,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _PolygonVisualStyle &&
            fill == other.fill &&
            border == other.border &&
            borderWidth == other.borderWidth &&
            defaultBorder == other.defaultBorder &&
            defaultBorderWidth == other.defaultBorderWidth &&
            selectedBorder == other.selectedBorder &&
            selectedBorderWidth == other.selectedBorderWidth;
  }

  @override
  int get hashCode => Object.hash(
        fill,
        border,
        borderWidth,
        defaultBorder,
        defaultBorderWidth,
        selectedBorder,
        selectedBorderWidth,
      );
}

class _PaintedPolygon {
  final UkraineOblastPolygon polygon;
  final _PolygonVisualStyle style;

  const _PaintedPolygon({
    required this.polygon,
    required this.style,
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _PaintedPolygon &&
            polygon.isoCode == other.polygon.isoCode &&
            style == other.style;
  }

  @override
  int get hashCode => Object.hash(polygon.isoCode, style);
}

class _UkraineMapPainter extends CustomPainter {
  final List<_PaintedPolygon> polygons;

  const _UkraineMapPainter({required this.polygons});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final t = UkraineOblastsMap._mapTransform(size);
    if (t.scale <= 0.0) return;
    final double invScale = 1.0 / t.scale;

    canvas.save();
    canvas.translate(t.offsetX, t.offsetY);
    canvas.scale(t.scale, t.scale);

    final Paint fillPaint = Paint()..style = PaintingStyle.fill;
    final Paint borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    // Pass 1: Fill every region polygon strictly vivid Red / Yellow / Clear.
    for (final entry in polygons) {
      final path = UkraineOblastsMap.normalizedPathFor(entry.polygon);
      fillPaint.color = entry.style.fill;
      canvas.drawPath(path, fillPaint);
    }

    // Pass 2: Draw standard borders (high-contrast on adjacent red/yellow regions).
    for (final entry in polygons) {
      final path = UkraineOblastsMap.normalizedPathFor(entry.polygon);
      borderPaint
        ..color = entry.style.border
        ..strokeWidth = entry.style.borderWidth * invScale;
      canvas.drawPath(path, borderPaint);
    }

    // Pass 3: Draw accented 2px primary border for defaultRegion and selection highlight on top.
    for (final entry in polygons) {
      final path = UkraineOblastsMap.normalizedPathFor(entry.polygon);
      if (entry.style.defaultBorderWidth > 0.05 &&
          entry.style.defaultBorder.a > 0.01) {
        borderPaint
          ..color = entry.style.defaultBorder
          ..strokeWidth = entry.style.defaultBorderWidth * invScale;
        canvas.drawPath(path, borderPaint);
      }
      if (entry.style.selectedBorderWidth > 0.05 &&
          entry.style.selectedBorder.a > 0.01) {
        borderPaint
          ..color = entry.style.selectedBorder
          ..strokeWidth = entry.style.selectedBorderWidth * invScale;
        canvas.drawPath(path, borderPaint);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _UkraineMapPainter oldDelegate) {
    if (identical(oldDelegate.polygons, polygons)) return false;
    if (oldDelegate.polygons.length != polygons.length) return true;
    for (int i = 0; i < polygons.length; i++) {
      if (oldDelegate.polygons[i] != polygons[i]) return true;
    }
    return false;
  }
}

/// Localized labels used by [OblastOverlayChip] when a map polygon is tapped.
class OblastOverlayStrings {
  final String clearLabel;
  final String activeAlertLabel;
  final String oneAlertSuffix;
  final String fewAlertsSuffix;
  final String manyAlertsSuffix;
  final String yellowNote;
  final String defaultBadgeLabel;

  const OblastOverlayStrings({
    this.clearLabel = 'All clear',
    this.activeAlertLabel = 'Active alert',
    this.oneAlertSuffix = 'active alert',
    this.fewAlertsSuffix = 'active alerts',
    this.manyAlertsSuffix = 'active alerts',
    this.yellowNote = 'Yellow',
    this.defaultBadgeLabel = 'Default',
  });

  const OblastOverlayStrings.uk({
    this.clearLabel = 'Тривог немає',
    this.activeAlertLabel = 'Активна тривога',
    this.oneAlertSuffix = 'тривога',
    this.fewAlertsSuffix = 'тривоги',
    this.manyAlertsSuffix = 'тривог',
    this.yellowNote = 'Жовтий рівень',
    this.defaultBadgeLabel = 'За замовчуванням',
  });

  String formatAlertCount(int count, {required bool isUkrainian}) {
    if (isUkrainian) {
      final int mod100 = count % 100;
      final int mod10 = count % 10;
      if (mod10 == 1 && mod100 != 11) {
        return '$count $oneAlertSuffix';
      }
      if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
        return '$count $fewAlertsSuffix';
      }
      return '$count $manyAlertsSuffix';
    }
    return '$count ${count == 1 ? oneAlertSuffix : manyAlertsSuffix}';
  }
}

/// Compact Material 3 floating overlay chip shown when an oblast polygon is tapped.
class OblastOverlayChip extends StatelessWidget {
  final OblastMapStatus status;
  final VoidCallback onClose;
  final bool isUkrainian;
  final String? localizedOblastName;
  final OblastOverlayStrings? overlayStrings;

  const OblastOverlayChip({
    super.key,
    required this.status,
    required this.onClose,
    this.isUkrainian = false,
    this.localizedOblastName,
    this.overlayStrings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final OblastOverlayStrings strings = overlayStrings ??
        (isUkrainian
            ? const OblastOverlayStrings.uk()
            : const OblastOverlayStrings());
    final String oblastLabel = localizedOblastName ??
        (isUkrainian ? status.polygon.ukName : status.polygon.enName);

    final String summaryText;
    if (status.isClear) {
      summaryText = strings.clearLabel;
    } else if (status.alertCount == 0) {
      summaryText = strings.activeAlertLabel;
    } else {
      final levelNote = status.isYellow ? ' · ${strings.yellowNote}' : '';
      summaryText =
          '${strings.formatAlertCount(status.alertCount, isUkrainian: isUkrainian)}$levelNote';
    }

    final bool isAlerted = !status.isClear;
    final Color bgColor;
    final Color fgColor;
    if (status.isYellow) {
      bgColor = isDark ? const Color(0xFF5C4300) : const Color(0xFFFFE082);
      fgColor = isDark ? const Color(0xFFFFE082) : const Color(0xFF5D4000);
    } else if (isAlerted) {
      bgColor = scheme.errorContainer;
      fgColor = scheme.onErrorContainer;
    } else {
      bgColor = scheme.surfaceContainerHigh;
      fgColor = scheme.onSurface;
    }

    return Material(
      elevation: 4,
      color: bgColor,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAlerted
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline_rounded,
              size: 16,
              color: isAlerted ? fgColor : scheme.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '$oblastLabel · $summaryText',
                style: textTheme.labelMedium?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (status.isDefaultRegion) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  strings.defaultBadgeLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: isAlerted ? fgColor : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
