import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:m3x_core/m3x_core.dart';
import 'package:m3x_ui/m3x_ui.dart';
import 'package:provider/provider.dart';

import '../engine.dart';
import '../services/alerts_mesh_service.dart';
import '../services/ukrainian_locations.dart';
import '../widgets/ukraine_map.dart';
import '../widgets/ukraine_map_data.dart';
import 'settings_page.dart';

/// Counts region severity segments (`red`, `yellow`, `clear`) from computed
/// [OblastMapStatus] entries across all 27 Ukraine map regions.
({int red, int yellow, int clear}) countOblastStatusSegments(
  List<OblastMapStatus> statuses,
) {
  int redCount = 0;
  int yellowCount = 0;
  int clearCount = 0;
  for (final status in statuses) {
    switch (status.status) {
      case OblastAlertStatus.red:
        redCount++;
      case OblastAlertStatus.yellow:
        yellowCount++;
      case OblastAlertStatus.clear:
        clearCount++;
    }
  }
  return (red: redCount, yellow: yellowCount, clear: clearCount);
}

/// Builds a horizontal Red → Yellow → Accent [LinearGradient] whose color stops
/// match the proportional share of [redCount], [yellowCount], and [clearCount]
/// oblasts, using narrow ~0.03 transition ramps at segment boundaries.
LinearGradient buildHeroStatusGradient({
  required ColorScheme colorScheme,
  required int redCount,
  required int yellowCount,
  required int clearCount,
}) {
  final bool isDark = colorScheme.brightness == Brightness.dark;
  final Color redTint = colorScheme.errorContainer.withValues(
    alpha: isDark ? 0.52 : 0.58,
  );
  final Color yellowTint = isDark
      ? const Color(0xFF5C4300).withValues(alpha: 0.65)
      : const Color(0xFFFFE082).withValues(alpha: 0.58);
  final Color accentTint = colorScheme.primaryContainer.withValues(
    alpha: isDark ? 0.48 : 0.55,
  );

  final int safeRed = math.max(0, redCount);
  final int safeYellow = math.max(0, yellowCount);
  final int safeClear = math.max(0, clearCount);
  final int total = safeRed + safeYellow + safeClear;

  if (total == 0 || (safeRed == 0 && safeYellow == 0)) {
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[accentTint, accentTint],
      stops: const <double>[0.0, 1.0],
    );
  }

  final List<({double fraction, Color color})> segments =
      <({double fraction, Color color})>[
    if (safeRed > 0) (fraction: safeRed / total, color: redTint),
    if (safeYellow > 0) (fraction: safeYellow / total, color: yellowTint),
    if (safeClear > 0) (fraction: safeClear / total, color: accentTint),
  ];

  if (segments.length == 1) {
    final Color single = segments.first.color;
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[single, single],
      stops: const <double>[0.0, 1.0],
    );
  }

  const double maxHalfRamp = 0.015;
  final List<Color> colors = <Color>[segments.first.color];
  final List<double> stops = <double>[0.0];

  double boundary = 0.0;
  for (int i = 0; i < segments.length - 1; i++) {
    final current = segments[i];
    final next = segments[i + 1];
    boundary += current.fraction;

    final double leftHalf = math.min(maxHalfRamp, current.fraction * 0.45);
    final double rightHalf = math.min(maxHalfRamp, next.fraction * 0.45);
    final double rampStart =
        math.max(stops.last, (boundary - leftHalf).clamp(0.0, 1.0));
    final double rampEnd =
        math.max(rampStart, (boundary + rightHalf).clamp(0.0, 1.0));

    colors.add(current.color);
    stops.add(rampStart);
    colors.add(next.color);
    stops.add(rampEnd);
  }

  colors.add(segments.last.color);
  stops.add(1.0);

  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: colors,
    stops: stops,
  );
}

Color _sampleLinearGradientAt(LinearGradient gradient, double t) {
  final colors = gradient.colors;
  if (colors.isEmpty) return Colors.transparent;
  if (colors.length == 1) return colors.first;

  final List<double> stops = gradient.stops != null &&
          gradient.stops!.length == colors.length
      ? gradient.stops!
      : List<double>.generate(
          colors.length,
          (i) => i / (colors.length - 1),
        );

  final double clamped = t.clamp(0.0, 1.0);
  if (clamped <= stops.first) return colors.first;
  if (clamped >= stops.last) return colors.last;

  for (int i = 0; i < stops.length - 1; i++) {
    final double s0 = stops[i];
    final double s1 = stops[i + 1];
    if (clamped <= s1) {
      if ((s1 - s0).abs() < 1e-6) return colors[i + 1];
      final double localT = (clamped - s0) / (s1 - s0);
      return Color.lerp(colors[i], colors[i + 1], localT)!;
    }
  }
  return colors.last;
}

/// Smoothly interpolates between two [LinearGradient]s even when they have
/// different stop counts (e.g. 2-stop Clear -> 6-stop Red+Yellow+Clear) by
/// resampling both gradients onto their unified sorted union of stops.
LinearGradient lerpHeroStatusGradient(
  LinearGradient a,
  LinearGradient b,
  double t,
) {
  final double clampedT = t.clamp(0.0, 1.0);
  if (clampedT <= 0.0) return a;
  if (clampedT >= 1.0) return b;

  List<double> stopsFor(LinearGradient g) {
    if (g.stops != null && g.stops!.length == g.colors.length) {
      return g.stops!;
    }
    if (g.colors.length <= 1) return const <double>[0.0, 1.0];
    return List<double>.generate(
      g.colors.length,
      (i) => i / (g.colors.length - 1),
    );
  }

  final rawStops = <double>[
    0.0,
    1.0,
    ...stopsFor(a),
    ...stopsFor(b),
  ]..sort();

  final unifiedStops = <double>[];
  for (final s in rawStops) {
    final clamped = s.clamp(0.0, 1.0);
    if (unifiedStops.isEmpty || (clamped - unifiedStops.last).abs() > 1e-5) {
      unifiedStops.add(clamped);
    }
  }
  if (unifiedStops.length == 1) {
    unifiedStops.add(1.0);
  } else {
    unifiedStops[0] = 0.0;
    unifiedStops[unifiedStops.length - 1] = 1.0;
  }

  final mergedColors = <Color>[
    for (final s in unifiedStops)
      Color.lerp(
        _sampleLinearGradientAt(a, s),
        _sampleLinearGradientAt(b, s),
        clampedT,
      )!,
  ];

  return LinearGradient(
    begin: AlignmentGeometry.lerp(a.begin, b.begin, clampedT) ??
        Alignment.centerLeft,
    end: AlignmentGeometry.lerp(a.end, b.end, clampedT) ??
        Alignment.centerRight,
    colors: mergedColors,
    stops: unifiedStops,
  );
}

bool _linearGradientsEqual(LinearGradient a, LinearGradient b) {
  if (identical(a, b)) return true;
  if (a.colors.length != b.colors.length) return false;
  for (int i = 0; i < a.colors.length; i++) {
    if (a.colors[i] != b.colors[i]) return false;
  }
  final aStops = a.stops;
  final bStops = b.stops;
  if (aStops == null && bStops == null) return true;
  if (aStops == null || bStops == null || aStops.length != bStops.length) {
    return false;
  }
  for (int i = 0; i < aStops.length; i++) {
    if ((aStops[i] - bStops[i]).abs() > 1e-5) return false;
  }
  return true;
}

/// Responsive Material 3 standalone dashboard for Ukraine Air Alerts.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin {
  static const double _maxContentWidth = 760;

  bool _isMapExpanded = false;
  String? _selectedOblastIso;

  final GlobalKey _bodyStackKey = GlobalKey();
  final GlobalKey _mapCardKey = GlobalKey();
  final GlobalKey _heroCardKey = GlobalKey();
  Rect? _capturedMapStartRect;
  Rect? _capturedHeroStartRect;
  Size? _capturedViewportSize;

  final ScrollController _scrollController = ScrollController();
  final TransformationController _mapTransformController =
      TransformationController();
  late final AnimationController _expandController;
  late final Animation<double> _expandAnimation;
  late final Animation<double> _fadeOutAnimation;
  late final AnimationController _gradientController;
  late final Animation<double> _gradientAnimation;

  late final Timer _clockTimer;
  final ValueNotifier<DateTime> _nowNotifier =
      ValueNotifier<DateTime>(DateTime.now());
  final ValueNotifier<bool> _overlayActiveNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _fullyExpandedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _mapInteractiveNotifier = ValueNotifier<bool>(false);

  LinearGradient? _fromGradient;
  LinearGradient? _toGradient;
  LinearGradient? _pendingGradient;
  bool _gradientFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeOutAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      _expandAnimation,
    );
    _expandAnimation.addListener(_onExpandAnimationTick);
    _expandController.addStatusListener(_onExpandStatusChanged);

    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _gradientAnimation = CurvedAnimation(
      parent: _gradientController,
      curve: Curves.easeInOutCubic,
    );

    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        _nowNotifier.value = DateTime.now();
      }
    });
  }

  @override
  void dispose() {
    _expandAnimation.removeListener(_onExpandAnimationTick);
    _expandController.removeStatusListener(_onExpandStatusChanged);
    _clockTimer.cancel();
    _nowNotifier.dispose();
    _overlayActiveNotifier.dispose();
    _fullyExpandedNotifier.dispose();
    _mapInteractiveNotifier.dispose();
    _expandController.dispose();
    _gradientController.dispose();
    _scrollController.dispose();
    _mapTransformController.dispose();
    super.dispose();
  }

  void _onExpandAnimationTick() {
    final double v = _expandAnimation.value;
    final bool overlayActive = v > 0.0;
    final bool fullyExpanded = v >= 1.0;
    if (_overlayActiveNotifier.value != overlayActive) {
      _overlayActiveNotifier.value = overlayActive;
    }
    if (_fullyExpandedNotifier.value != fullyExpanded) {
      _fullyExpandedNotifier.value = fullyExpanded;
    }
  }

  void _onExpandStatusChanged(AnimationStatus status) {
    final bool interactive =
        status == AnimationStatus.completed && _isMapExpanded;
    if (_mapInteractiveNotifier.value != interactive) {
      _mapInteractiveNotifier.value = interactive;
    }
  }

  LinearGradient _resolveAnimatedGradient(LinearGradient target) {
    if (_toGradient == null || _fromGradient == null) {
      _fromGradient = target;
      _toGradient = target;
      _gradientController.value = 1.0;
      return target;
    }

    final currentTarget = _pendingGradient ?? _toGradient!;
    if (!_linearGradientsEqual(currentTarget, target)) {
      _pendingGradient = target;
      if (!_gradientFrameScheduled) {
        _gradientFrameScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gradientFrameScheduled = false;
          if (!mounted || _pendingGradient == null) return;
          final next = _pendingGradient!;
          _pendingGradient = null;
          if (_linearGradientsEqual(_toGradient!, next)) return;
          _fromGradient = lerpHeroStatusGradient(
            _fromGradient!,
            _toGradient!,
            _gradientAnimation.value,
          );
          _toGradient = next;
          _gradientController.forward(from: 0.0);
        });
      }
    }

    return lerpHeroStatusGradient(
      _fromGradient!,
      _toGradient!,
      _gradientAnimation.value,
    );
  }

  Rect? _measureInBodyStack(GlobalKey key) {
    final stackObj = _bodyStackKey.currentContext?.findRenderObject();
    final itemObj = key.currentContext?.findRenderObject();
    if (stackObj is! RenderBox || itemObj is! RenderBox) return null;
    if (!stackObj.hasSize || !itemObj.hasSize) return null;
    final topLeft = itemObj.localToGlobal(Offset.zero, ancestor: stackObj);
    return topLeft & itemObj.size;
  }

  void _expandMap() {
    if (_isMapExpanded) return;
    final stackObj = _bodyStackKey.currentContext?.findRenderObject();
    _capturedViewportSize =
        stackObj is RenderBox && stackObj.hasSize ? stackObj.size : null;
    _capturedMapStartRect = _measureInBodyStack(_mapCardKey);
    _capturedHeroStartRect = _measureInBodyStack(_heroCardKey);
    _mapInteractiveNotifier.value = false;
    setState(() {
      _isMapExpanded = true;
      _selectedOblastIso = null;
    });
    _expandController.forward();
  }

  void _collapseMap() {
    if (!_isMapExpanded) return;
    _mapInteractiveNotifier.value = false;
    setState(() {
      _isMapExpanded = false;
      _selectedOblastIso = null;
      _mapTransformController.value = Matrix4.identity();
    });
    _expandController.reverse();
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AlertsEngine>(
      builder: (context, engine, _) {
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final bool isUkrainian = engine.dict.locale == 'uk';
        final List<AlertItem> alerts = engine.alerts;
        final List<String> affectedOblasts = engine.affectedOblasts;
        final String defaultRegion = engine.defaultRegion;
        final statuses = UkraineOblastsMap.computeStatuses(
          alerts: alerts,
          affectedOblasts: affectedOblasts,
          defaultRegion: defaultRegion,
        );
        final counts = countOblastStatusSegments(statuses);
        final List<MapEntry<String, int>> byTypeEntries =
            engine.byType.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
        final targetGradient = buildHeroStatusGradient(
          colorScheme: scheme,
          redCount: counts.red,
          yellowCount: counts.yellow,
          clearCount: counts.clear,
        );
        _resolveAnimatedGradient(targetGradient);
        final LinearGradient fromGrad = _fromGradient ?? targetGradient;
        final LinearGradient toGrad = _toGradient ?? targetGradient;

        return Scaffold(
          appBar: AppBar(
            surfaceTintColor: Colors.transparent,
            titleSpacing: 20,
            title: Text(
              engine.t('app_title'),
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              IconButton(
                tooltip: engine.t('settings'),
                onPressed: () => _openSettings(context),
                icon: const Icon(Icons.settings_rounded),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: IconButton(
                  tooltip: engine.isRefreshing
                      ? engine.t('refreshing')
                      : engine.t('refresh'),
                  onPressed:
                      engine.isRefreshing ? null : () => engine.refreshNow(),
                  icon: engine.isRefreshing
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: scheme.primary,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final bool isWide = constraints.maxWidth >= 680;
              final double compactHorizontalPad = isWide ? 24.0 : 0.0;
              final double compactContainerWidth = math.min(
                constraints.maxWidth - compactHorizontalPad * 2,
                _maxContentWidth,
              );
              final double compactCanvasWidth = math.max(
                120.0,
                compactContainerWidth - 30.0 - 28.0,
              );
              final double compactCanvasHeight = math.min(
                260.0,
                compactCanvasWidth / ukraineMapAspectRatio,
              );
              final double compactMapCardHeight = compactCanvasHeight + 28.0;

              final double bottomPadding = MediaQuery.paddingOf(context).bottom;
              final double loadingHeight = engine.isLoading ? 16.0 : 0.0;
              final double compactLeftMargin =
                  (constraints.maxWidth - compactContainerWidth) * 0.5 + 15.0;
              final double compactCardWidth = math.max(
                120.0,
                compactContainerWidth - 30.0,
              );

              final double expandedTop = 14.0 + loadingHeight;
              final double endLeft = isWide ? 24.0 : 15.0;
              final double endWidth = math.max(
                120.0,
                constraints.maxWidth - endLeft * 2,
              );
              const double stripHeight = 92.0;
              final double stripBottom =
                  constraints.maxHeight - bottomPadding - 12.0;
              final double stripTop = math.max(
                expandedTop + compactMapCardHeight + 10.0,
                stripBottom - stripHeight,
              );
              final Rect stripEndRect = Rect.fromLTWH(
                endLeft,
                stripTop,
                endWidth,
                stripHeight,
              );
              final Rect mapEndRect = Rect.fromLTWH(
                endLeft,
                expandedTop,
                endWidth,
                math.max(
                  compactMapCardHeight,
                  stripTop - 10.0 - expandedTop,
                ),
              );

              final double mapInnerMaxW = math.max(1.0, mapEndRect.width - 28.0);
              final double mapInnerMaxH = math.max(1.0, mapEndRect.height - 28.0);
              final double expandedCanvasW = math.min(
                mapInnerMaxW,
                mapInnerMaxH * ukraineMapAspectRatio,
              );
              final double expandedCanvasH =
                  expandedCanvasW / ukraineMapAspectRatio;
              final double fixedMapBoxW = expandedCanvasW + 28.0;
              final double fixedMapBoxH = expandedCanvasH + 28.0;

              final Widget compactBackground = ValueListenableBuilder<bool>(
                valueListenable: _fullyExpandedNotifier,
                builder: (context, fullyExpanded, child) {
                  return Offstage(
                    offstage: fullyExpanded,
                    child: child,
                  );
                },
                child: ValueListenableBuilder<bool>(
                  valueListenable: _overlayActiveNotifier,
                  builder: (context, overlayActive, child) {
                    return IgnorePointer(
                      ignoring: overlayActive,
                      child: child,
                    );
                  },
                  child: RefreshIndicator(
                    onRefresh: engine.refreshNow,
                    child: MotionBlurContainer(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.symmetric(
                          horizontal: compactHorizontalPad,
                          vertical: 12,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _maxContentWidth,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (engine.isLoading)
                                  FadeTransition(
                                    opacity: _fadeOutAnimation,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 15,
                                        vertical: 6,
                                      ),
                                      child: LinearProgressIndicator(),
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 15,
                                    vertical: 2,
                                  ),
                                  child: ValueListenableBuilder<bool>(
                                    valueListenable: _overlayActiveNotifier,
                                    builder: (context, overlayActive, child) {
                                      return Visibility(
                                        visible: !overlayActive,
                                        maintainSize: true,
                                        maintainAnimation: true,
                                        maintainState: true,
                                        child: child!,
                                      );
                                    },
                                    child: KeyedSubtree(
                                      key: _mapCardKey,
                                      child: Material(
                                        color: scheme.surfaceContainer,
                                        surfaceTintColor: scheme.primary,
                                        elevation: 3,
                                        borderRadius: BorderRadius.circular(20),
                                        clipBehavior: Clip.hardEdge,
                                        child: InkWell(
                                          onTap: _expandMap,
                                          child: SizedBox(
                                            height: compactMapCardHeight,
                                            width: double.infinity,
                                            child: UkraineOblastsMap(
                                              alerts: alerts,
                                              affectedOblasts: affectedOblasts,
                                              defaultRegion: defaultRegion,
                                              allowPolygonSelection: false,
                                              showOverlayChip: false,
                                              maxHeight: 260,
                                              isUkrainian: isUkrainian,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 15,
                                    vertical: 2,
                                  ),
                                  child: ValueListenableBuilder<bool>(
                                    valueListenable: _overlayActiveNotifier,
                                    builder: (context, overlayActive, child) {
                                      return Visibility(
                                        visible: !overlayActive,
                                        maintainSize: true,
                                        maintainAnimation: true,
                                        maintainState: true,
                                        child: child!,
                                      );
                                    },
                                    child: KeyedSubtree(
                                      key: _heroCardKey,
                                      child: _MorphingStatusCard(
                                        engine: engine,
                                        affectedOblasts: affectedOblasts,
                                        byTypeEntries: byTypeEntries,
                                        nowListenable: _nowNotifier,
                                        gradientAnimation: _gradientAnimation,
                                        fromGradient: fromGrad,
                                        toGradient: toGrad,
                                        hasRedAlerts: counts.red > 0,
                                        hasYellowAlerts: counts.yellow > 0,
                                        morphT: 0.0,
                                      ),
                                    ),
                                  ),
                                ),
                                FadeTransition(
                                  opacity: _fadeOutAnimation,
                                  child: RepaintBoundary(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Category.settings(
                                          title: engine.t('live_active_alerts'),
                                          context: context,
                                          trailing: _CountPill(
                                            label:
                                                '${engine.totalActive} ${engine.t('active_pill')}',
                                            highlighted:
                                                engine.totalActive > 0,
                                          ),
                                        ),
                                        _LiveAlertsSection(
                                          engine: engine,
                                          alerts: alerts,
                                          nowListenable: _nowNotifier,
                                        ),
                                        const SizedBox(height: 12),
                                        CardGroup(
                                          children: [
                                            CardContents.tapIcon(
                                              title:
                                                  engine.t('about_ukrzen_title'),
                                              subtitle:
                                                  engine.t('about_ukrzen_body'),
                                              icon: Icons.info_outline_rounded,
                                              color:
                                                  scheme.onSecondaryContainer,
                                              colorBG:
                                                  scheme.secondaryContainer,
                                              trailing: Icon(
                                                Icons.chevron_right_rounded,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                              action: () =>
                                                  _openSettings(context),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 24),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );

              final Widget cachedExpandedMap = ValueListenableBuilder<bool>(
                valueListenable: _mapInteractiveNotifier,
                builder: (context, interactive, _) {
                  return RepaintBoundary(
                    child: SizedBox(
                      width: fixedMapBoxW,
                      height: fixedMapBoxH,
                      child: UkraineOblastsMap(
                        alerts: alerts,
                        affectedOblasts: affectedOblasts,
                        defaultRegion: defaultRegion,
                        allowPolygonSelection: interactive,
                        showOverlayChip: false,
                        maxHeight: null,
                        isUkrainian: isUkrainian,
                        selectedIsoCode:
                            interactive ? _selectedOblastIso : null,
                        onOblastSelected: (status) {
                          setState(() {
                            _selectedOblastIso = status?.polygon.isoCode;
                          });
                        },
                      ),
                    ),
                  );
                },
              );

              return SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                child: Stack(
                  key: _bodyStackKey,
                  fit: StackFit.expand,
                  children: [
                    compactBackground,
                    AnimatedBuilder(
                      animation: _expandAnimation,
                      child: cachedExpandedMap,
                      builder: (context, mapChild) {
                        final double t = _expandAnimation.value;
                        if (t <= 0.0) {
                          return const SizedBox.shrink();
                        }

                        final double scrollOffset =
                            _scrollController.hasClients
                                ? _scrollController.offset
                                : 0.0;
                        final double fallbackMapTop =
                            14.0 + loadingHeight - scrollOffset;
                        final Rect fallbackMapRect = Rect.fromLTWH(
                          compactLeftMargin,
                          fallbackMapTop,
                          compactCardWidth,
                          compactMapCardHeight,
                        );
                        final Rect fallbackHeroRect = Rect.fromLTWH(
                          compactLeftMargin,
                          fallbackMapTop + compactMapCardHeight + 10.0,
                          compactCardWidth,
                          148.0,
                        );

                        final bool sameViewport =
                            _capturedViewportSize != null &&
                                (_capturedViewportSize!.width -
                                            constraints.maxWidth)
                                        .abs() <
                                    0.5 &&
                                (_capturedViewportSize!.height -
                                            constraints.maxHeight)
                                        .abs() <
                                    0.5;
                        final Rect mapStartRect =
                            sameViewport && _capturedMapStartRect != null
                                ? _capturedMapStartRect!
                                : fallbackMapRect;
                        final Rect heroStartRect =
                            sameViewport && _capturedHeroStartRect != null
                                ? _capturedHeroStartRect!
                                : fallbackHeroRect;

                        final Rect currentMapRect = Rect.lerp(
                          mapStartRect,
                          mapEndRect,
                          t,
                        )!;
                        final Rect currentHeroRect = Rect.lerp(
                          heroStartRect,
                          stripEndRect,
                          t,
                        )!;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (engine.isLoading)
                              const Positioned(
                                top: 6,
                                left: 15,
                                right: 15,
                                child: LinearProgressIndicator(),
                              ),
                            Positioned.fromRect(
                              rect: currentMapRect,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _mapInteractiveNotifier,
                                builder: (context, interactive, child) {
                                  return _ExpandedMapCard(
                                    engine: engine,
                                    statuses: statuses,
                                    transformController:
                                        _mapTransformController,
                                    selectedIsoCode: _selectedOblastIso,
                                    interactive: interactive,
                                    cardSize: currentMapRect.size,
                                    mapChild: child!,
                                    onOblastSelected: (status) {
                                      setState(() {
                                        _selectedOblastIso =
                                            status?.polygon.isoCode;
                                      });
                                    },
                                  );
                                },
                                child: mapChild,
                              ),
                            ),
                            Positioned.fromRect(
                              rect: currentHeroRect,
                              child: _MorphingStatusCard(
                                engine: engine,
                                affectedOblasts: affectedOblasts,
                                byTypeEntries: byTypeEntries,
                                nowListenable: _nowNotifier,
                                gradientAnimation: _gradientAnimation,
                                fromGradient: fromGrad,
                                toGradient: toGrad,
                                hasRedAlerts: counts.red > 0,
                                hasYellowAlerts: counts.yellow > 0,
                                morphT: t,
                                onCollapseTap:
                                    t >= 0.95 ? _collapseMap : null,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

Color _withAlphaFactor(Color color, double factor) {
  final double clamped = factor.clamp(0.0, 1.0);
  if (clamped >= 1.0) return color;
  return color.withValues(alpha: (color.a * clamped).clamp(0.0, 1.0));
}

String _localizedRegionName(AlertsEngine engine, String rawName) {
  final trimmed = rawName.trim();
  if (trimmed.isEmpty) return engine.t('other_region');
  final loc = UkrainianLocations.findByCanonicalOrAlias(trimmed);
  if (loc != null) {
    return engine.locationNameForLocale(loc);
  }
  return trimmed;
}

String _formatActiveAlertsHeadline(AlertsEngine engine) {
  final int count = engine.totalActive;
  if (count <= 0) {
    return engine.t('status_all_clear_hero');
  }
  if (engine.dict.locale == 'uk') {
    final int mod100 = count % 100;
    final int mod10 = count % 10;
    if (mod10 == 1 && mod100 != 11) {
      return '$count ${engine.t('status_active_alerts_one')}';
    }
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return '$count активні тривоги';
    }
    return '$count ${engine.t('status_active_alerts_many')}';
  }
  return '$count ${count == 1 ? engine.t('status_active_alerts_one') : engine.t('status_active_alerts_many')}';
}

String _formatGroupAlertCount(AlertsEngine engine, int count) {
  if (engine.dict.locale == 'uk') {
    final int mod100 = count % 100;
    final int mod10 = count % 10;
    if (mod10 == 1 && mod100 != 11) {
      return '$count ${engine.t('alert_one')}';
    }
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return '$count тривоги';
    }
    return '$count ${engine.t('alert_many')}';
  }
  return '$count ${count == 1 ? engine.t('alert_one') : engine.t('alert_many')}';
}

String _formatLocalizedDuration(
  Duration d, {
  required bool isUkrainian,
  bool includeSeconds = true,
}) {
  if (!isUkrainian) {
    return PuzzakFormatters.formatDuration(
      d,
      includeSeconds: includeSeconds,
    );
  }
  final Duration absDuration = d.isNegative ? d.abs() : d;
  final int days = absDuration.inDays;
  final int hours = absDuration.inHours.remainder(24);
  final int minutes = absDuration.inMinutes.remainder(60);
  final int seconds = absDuration.inSeconds.remainder(60);

  final List<String> parts = <String>[];
  if (days > 0) {
    parts.add('$daysд');
  }
  if (hours > 0 || days > 0) {
    parts.add('$hoursгод');
  }
  if (minutes > 0 || hours > 0 || days > 0 || !includeSeconds) {
    parts.add('$minutesхв');
  }
  if (includeSeconds) {
    parts.add('$secondsс');
  }

  final String sign = d.isNegative ? '-' : '';
  return '$sign${parts.join(' ')}';
}

class _ExpandedMapCard extends StatelessWidget {
  final AlertsEngine engine;
  final List<OblastMapStatus> statuses;
  final TransformationController transformController;
  final String? selectedIsoCode;
  final bool interactive;
  final Size cardSize;
  final Widget mapChild;
  final ValueChanged<OblastMapStatus?> onOblastSelected;

  const _ExpandedMapCard({
    required this.engine,
    required this.statuses,
    required this.transformController,
    required this.selectedIsoCode,
    required this.interactive,
    required this.cardSize,
    required this.mapChild,
    required this.onOblastSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isUkrainian = engine.dict.locale == 'uk';

    OblastMapStatus? selectedStatus;
    if (interactive && selectedIsoCode != null) {
      for (final status in statuses) {
        if (status.polygon.isoCode == selectedIsoCode) {
          selectedStatus = status;
          break;
        }
      }
    }

    return Material(
      color: scheme.surfaceContainer,
      surfaceTintColor: scheme.primary,
      elevation: interactive ? 3.0 : 0.0,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InteractiveViewer(
            transformationController: transformController,
            panEnabled: interactive,
            scaleEnabled: interactive,
            minScale: 1.0,
            maxScale: 3.5,
            boundaryMargin: const EdgeInsets.all(48),
            child: SizedBox(
              width: cardSize.width,
              height: cardSize.height,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: mapChild,
                ),
              ),
            ),
          ),
          if (selectedStatus != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: OblastOverlayChip(
                    status: selectedStatus,
                    onClose: () => onOblastSelected(null),
                    isUkrainian: isUkrainian,
                    localizedOblastName: _localizedRegionName(
                      engine,
                      selectedStatus.polygon.ukName,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Unified morphing gradient status card that smoothly transitions between
/// the full dashboard hero card (`morphT == 0.0`) and the expanded-map bottom
/// header card (`morphT == 1.0`), preserving the exact `48x48` icon badge,
/// bold headline, and `Updated ... ago` subtitle row while smoothly collapsing
/// the extra body without creating any `Opacity` `saveLayer`s.
class _MorphingStatusCard extends StatelessWidget {
  final AlertsEngine engine;
  final List<String> affectedOblasts;
  final List<MapEntry<String, int>> byTypeEntries;
  final ValueListenable<DateTime> nowListenable;
  final Animation<double> gradientAnimation;
  final LinearGradient fromGradient;
  final LinearGradient toGradient;
  final bool hasRedAlerts;
  final bool hasYellowAlerts;
  final double morphT;
  final VoidCallback? onCollapseTap;

  const _MorphingStatusCard({
    required this.engine,
    required this.affectedOblasts,
    required this.byTypeEntries,
    required this.nowListenable,
    required this.gradientAnimation,
    required this.fromGradient,
    required this.toGradient,
    required this.hasRedAlerts,
    required this.hasYellowAlerts,
    required this.morphT,
    this.onCollapseTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final double t = morphT.clamp(0.0, 1.0);

    final bool isInitialLoading =
        engine.isLoading || (engine.isRefreshing && engine.lastUpdatedAt == null);
    final bool hasAlerts = engine.totalActive > 0;
    final bool isYellowOnly = hasAlerts && !hasRedAlerts && hasYellowAlerts;
    final bool isUpdating = engine.isLoading || engine.isRefreshing;

    final Color accentContainer;
    final Color onAccentContainer;
    if (isYellowOnly) {
      accentContainer = UkraineOblastsMap.yellowAlertColor;
      onAccentContainer = const Color(0xFF3E2700);
    } else if (hasAlerts) {
      accentContainer = UkraineOblastsMap.redAlertColor;
      onAccentContainer = Colors.white;
    } else {
      accentContainer = scheme.primaryContainer;
      onAccentContainer = scheme.onPrimaryContainer;
    }

    final EdgeInsetsGeometry contentPadding = EdgeInsets.lerp(
      const EdgeInsets.all(20),
      const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      t,
    )!;
    const double badgeSize = 48.0;
    const double badgeRadius = 14.0;
    const double iconSize = 26.0;
    const double iconGap = 14.0;

    final TextStyle heroTitleStyle = textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          height: 1.15,
          color: scheme.onSurface,
        ) ??
        TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          height: 1.15,
          color: scheme.onSurface,
        );

    final String heroHeadline = _formatActiveAlertsHeadline(engine);
    final double extrasAlpha = (1.0 - t / 0.75).clamp(0.0, 1.0);
    final double errorAlpha = (1.0 - t / 0.6).clamp(0.0, 1.0);
    final double chevronAlpha = ((t - 0.15) / 0.85).clamp(0.0, 1.0);

    final Widget headerTitleBlock;
    if (isInitialLoading) {
      headerTitleBlock = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            engine.t('status_checking'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          if (t < 0.75) ...[
            const SizedBox(height: 2),
            Text(
              '${engine.t('status_fetching')} ${engine.workerOrigin}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: _withAlphaFactor(
                  scheme.onSurfaceVariant,
                  extrasAlpha,
                ),
              ),
            ),
          ],
        ],
      );
    } else {
      headerTitleBlock = _LiveTimeBuilder(
        nowListenable: nowListenable,
        builder: (context, now) {
          final String updatedText = _formatUpdatedLabel(
            engine,
            engine.lastUpdatedAt,
            now,
            isUpdating: isUpdating,
          );
          final Widget headlineWidget = t > 0.0
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    heroHeadline,
                    maxLines: 1,
                    style: heroTitleStyle,
                  ),
                )
              : Text(heroHeadline, style: heroTitleStyle);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              headlineWidget,
              const SizedBox(height: 6),
              _TimestampLabel(
                icon: Icons.update_rounded,
                label: updatedText,
              ),
            ],
          );
        },
      );
    }

    final Widget leadingBadge = Container(
      width: badgeSize,
      height: badgeSize,
      decoration: BoxDecoration(
        color: accentContainer,
        borderRadius: BorderRadius.circular(badgeRadius),
      ),
      padding: isInitialLoading ? const EdgeInsets.all(12.0) : EdgeInsets.zero,
      child: isInitialLoading
          ? CircularProgressIndicator(
              strokeWidth: 2.5,
              color: onAccentContainer,
            )
          : Icon(
              hasAlerts
                  ? Icons.warning_amber_rounded
                  : Icons.verified_user_rounded,
              color: onAccentContainer,
              size: iconSize,
            ),
    );

    Widget bodyColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: contentPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: t > 0.35
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  leadingBadge,
                  const SizedBox(width: iconGap),
                  Expanded(child: headerTitleBlock),
                  if (t > 0.15)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 8),
                      child: Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 24,
                        color: _withAlphaFactor(
                          scheme.onSurfaceVariant,
                          chevronAlpha,
                        ),
                      ),
                    ),
                ],
              ),
              if (!isInitialLoading && t < 0.75)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (engine.isStale) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _withAlphaFactor(
                            scheme.tertiaryContainer,
                            extrasAlpha,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.history_toggle_off_rounded,
                              size: 16,
                              color: _withAlphaFactor(
                                scheme.onTertiaryContainer,
                                extrasAlpha,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              engine.t('status_stale_cached'),
                              style: textTheme.labelMedium?.copyWith(
                                color: _withAlphaFactor(
                                  scheme.onTertiaryContainer,
                                  extrasAlpha,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (byTypeEntries.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in byTypeEntries)
                            _AlertTypeChip(
                              type: entry.key,
                              label: engine.alertTypeLabel(entry.key),
                              count: entry.value,
                              alphaFactor: extrasAlpha,
                            ),
                        ],
                      ),
                    ],
                    if (affectedOblasts.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        '${engine.t('status_affected_oblasts')} (${affectedOblasts.length})',
                        style: textTheme.labelLarge?.copyWith(
                          color: _withAlphaFactor(
                            scheme.onSurfaceVariant,
                            extrasAlpha,
                          ),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final oblast in affectedOblasts)
                            _OblastChip(
                              oblast: _localizedRegionName(engine, oblast),
                              isDefaultRegion: _oblastMatchesDefault(
                                oblast,
                                engine.defaultRegion,
                              ),
                              alphaFactor: extrasAlpha,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
        if (engine.errorMessage != null && t < 0.6)
          _InlineErrorBanner(
            message: engine.errorMessage!,
            onRetry: engine.isRefreshing ? null : () => engine.refreshNow(),
            retryLabel: engine.t('retry'),
            alphaFactor: errorAlpha,
          ),
      ],
    );

    if (t > 0.0) {
      bodyColumn = ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: 0,
          maxHeight: double.infinity,
          child: bodyColumn,
        ),
      );
    }

    final double cardElevation =
        (t > 0.0 && t < 1.0) ? 0.0 : (t >= 1.0 ? 2.0 : 3.0);
    final Color borderColor = scheme.outlineVariant.withValues(
      alpha: ui.lerpDouble(0.2, 0.4, t)!,
    );

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: gradientAnimation,
        child: bodyColumn,
        builder: (context, child) {
          final LinearGradient activeGradient = lerpHeroStatusGradient(
            fromGradient,
            toGradient,
            gradientAnimation.value,
          );
          return Material(
            color: scheme.surfaceContainer,
            surfaceTintColor: scheme.primary,
            elevation: cardElevation,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onCollapseTap,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: activeGradient,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: borderColor),
                ),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  static bool _oblastMatchesDefault(String oblast, String defaultRegion) {
    if (defaultRegion.trim().isEmpty) return false;
    return AlertsMeshService.matchesRegion(
      AlertItem(
        id: oblast,
        locationTitle: oblast,
        locationOblast: oblast,
        locationType: '',
        alertType: 'air_raid',
      ),
      defaultRegion,
    );
  }
}

class _InlineErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final double alphaFactor;

  const _InlineErrorBanner({
    required this.message,
    required this.onRetry,
    required this.retryLabel,
    this.alphaFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final Color fgColor = _withAlphaFactor(scheme.onErrorContainer, alphaFactor);

    return Container(
      color: _withAlphaFactor(
        scheme.errorContainer.withValues(alpha: 0.72),
        alphaFactor,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: fgColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: fgColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: fgColor,
            ),
            child: Text(retryLabel),
          ),
        ],
      ),
    );
  }
}

class _LiveTimeBuilder extends StatelessWidget {
  final ValueListenable<DateTime> nowListenable;
  final Widget Function(BuildContext context, DateTime now) builder;

  const _LiveTimeBuilder({
    required this.nowListenable,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: nowListenable,
      builder: (context, now, _) => builder(context, now),
    );
  }
}

String _formatUpdatedLabel(
  AlertsEngine engine,
  String? raw,
  DateTime now, {
  required bool isUpdating,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return isUpdating
        ? engine.t('status_updated_updating')
        : engine.t('status_updated_pending');
  }
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) {
    return '${engine.t('status_updated_prefix')}: ${raw.trim()}';
  }
  final elapsed = _nonNegativeElapsed(now.difference(parsed.toLocal()));
  final formatted = _formatLocalizedDuration(
    elapsed,
    isUkrainian: engine.dict.locale == 'uk',
    includeSeconds: elapsed.inHours == 0,
  );
  return '${engine.t('status_updated_prefix')} $formatted ${engine.t('status_updated_ago_suffix')}';
}

class _OblastAlertGroup {
  final String key;
  final String title;
  final List<AlertItem> alerts;
  final bool isDefaultMatch;
  final bool hasRed;
  final bool hasYellow;

  const _OblastAlertGroup({
    required this.key,
    required this.title,
    required this.alerts,
    required this.isDefaultMatch,
    required this.hasRed,
    required this.hasYellow,
  });

  bool get isYellowOnly => !hasRed && hasYellow;
}

class _LiveAlertsSection extends StatefulWidget {
  final AlertsEngine engine;
  final List<AlertItem> alerts;
  final ValueListenable<DateTime> nowListenable;

  const _LiveAlertsSection({
    required this.engine,
    required this.alerts,
    required this.nowListenable,
  });

  @override
  State<_LiveAlertsSection> createState() => _LiveAlertsSectionState();
}

class _LiveAlertsSectionState extends State<_LiveAlertsSection> {
  final Set<String> _expandedKeys = <String>{};

  void _toggleGroup(String key) {
    setState(() {
      if (!_expandedKeys.add(key)) {
        _expandedKeys.remove(key);
      }
    });
  }

  static String _normalizeOblastKey(String value) {
    return value
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll('`', "'")
        .replaceAll(RegExp(r'[\s_]+'), ' ')
        .trim();
  }

  static String _resolveGroupOblast(AlertItem alert, AlertsEngine engine) {
    final kyivCity = UkrainianLocations.findByCanonicalOrAlias(
      UkrainianLocations.kyivCityCanonical,
    );
    if (kyivCity != null &&
        AlertsMeshService.matchesLocation(alert, kyivCity)) {
      return UkrainianLocations.kyivCityCanonical;
    }

    final sevastopolCity = UkrainianLocations.findByCanonicalOrAlias(
      UkrainianLocations.sevastopolCityCanonical,
    );
    if (sevastopolCity != null &&
        AlertsMeshService.matchesLocation(alert, sevastopolCity)) {
      return UkrainianLocations.sevastopolCityCanonical;
    }

    if (alert.locationOblast.trim().isNotEmpty) {
      return alert.locationOblast.trim();
    }
    if (alert.locationTitle.trim().isNotEmpty) {
      return alert.locationTitle.trim();
    }
    return engine.t('other_region');
  }

  static List<_OblastAlertGroup> _groupAlerts(
    List<AlertItem> alerts,
    AlertsEngine engine,
  ) {
    final Map<String, List<AlertItem>> buckets = <String, List<AlertItem>>{};
    final Map<String, String> titles = <String, String>{};
    final Map<String, bool> defaultMatches = <String, bool>{};
    final Map<String, bool> hasRedMap = <String, bool>{};
    final Map<String, bool> hasYellowMap = <String, bool>{};

    final String trimmedDefault = engine.defaultRegion.trim();

    for (final alert in alerts) {
      final String rawOblast = _resolveGroupOblast(alert, engine);
      final String key = _normalizeOblastKey(rawOblast);

      buckets.putIfAbsent(key, () => <AlertItem>[]).add(alert);
      titles.putIfAbsent(
        key,
        () => _localizedRegionName(engine, rawOblast),
      );

      final bool matchesDefault = trimmedDefault.isNotEmpty &&
          AlertsMeshService.matchesRegion(alert, trimmedDefault);
      if (matchesDefault) {
        defaultMatches[key] = true;
      }

      final bool isYellow = alert.alertLevel?.trim().toLowerCase() == 'yellow';
      if (isYellow) {
        hasYellowMap[key] = true;
      } else {
        hasRedMap[key] = true;
      }
    }

    final List<_OblastAlertGroup> groups = buckets.entries.map((entry) {
      final String key = entry.key;
      final List<AlertItem> sortedItems = List<AlertItem>.from(entry.value)
        ..sort((a, b) {
          final bool aYellow = a.alertLevel?.trim().toLowerCase() == 'yellow';
          final bool bYellow = b.alertLevel?.trim().toLowerCase() == 'yellow';
          if (aYellow != bYellow) return aYellow ? 1 : -1;
          return a.locationTitle
              .toLowerCase()
              .compareTo(b.locationTitle.toLowerCase());
        });

      return _OblastAlertGroup(
        key: key,
        title: titles[key]!,
        alerts: sortedItems,
        isDefaultMatch: defaultMatches[key] ?? false,
        hasRed: hasRedMap[key] ?? false,
        hasYellow: hasYellowMap[key] ?? false,
      );
    }).toList();

    groups.sort((a, b) {
      if (a.isDefaultMatch != b.isDefaultMatch) {
        return a.isDefaultMatch ? -1 : 1;
      }
      if (a.isYellowOnly != b.isYellowOnly) {
        return a.isYellowOnly ? 1 : -1;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final engine = widget.engine;
    final bool isInitialLoading =
        engine.isLoading || (engine.isRefreshing && engine.lastCheckedAt == null);

    if (widget.alerts.isEmpty) {
      if (isInitialLoading) {
        return CardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          engine.t('alerts_loading_title'),
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${engine.t('alerts_loading_subtitle')} ${engine.workerOrigin}',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }

      return CardGroup(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.check_circle_outline_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        engine.t('alerts_none_active'),
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        engine.errorMessage != null
                            ? engine.t('alerts_none_error_subtitle')
                            : engine.t('alerts_none_subtitle'),
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final List<_OblastAlertGroup> groups = _groupAlerts(widget.alerts, engine);

    return CardGroup(
      children: [
        for (final group in groups)
          _ExpandableOblastCard(
            engine: engine,
            group: group,
            isExpanded: _expandedKeys.contains(group.key),
            nowListenable: widget.nowListenable,
            onToggle: () => _toggleGroup(group.key),
          ),
      ],
    );
  }
}

class _ExpandableOblastCard extends StatelessWidget {
  final AlertsEngine engine;
  final _OblastAlertGroup group;
  final bool isExpanded;
  final ValueListenable<DateTime> nowListenable;
  final VoidCallback onToggle;

  const _ExpandableOblastCard({
    required this.engine,
    required this.group,
    required this.isExpanded,
    required this.nowListenable,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    final Color amberBg =
        isDark ? const Color(0xFF5C4300) : const Color(0xFFFFE082);
    final Color amberFg =
        isDark ? const Color(0xFFFFE082) : const Color(0xFF5D4000);

    final Color badgeBg = group.isYellowOnly
        ? UkraineOblastsMap.yellowAlertColor
        : UkraineOblastsMap.redAlertColor;
    final Color badgeFg =
        group.isYellowOnly ? const Color(0xFF3E2700) : Colors.white;
    final Color pillBg = group.isYellowOnly ? amberBg : scheme.errorContainer;
    final Color pillFg = group.isYellowOnly ? amberFg : scheme.onErrorContainer;

    final int count = group.alerts.length;
    final String countLabel = _formatGroupAlertCount(engine, count);

    return Container(
      color: group.isDefaultMatch
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: badgeFg,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          group.title,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (group.isDefaultMatch)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              engine.t('map_chip_default_badge'),
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: pillBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      countLabel,
                      style: textTheme.labelSmall?.copyWith(
                        color: pillFg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final alert in group.alerts) ...[
                        Divider(
                          height: 1,
                          indent: 18,
                          endIndent: 18,
                          color: scheme.outlineVariant.withValues(alpha: 0.35),
                        ),
                        _NestedAlertItem(
                          engine: engine,
                          alert: alert,
                          fallbackTitle: group.title,
                          nowListenable: nowListenable,
                        ),
                      ],
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _NestedAlertItem extends StatelessWidget {
  final AlertsEngine engine;
  final AlertItem alert;
  final String fallbackTitle;
  final ValueListenable<DateTime> nowListenable;

  const _NestedAlertItem({
    required this.engine,
    required this.alert,
    required this.fallbackTitle,
    required this.nowListenable,
  });

  String _localizedLocationLabel() {
    final bool isUk = engine.dict.locale == 'uk';
    final String rawTitle = alert.locationTitle.trim();
    if (!isUk) {
      final enTitle = alert.locationTitleEn?.trim();
      if (enTitle != null && enTitle.isNotEmpty) {
        return enTitle;
      }
      if (rawTitle.isNotEmpty) {
        final loc = UkrainianLocations.findByCanonicalOrAlias(rawTitle);
        if (loc != null) {
          return engine.locationNameForLocale(loc);
        }
      }
    }
    return rawTitle.isNotEmpty ? rawTitle : fallbackTitle;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final bool isUk = engine.dict.locale == 'uk';

    final bool isStandardAirRaid =
        alert.alertType.trim().toLowerCase() == 'air_raid';
    final String readableType = engine.alertTypeLabel(alert.alertType);
    final bool isYellow = alert.alertLevel?.trim().toLowerCase() == 'yellow';

    final Color amberBg =
        isDark ? const Color(0xFF5C4300) : const Color(0xFFFFE082);
    final Color amberFg =
        isDark ? const Color(0xFFFFE082) : const Color(0xFF5D4000);

    final Color iconBg = isYellow
        ? UkraineOblastsMap.yellowAlertColor
        : UkraineOblastsMap.redAlertColor;
    final Color iconFg =
        isYellow ? const Color(0xFF3E2700) : Colors.white;

    final String locationLabel = _localizedLocationLabel();

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 11, 18, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              _alertTypeIcon(alert.alertType),
              size: 16,
              color: iconFg,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  locationLabel,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _LiveTimeBuilder(
                  nowListenable: nowListenable,
                  builder: (context, now) {
                    final String startedFormatted = _formatAlertStartTime(
                      alert.startedAt,
                      engine: engine,
                      now: now,
                    );
                    final bool hasMetaRow = !isStandardAirRaid ||
                        isYellow ||
                        startedFormatted.isNotEmpty;
                    if (!hasMetaRow) {
                      return const SizedBox.shrink();
                    }

                    return Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!isStandardAirRaid)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.errorContainer
                                    .withValues(alpha: 0.75),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                readableType,
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onErrorContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (isYellow)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: amberBg,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                isUk ? 'Жовтий рівень' : 'Yellow',
                                style: textTheme.labelSmall?.copyWith(
                                  color: amberFg,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (startedFormatted.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.access_time_rounded,
                                  size: 14,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  startedFormatted,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final String label;
  final bool highlighted;

  const _CountPill({
    required this.label,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: highlighted
            ? scheme.errorContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: highlighted
              ? scheme.onErrorContainer
              : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TimestampLabel extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TimestampLabel({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final Color fgColor = scheme.onSurfaceVariant;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fgColor),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(
              color: fgColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _AlertTypeChip extends StatelessWidget {
  final String type;
  final String label;
  final int count;
  final double alphaFactor;

  const _AlertTypeChip({
    required this.type,
    required this.label,
    required this.count,
    this.alphaFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _withAlphaFactor(
          scheme.surfaceContainerLowest.withValues(alpha: 0.75),
          alphaFactor,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _withAlphaFactor(
            scheme.outlineVariant.withValues(alpha: 0.6),
            alphaFactor,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _alertTypeIcon(type),
            size: 15,
            color: _withAlphaFactor(
              UkraineOblastsMap.redAlertColor,
              alphaFactor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$label: $count',
            style: textTheme.labelMedium?.copyWith(
              color: _withAlphaFactor(scheme.onSurface, alphaFactor),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _OblastChip extends StatelessWidget {
  final String oblast;
  final bool isDefaultRegion;
  final double alphaFactor;

  const _OblastChip({
    required this.oblast,
    required this.isDefaultRegion,
    this.alphaFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: _withAlphaFactor(
          isDefaultRegion
              ? scheme.primary
              : scheme.surfaceContainerLowest.withValues(alpha: 0.7),
          alphaFactor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        oblast,
        style: textTheme.labelSmall?.copyWith(
          color: _withAlphaFactor(
            isDefaultRegion ? scheme.onPrimary : scheme.onSurface,
            alphaFactor,
          ),
          fontWeight: isDefaultRegion ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

IconData _alertTypeIcon(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'air_raid':
      return Icons.campaign_rounded;
    case 'artillery_shelling':
      return Icons.crisis_alert_rounded;
    case 'urban_fights':
      return Icons.shield_rounded;
    case 'chemical':
      return Icons.science_rounded;
    case 'nuclear':
      return Icons.dangerous_rounded;
    default:
      return Icons.warning_amber_rounded;
  }
}

Duration _nonNegativeElapsed(Duration d) => d.isNegative ? Duration.zero : d;

String _formatAlertStartTime(
  String? raw, {
  required AlertsEngine engine,
  DateTime? now,
}) {
  if (raw == null || raw.trim().isEmpty) return '';
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw.trim();

  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final dateTimeStr =
      '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';

  final elapsed = _nonNegativeElapsed((now ?? DateTime.now()).difference(local));
  final durationStr = _formatLocalizedDuration(
    elapsed,
    isUkrainian: engine.dict.locale == 'uk',
    includeSeconds: elapsed.inMinutes < 1,
  );
  return '$dateTimeStr · $durationStr ${engine.t('status_updated_ago_suffix')}';
}
