import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:m3x/m3x.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/alerts_mesh_service.dart';
import 'services/ukrainian_locations.dart';

/// Root state, localization, and M3x Mesh coordinator for the Alerts app.
///
/// Strictly UI-independent: never stores a `BuildContext` and bounds all
/// network/platform operations with explicit timeouts.
class AlertsEngine extends ChangeNotifier {
  static const String prefsIntroCompletedKey = 'alerts_intro_completed';
  static const String prefsDictKeyPrefix = 'alerts_dict_';
  static const Duration defaultAutoRefreshInterval = Duration(seconds: 15);

  final M3xMeshClient meshClient;
  final AlertsMeshService meshService;
  final Duration autoRefreshInterval;
  late final AnalyticsService logger;
  late final Dictionary dict;

  SharedPreferences? _prefs;
  final Map<String, dynamic> _dictMemoryFallback = <String, dynamic>{};

  bool _appStarted = false;
  bool _introCompleted = false;
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isForeground = true;
  bool _disposed = false;
  Timer? _pollTimer;
  String? _errorMessage;
  String _appVersionDisplay = M3x.versionDisplay;
  AlertsSnapshot? _snapshot;
  Future<void>? _initFuture;
  Future<void>? _headlessFuture;

  AlertsEngine({
    M3xMeshClient? meshClient,
    AlertsMeshService? meshService,
    this.autoRefreshInterval = defaultAutoRefreshInterval,
    String Function()? systemLocaleProvider,
  })  : meshClient = meshClient ?? M3xMeshClient(localAppId: AlertsMeshService.app),
        meshService = meshService ?? AlertsMeshService() {
    logger = AnalyticsService(notifyEngine: genericRefresh);
    dict = Dictionary(
      path: 'assets/translations',
      url: '',
      systemLocaleProvider: systemLocaleProvider,
      storage: CallbackDictionaryStorage(
        getFn: (key) =>
            _prefs?.get(_dictPrefKey(key)) ?? _dictMemoryFallback[key],
        putFn: (key, val) async {
          _dictMemoryFallback[key] = val;
          final prefs = _prefs ??= await SharedPreferences.getInstance();
          if (val == null) {
            await prefs.remove(_dictPrefKey(key));
          } else {
            await prefs.setString(_dictPrefKey(key), val.toString());
          }
        },
        deleteFn: (key) async {
          _dictMemoryFallback.remove(key);
          final prefs = _prefs ??= await SharedPreferences.getInstance();
          await prefs.remove(_dictPrefKey(key));
        },
        containsKeyFn: (key) {
          final prefs = _prefs;
          if (prefs != null) {
            return prefs.containsKey(_dictPrefKey(key));
          }
          return _dictMemoryFallback.containsKey(key);
        },
      ),
      onRemoteUpdated: genericRefresh,
    );
  }

  static String _dictPrefKey(String key) => '$prefsDictKeyPrefix$key';

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void genericRefresh() => _safeNotify();

  bool get appStarted => _appStarted;
  bool get introCompleted => _introCompleted;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  bool get isForeground => _isForeground;
  bool get isAutoRefreshActive => _pollTimer?.isActive ?? false;
  String? get errorMessage => _errorMessage;
  String get appVersionDisplay => _appVersionDisplay;
  String get appDescription => M3x.appDescription;
  String get changelogContent => M3x.changelogContent;
  Map<String, String> get dependencies => M3x.dependencies;

  /// Active language preference: `'system'` when following OS locale,
  /// or an explicit language code (e.g. `'en'`, `'uk'`).
  String get languagePreferenceMode =>
      dict.isSystemLanguage ? 'system' : dict.locale;

  String get workerOrigin => AlertsMeshService.fixedWorkerOrigin;
  String get workerUrl => AlertsMeshService.fixedWorkerUrl;
  String get defaultRegion => meshService.defaultRegion;
  UkrainianLocation? get defaultLocation => meshService.defaultLocation;
  String get defaultRegionDisplayName {
    final loc = defaultLocation;
    if (loc == null) return meshService.defaultRegion;
    return locationNameForLocale(loc);
  }

  bool get hasWorkerUrl => meshService.isConfigured;

  String? get lastUpdatedAt => _snapshot?.updatedAt;
  DateTime? get lastCheckedAt => _snapshot?.fetchedAt;
  bool get isStale => _snapshot?.stale ?? false;
  int get totalActive => _snapshot?.totalActive ?? 0;
  Map<String, int> get byType =>
      Map<String, int>.unmodifiable(_snapshot?.byType ?? const <String, int>{});
  List<String> get affectedOblasts =>
      List<String>.unmodifiable(_snapshot?.affectedOblasts ?? const <String>[]);
  List<AlertItem> get alerts =>
      List<AlertItem>.unmodifiable(_snapshot?.alerts ?? const <AlertItem>[]);
  List<AlertItem> get defaultLocationAlerts {
    final loc = defaultLocation;
    if (loc == null) return const <AlertItem>[];
    return alertsForLocation(loc);
  }

  bool get isDefaultLocationAlerted => defaultLocationAlerts.isNotEmpty;
  List<M3xTool> get registeredTools => meshClient.localRegistry.tools;

  /// Shorthand lookup into [dict].
  String t(String key) => dict.value(key);

  /// Returns the localized display name for a [UkrainianLocation] while
  /// preserving canonical Ukrainian identifiers in storage and mesh queries.
  String locationNameForLocale(UkrainianLocation loc) {
    return dict.locale == 'uk' ? loc.canonicalName : loc.englishName;
  }

  /// Returns the localized administrative tier label for [type].
  String locationTypeLabel(String type) {
    switch (type.trim().toLowerCase()) {
      case 'special_city':
        return dict.value('location_type_special_city');
      case 'oblast':
        return dict.value('location_type_oblast');
      case 'raion':
        return dict.value('location_type_raion');
      case 'city':
        return dict.value('location_type_city');
      case 'hromada':
        return dict.value('location_type_hromada');
      default:
        return type;
    }
  }

  /// Returns a localized secondary subtitle (parent oblast or admin tier)
  /// for a [UkrainianLocation].
  String locationSubtitleForLocale(UkrainianLocation loc) {
    if (loc.parentOblast != null) {
      final parentLoc =
          UkrainianLocations.findByCanonicalOrAlias(loc.parentOblast!);
      if (parentLoc != null) {
        return locationNameForLocale(parentLoc);
      }
      return loc.parentOblast!;
    }
    return locationTypeLabel(loc.type);
  }

  /// Returns a localized human-readable label for an alert `alert_type`.
  String alertTypeLabel(String rawType) {
    switch (rawType.trim().toLowerCase()) {
      case 'air_raid':
        return dict.value('type_air_raid');
      case 'artillery_shelling':
        return dict.value('type_artillery');
      case 'urban_fights':
        return dict.value('type_urban_fights');
      case 'chemical':
        return dict.value('type_chemical');
      case 'nuclear':
        return dict.value('type_nuclear');
      default:
        final cleaned = rawType.trim().replaceAll('_', ' ');
        if (cleaned.isEmpty) return dict.value('type_default');
        return cleaned[0].toUpperCase() + cleaned.substring(1);
    }
  }

  List<AlertItem> alertsForRegion(String query) {
    final snapshotAlerts = _snapshot?.alerts;
    if (snapshotAlerts == null || snapshotAlerts.isEmpty) {
      return const <AlertItem>[];
    }
    return List<AlertItem>.unmodifiable(
      snapshotAlerts.where((a) => AlertsMeshService.matchesRegion(a, query)),
    );
  }

  List<AlertItem> alertsForLocation(UkrainianLocation location) {
    final snapshotAlerts = _snapshot?.alerts;
    if (snapshotAlerts == null || snapshotAlerts.isEmpty) {
      return const <AlertItem>[];
    }
    return List<AlertItem>.unmodifiable(
      snapshotAlerts.where((a) => AlertsMeshService.matchesLocation(a, location)),
    );
  }

  /// Full foreground initialization.
  ///
  /// Loads local preferences, translations, cached alert snapshot, and M3x
  /// metadata before triggering a non-blocking remote alert refresh.
  Future<void> init() {
    return _initFuture ??= _performInit();
  }

  Future<void> _performInit() async {
    _isLoading = true;
    _safeNotify();

    try {
      _prefs = await SharedPreferences.getInstance();
      _introCompleted = _prefs?.getBool(prefsIntroCompletedKey) ?? false;

      await meshService.init();
      _applySnapshot(meshService.cachedSnapshot);

      await dict.setup(backgroundRefresh: false);

      meshService.registerTools(meshClient);
      await meshClient.startListening();
      await meshClient.syncDeclaredTools();

      try {
        await M3x.init().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
      } catch (_) {
        // Safe fallback in headless/test environments without full asset bundles.
      }
      _appVersionDisplay = M3x.versionDisplay;

      _appStarted = true;
      _isLoading = false;
      logger.log(
        'Engine',
        'Info',
        'Initialized (${registeredTools.length} mesh tools, locale: ${dict.locale})',
      );
      _safeNotify();

      unawaited(refreshNow());
      if (_isForeground && !_disposed) {
        startAutoRefresh();
      }
    } catch (e) {
      _errorMessage = e.toString();
      _appStarted = true;
      _isLoading = false;
      logger.log('Engine', 'Error', 'Initialization failed: $e');
      _safeNotify();
    }
  }

  /// Lightweight headless startup for cold-start M3x Mesh ContentProvider calls.
  Future<void> startHeadlessForMesh() {
    return _headlessFuture ??= _performHeadlessInit();
  }

  Future<void> _performHeadlessInit() async {
    _prefs ??= await SharedPreferences.getInstance();
    await meshService.init();
    _applySnapshot(meshService.cachedSnapshot);

    meshService.registerTools(meshClient);
    await meshClient.startListening();
    await meshClient.syncDeclaredTools();

    _appStarted = true;
    logger.log(
      'Mesh',
      'Info',
      'Headless mesh host ready (${registeredTools.length} tools)',
    );
  }

  /// Switches the active dictionary language (`'en'`, `'uk'`, or `'system'` / `null`).
  Future<void> setLanguage(String? code) async {
    _prefs ??= await SharedPreferences.getInstance();
    final normalized = code?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty || normalized == 'system') {
      await dict.setSystemLanguage();
      logger.log(
        'Config',
        'Info',
        'Language set to system (${dict.locale})',
      );
    } else {
      await dict.setLanguage(normalized);
      logger.log(
        'Config',
        'Info',
        'Language set to ${dict.locale}',
      );
    }
    _safeNotify();
  }

  /// Marks the onboarding/disclaimer intro wizard as completed and persists it.
  Future<void> completeIntro() async {
    _prefs ??= await SharedPreferences.getInstance();
    _introCompleted = true;
    await _prefs!.setBool(prefsIntroCompletedKey, true);
    logger.log('Config', 'Info', 'Intro completed');
    _safeNotify();
  }

  /// Resets the intro wizard state so the user can replay setup & disclaimer.
  Future<void> resetIntro() async {
    _prefs ??= await SharedPreferences.getInstance();
    _introCompleted = false;
    await _prefs!.setBool(prefsIntroCompletedKey, false);
    logger.log('Config', 'Info', 'Intro reset');
    _safeNotify();
  }

  /// Starts or restarts periodic foreground polling using [autoRefreshInterval].
  void startAutoRefresh() {
    stopAutoRefresh();
    if (_disposed) return;
    _pollTimer = Timer.periodic(autoRefreshInterval, (_) {
      if (_isForeground && !_disposed && !_isRefreshing) {
        unawaited(refreshNow());
      }
    });
  }

  /// Cancels any active foreground polling timer.
  void stopAutoRefresh() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Updates the foreground lifecycle gate, pausing polling in the background
  /// and triggering an immediate refresh plus timer restart upon resume.
  void setForeground(bool foreground) {
    final wasForeground = _isForeground;
    _isForeground = foreground;
    if (!foreground) {
      stopAutoRefresh();
      return;
    }
    if (_appStarted && !_disposed) {
      startAutoRefresh();
      if (!wasForeground) {
        unawaited(refreshNow());
      }
    }
  }

  /// Forces a live fetch from the fixed Cloudflare Worker endpoint.
  Future<void> refreshNow() async {
    if (_isRefreshing || _disposed) return;

    _isRefreshing = true;
    _errorMessage = null;
    _safeNotify();

    try {
      final snapshot = await meshService.getSnapshot(forceRefresh: true);
      if (_disposed) return;
      _applySnapshot(snapshot);
      if (snapshot.error != null) {
        logger.log('Alerts', 'Warning', snapshot.error!);
      } else {
        logger.log(
          'Alerts',
          'Info',
          'Refreshed (${snapshot.totalActive} active alerts)',
        );
      }
    } catch (e) {
      if (!_disposed) {
        _errorMessage = e.toString();
        logger.log('Alerts', 'Error', 'Refresh failed: $e');
      }
    } finally {
      _isRefreshing = false;
      _safeNotify();
    }
  }

  /// Validates, canonicalizes, and persists the optional default region fallback
  /// used by `alerts_check_region`.
  ///
  /// Passing `null` or empty text clears the saved region and returns `true`.
  /// Passing an unrecognized location string (such as `'moon'`) rejects the
  /// change without persisting and returns `false`.
  Future<bool> setDefaultRegion(String? region) async {
    final accepted = await meshService.setDefaultRegion(region);
    if (!accepted) {
      logger.log(
        'Config',
        'Warning',
        'Rejected invalid default region: ${region?.trim() ?? ''}',
      );
      return false;
    }

    final saved = meshService.defaultRegion;
    logger.log(
      'Config',
      'Info',
      saved.isEmpty ? 'Default region cleared' : 'Default region set to $saved',
    );
    _safeNotify();
    return true;
  }

  void _applySnapshot(AlertsSnapshot? snapshot) {
    _snapshot = snapshot;
    _errorMessage = snapshot?.error;
  }

  @override
  void dispose() {
    _disposed = true;
    stopAutoRefresh();
    meshService.dispose();
    super.dispose();
  }
}
