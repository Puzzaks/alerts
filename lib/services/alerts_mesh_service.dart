import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:m3x_mesh/m3x_mesh.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ukrainian_locations.dart';

/// Compact representation of a single active civil defense / air raid alert.
class AlertItem {
  final String id;
  final String locationTitle;
  final String? locationTitleEn;
  final String locationOblast;
  final String? locationRaion;
  final String locationType;
  final String alertType;
  final String? alertLevel;
  final String? startedAt;
  final String? updatedAt;

  const AlertItem({
    required this.id,
    required this.locationTitle,
    required this.locationOblast,
    required this.locationType,
    required this.alertType,
    this.locationTitleEn,
    this.locationRaion,
    this.alertLevel,
    this.startedAt,
    this.updatedAt,
  });

  factory AlertItem.fromJson(Map<String, dynamic> json) {
    String pickString(List<String> keys) {
      for (final key in keys) {
        final val = json[key];
        if (val != null) {
          final str = val.toString().trim();
          if (str.isNotEmpty) return str;
        }
      }
      return '';
    }

    String? pickNullableString(List<String> keys) {
      final str = pickString(keys);
      return str.isEmpty ? null : str;
    }

    final location = pickString(const [
      'location',
      'location_title',
      'title',
      'region',
      'name',
    ]);
    final locationEn = pickNullableString(const [
      'location_title_en',
      'title_en',
    ]);
    final oblast = pickString(const [
      'oblast',
      'location_oblast',
      'region_oblast',
      'parent_region',
    ]);
    final raion = pickNullableString(const [
      'location_raion',
      'raion',
    ]);
    final locType = pickString(const [
      'location_type',
      'type_location',
    ]);
    final type = pickString(const [
      'type',
      'alert_type',
    ]);
    final level = pickNullableString(const [
      'alert_level',
      'level',
    ])?.toLowerCase();
    final id = pickString(const [
      'id',
      'location_uid',
      'uid',
    ]);

    return AlertItem(
      id: id.isNotEmpty ? id : '$location|$oblast|$type',
      locationTitle: location.isNotEmpty ? location : oblast,
      locationTitleEn: locationEn,
      locationOblast: oblast,
      locationRaion: raion,
      locationType: locType,
      alertType: type.isNotEmpty ? type : 'air_raid',
      alertLevel: level,
      startedAt: pickNullableString(const ['started_at', 'startedAt', 'created_at']),
      updatedAt: pickNullableString(const ['updated_at', 'updatedAt']),
    );
  }

  /// Full JSON representation of an [AlertItem].
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'location_title': locationTitle,
        if (locationTitleEn != null && locationTitleEn!.isNotEmpty)
          'location_title_en': locationTitleEn,
        if (locationOblast.isNotEmpty) 'location_oblast': locationOblast,
        if (locationRaion != null && locationRaion!.isNotEmpty)
          'location_raion': locationRaion,
        if (locationType.isNotEmpty) 'location_type': locationType,
        'alert_type': alertType,
        if (alertLevel != null && alertLevel!.isNotEmpty) 'alert_level': alertLevel,
        if (startedAt != null && startedAt!.isNotEmpty) 'started_at': startedAt,
        if (updatedAt != null && updatedAt!.isNotEmpty) 'updated_at': updatedAt,
      };

  /// Token-budgeted map suitable for Gemini Nano / M3x Mesh responses.
  Map<String, dynamic> toCompactJson() => <String, dynamic>{
        'location': locationTitle,
        if (locationOblast.isNotEmpty) 'oblast': locationOblast,
        if (locationRaion != null && locationRaion!.isNotEmpty)
          'raion': locationRaion,
        'type': alertType,
        if (alertLevel != null && alertLevel!.isNotEmpty) 'alert_level': alertLevel,
        if (locationType.isNotEmpty) 'location_type': locationType,
        if (startedAt != null && startedAt!.isNotEmpty) 'started_at': startedAt,
      };
}

/// Parsed snapshot of active alerts with freshness metadata.
class AlertsSnapshot {
  final List<AlertItem> alerts;
  final String? updatedAt;
  final DateTime fetchedAt;
  final bool stale;
  final String? error;

  const AlertsSnapshot({
    required this.alerts,
    required this.fetchedAt,
    this.updatedAt,
    this.stale = false,
    this.error,
  });

  int get totalActive => alerts.length;

  Map<String, int> get byType {
    final counts = <String, int>{};
    for (final alert in alerts) {
      final key = alert.alertType.isEmpty ? 'air_raid' : alert.alertType;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> get byLevel {
    final counts = <String, int>{};
    for (final alert in alerts) {
      final level = alert.alertLevel?.trim().toLowerCase();
      if (level != null && level.isNotEmpty) {
        counts[level] = (counts[level] ?? 0) + 1;
      }
    }
    return counts;
  }

  List<String> get affectedOblasts {
    final set = <String>{};
    for (final alert in alerts) {
      final name = alert.locationOblast.isNotEmpty
          ? alert.locationOblast
          : alert.locationTitle;
      if (name.isNotEmpty) {
        set.add(name);
      }
    }
    final list = set.toList()..sort();
    return list;
  }

  AlertsSnapshot copyWith({
    List<AlertItem>? alerts,
    String? updatedAt,
    DateTime? fetchedAt,
    bool? stale,
    String? error,
  }) {
    return AlertsSnapshot(
      alerts: alerts ?? this.alerts,
      updatedAt: updatedAt ?? this.updatedAt,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      stale: stale ?? this.stale,
      error: error ?? this.error,
    );
  }
}

/// Diagnostic result returned by [AlertsMeshService.testConnection].
class AlertsConnectionTestResult {
  final bool ok;
  final int? statusCode;
  final int alertCount;
  final int latencyMs;
  final String message;
  final AlertsSnapshot? snapshot;

  const AlertsConnectionTestResult({
    required this.ok,
    required this.message,
    this.statusCode,
    this.alertCount = 0,
    this.latencyMs = 0,
    this.snapshot,
  });
}

/// Backend network, caching, bilingual region matching, and M3x Mesh tool host
/// for the `page.puzzak.alerts` extension.
class AlertsMeshService {
  static const String packageName = 'page.puzzak.alerts';
  static const String app = 'alerts';

  static const String fixedWorkerOrigin = 'https://alerts.puzzak.workers.dev/';
  static const String fixedWorkerUrl =
      'https://alerts.puzzak.workers.dev/v1/active.json';

  static const String prefsDefaultRegionKey = 'alerts_default_region';
  static const String prefsCachedPayloadKey = 'alerts_cached_payload';
  static const String prefsCachedFetchedAtKey = 'alerts_cached_fetched_at';

  static const Duration requestTimeout = Duration(seconds: 8);
  static const Duration cacheTtl = Duration(seconds: 8);

  /// Bilingual English <-> Ukrainian oblast & major city lookup groups
  /// used only as a fallback when a query is not in [UkrainianLocations].
  static const List<List<String>> _bilingualRegionGroups = <List<String>>[
    ['kharkiv', 'kharkov', 'харків', 'харківськ'],
    ['odesa', 'odessa', 'odes', 'одес', 'одеса', 'одеськ'],
    ['lviv', 'lvov', 'львів', 'львівськ'],
    ['dnipro', 'dnepr', 'dnipropetrovsk', 'дніпр', 'дніпро', 'дніпропетровськ', 'кривий ріг', 'kryvyi rih'],
    ['zaporizhzhia', 'zaporozhye', 'zaporizhia', 'запоріж', 'запоріжжя', 'запорізьк'],
    ['sumy', 'sumsk', 'суми', 'сумськ'],
    ['chernihiv', 'chernigov', 'чернігів', 'чернігівськ'],
    ['poltava', 'полтав', 'полтава', 'полтавськ', 'kremenchuk', 'кременчук'],
    ['mykolaiv', 'nikolaev', 'миколаїв', 'миколаївськ'],
    ['kherson', 'херсон', 'херсонськ'],
    ['donetsk', 'донецьк', 'донецька', 'kramatorsk', 'краматорськ', 'mariupol', 'маріуполь'],
    ['luhansk', 'lugansk', 'луганськ', 'луганська'],
    ['crimea', 'krym', 'крим', 'сімферополь', 'simferopol'],
    ['vinnytsia', 'vinnitsa', 'вінниц', 'вінниця', 'вінницьк'],
    ['zhytomyr', 'zhitomir', 'житомир', 'житомирськ'],
    ['cherkasy', 'cherkassy', 'черкас', 'черкаси', 'черкаськ'],
    ['kirovohrad', 'kirovograd', 'kropyvnytskyi', 'кіровоград', 'кіровоградськ', 'кропивницьк'],
    ['rivne', 'rovno', 'рівне', 'рівненськ'],
    ['volyn', 'lutsk', 'волин', 'волинь', 'волинськ', 'луцьк'],
    ['ternopil', 'тернопіл', 'тернопіль', 'тернопільськ'],
    ['ivano-frankivsk', 'ivano frankivsk', 'frankivsk', 'івано-франківськ', 'франківськ'],
    ['zakarpattia', 'transcarpathia', 'uzhhorod', 'uzhgorod', 'закарпат', 'закарпаття', 'ужгород'],
    ['chernivtsi', 'chernovtsi', 'чернівц', 'чернівці', 'чернівецьк'],
    ['khmelnytskyi', 'khmelnitsky', 'хмельниц', 'хмельницьк'],
  ];

  http.Client? _httpClient;
  final bool _ownsHttpClient;
  final DateTime Function() _now;
  final Uri _endpointUri;

  SharedPreferences? _prefs;
  String _defaultRegion = '';
  AlertsSnapshot? _cachedSnapshot;
  Future<AlertsSnapshot>? _inFlightFetch;
  List<M3xTool>? _loadedTools;

  AlertsMeshService({
    http.Client? httpClient,
    SharedPreferences? prefs,
    DateTime Function()? nowProvider,
    @visibleForTesting Uri? endpointUri,
  })  : _httpClient = httpClient,
        _ownsHttpClient = httpClient == null,
        _prefs = prefs,
        _now = nowProvider ?? DateTime.now,
        _endpointUri = endpointUri ?? Uri.parse(fixedWorkerUrl);

  http.Client get _client => _httpClient ??= http.Client();

  String get workerOrigin => fixedWorkerOrigin;
  String get workerUrl => fixedWorkerUrl;
  Uri get endpointUri => _endpointUri;
  String get defaultRegion => _defaultRegion;
  UkrainianLocation? get defaultLocation => _defaultRegion.isEmpty
      ? null
      : UkrainianLocations.findByCanonicalOrAlias(_defaultRegion);
  String get defaultRegionDisplayName =>
      defaultLocation?.englishName ?? _defaultRegion;
  bool get hasWorkerUrl => true;
  bool get isConfigured => true;
  AlertsSnapshot? get cachedSnapshot => _cachedSnapshot;

  /// Loads persisted default region (migrating legacy aliases such as
  /// `'Kyiv city'` -> `'м. Київ'` and discarding unrecognized values) and
  /// cached payload from [SharedPreferences].
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = (_prefs!.getString(prefsDefaultRegionKey) ?? '').trim();
    if (raw.isEmpty) {
      _defaultRegion = '';
    } else {
      final resolved = UkrainianLocations.findByCanonicalOrAlias(raw);
      if (resolved != null) {
        _defaultRegion = resolved.canonicalName;
        if (raw != resolved.canonicalName) {
          await _prefs!.setString(prefsDefaultRegionKey, _defaultRegion);
        }
      } else {
        _defaultRegion = '';
        await _prefs!.remove(prefsDefaultRegionKey);
      }
    }
    _loadPersistedCache();
    await _loadDeclaredToolsFromAsset();
  }

  /// Validates, canonicalizes, and persists the optional default location
  /// used by [checkRegion].
  ///
  /// Passing `null` or empty text clears the saved default location and returns
  /// `true`. Passing an unrecognized string (such as `'moon'`) leaves the
  /// stored preference unchanged and returns `false`.
  Future<bool> setDefaultRegion(String? region) async {
    _prefs ??= await SharedPreferences.getInstance();
    final trimmed = (region ?? '').trim();
    if (trimmed.isEmpty) {
      _defaultRegion = '';
      await _prefs!.remove(prefsDefaultRegionKey);
      return true;
    }

    final resolved = UkrainianLocations.findByCanonicalOrAlias(trimmed);
    if (resolved == null) {
      return false;
    }

    _defaultRegion = resolved.canonicalName;
    await _prefs!.setString(prefsDefaultRegionKey, _defaultRegion);
    return true;
  }

  /// Clears in-memory and persisted payload cache.
  Future<void> clearCache() async {
    _cachedSnapshot = null;
    if (_prefs != null) {
      await _prefs!.remove(prefsCachedPayloadKey);
      await _prefs!.remove(prefsCachedFetchedAtKey);
    }
  }

  void _loadPersistedCache() {
    if (_prefs == null) return;
    final rawJson = _prefs!.getString(prefsCachedPayloadKey);
    final fetchedAtIso = _prefs!.getString(prefsCachedFetchedAtKey);
    if (rawJson == null || rawJson.trim().isEmpty) return;

    final fetchedAt = fetchedAtIso != null ? DateTime.tryParse(fetchedAtIso) : null;
    try {
      _cachedSnapshot = parseWorkerPayload(
        rawJson,
        fetchedAt: fetchedAt ?? _now(),
        stale: true,
      );
    } catch (_) {
      // Ignore corrupt persisted cache.
    }
  }

  Future<void> _persistCache(String rawJson, DateTime fetchedAt) async {
    if (_prefs == null) return;
    await _prefs!.setString(prefsCachedPayloadKey, rawJson);
    await _prefs!.setString(prefsCachedFetchedAtKey, fetchedAt.toIso8601String());
  }

  /// Parses either `{ meta: {...}, alerts: [...] }` or raw `{ alerts: [...] }`.
  static AlertsSnapshot parseWorkerPayload(
    String rawBody, {
    required DateTime fetchedAt,
    bool stale = false,
  }) {
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object payload.');
    }

    final map = Map<String, dynamic>.from(decoded);
    final rawAlerts = map['alerts'];
    if (rawAlerts is! List) {
      throw const FormatException('Payload missing "alerts" array.');
    }

    final alerts = <AlertItem>[];
    for (final entry in rawAlerts) {
      if (entry is Map) {
        alerts.add(AlertItem.fromJson(Map<String, dynamic>.from(entry)));
      }
    }

    String? updatedAt;
    bool metaStale = stale;
    final rawMeta = map['meta'];
    if (rawMeta is Map) {
      final meta = Map<String, dynamic>.from(rawMeta);
      updatedAt = (meta['updated_at'] ??
              meta['last_updated_at'] ??
              meta['generated_at'] ??
              meta['timestamp'])
          ?.toString();
      if (meta['stale'] is bool && meta['stale'] == true) {
        metaStale = true;
      }
    }
    updatedAt ??= (map['updated_at'] ?? map['last_updated_at'])?.toString();

    return AlertsSnapshot(
      alerts: alerts,
      updatedAt: updatedAt,
      fetchedAt: fetchedAt,
      stale: metaStale,
    );
  }

  /// Returns an active alerts snapshot, reusing cached responses for [cacheTtl] (8s)
  /// and falling back to stale cache if offline or on Worker error.
  Future<AlertsSnapshot> getSnapshot({bool forceRefresh = false}) async {
    final now = _now();
    final cached = _cachedSnapshot;
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.fetchedAt) < cacheTtl &&
        cached.error == null) {
      return cached.copyWith(stale: false);
    }

    if (!forceRefresh && _inFlightFetch != null) {
      return _inFlightFetch!;
    }

    final future = _fetchAndCache();
    _inFlightFetch = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightFetch, future)) {
        _inFlightFetch = null;
      }
    }
  }

  Future<AlertsSnapshot> _fetchAndCache() async {
    try {
      final response = await _client.get(
        _endpointUri,
        headers: const <String, String>{
          'Accept': 'application/json',
        },
      ).timeout(requestTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpExceptionWithStatus(
          response.statusCode,
          'Worker returned HTTP ${response.statusCode}',
        );
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final fetchedAt = _now();
      final snapshot = parseWorkerPayload(
        body,
        fetchedAt: fetchedAt,
        stale: false,
      );
      _cachedSnapshot = snapshot;
      await _persistCache(body, fetchedAt);
      return snapshot;
    } catch (e) {
      final fallback = _cachedSnapshot;
      if (fallback != null) {
        return fallback.copyWith(
          stale: true,
          error: e.toString(),
        );
      }
      return AlertsSnapshot(
        alerts: const <AlertItem>[],
        fetchedAt: _now(),
        stale: true,
        error: e.toString(),
      );
    }
  }

  /// Performs a live uncached HTTP probe against the fixed Worker endpoint.
  Future<AlertsConnectionTestResult> testConnection() async {
    final sw = Stopwatch()..start();
    try {
      final response = await _client.get(
        _endpointUri,
        headers: const <String, String>{
          'Accept': 'application/json',
        },
      ).timeout(requestTimeout);
      sw.stop();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return AlertsConnectionTestResult(
          ok: false,
          statusCode: response.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          message: 'Worker returned HTTP ${response.statusCode}.',
        );
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final fetchedAt = _now();
      final snapshot = parseWorkerPayload(
        body,
        fetchedAt: fetchedAt,
        stale: false,
      );
      _cachedSnapshot = snapshot;
      await _persistCache(body, fetchedAt);

      return AlertsConnectionTestResult(
        ok: true,
        statusCode: response.statusCode,
        alertCount: snapshot.totalActive,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Connected (${snapshot.totalActive} active alerts, ${sw.elapsedMilliseconds}ms).',
        snapshot: snapshot,
      );
    } catch (e) {
      sw.stop();
      return AlertsConnectionTestResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Connection failed: $e',
      );
    }
  }

  /// Registers all 3 token-budgeted Alerts mesh tools into [client].
  void registerTools(M3xMeshClient client) {
    for (final tool in tools) {
      client.localRegistry.register(tool);
    }
  }

  Map<String, M3xToolHandler> get _toolHandlers => <String, M3xToolHandler>{
        'alerts_get_summary': getSummary,
        'alerts_check_region': checkRegion,
        'alerts_list_active': listActive,
      };

  /// Parses serialized MCP / OpenAPI tool definitions (e.g. `assets/mesh_tools.json`)
  /// using [M3xTool.fromJson] and attaches this service's executable handlers.
  List<M3xTool> toolsFromJsonString(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException('Expected a JSON array of mesh tool definitions.');
    }

    final handlers = _toolHandlers;
    final parsed = <M3xTool>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        throw const FormatException('Each mesh tool definition must be a JSON object.');
      }
      final map = Map<String, dynamic>.from(entry);
      final name = map['name']?.toString() ?? '';
      final handler = handlers[name];
      if (handler == null) {
        throw StateError("No handler registered for mesh tool '$name'.");
      }
      parsed.add(
        M3xTool.fromJson(
          map,
          handler: handler,
          app: map['app']?.toString() ?? app,
          packageName: map['packageName']?.toString() ?? packageName,
        ),
      );
    }
    return List<M3xTool>.unmodifiable(parsed);
  }

  Future<void> _loadDeclaredToolsFromAsset() async {
    try {
      final raw = await rootBundle.loadString('assets/mesh_tools.json');
      if (raw.trim().isNotEmpty) {
        _loadedTools = toolsFromJsonString(raw);
      }
    } catch (_) {
      // Fall back to built-in tool schemas when the asset bundle is unavailable.
    }
  }

  /// Declares the 3 MCP / OpenAPI tools exposed by `page.puzzak.alerts`.
  ///
  /// Uses schemas loaded from `assets/mesh_tools.json` when initialized with a
  /// Flutter asset bundle, falling back to [defaultTools] in pure-Dart tests.
  List<M3xTool> get tools => _loadedTools ?? defaultTools;

  static const Set<String> _nationwideQueries = <String>{
    'ukraine',
    'україна',
    'украина',
    'ua',
    'all',
    'nationwide',
    'everywhere',
    'всі',
    'усі',
  };

  static bool _isNationwideQuery(String query) {
    final cleaned = query
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');
    return _nationwideQueries.contains(cleaned);
  }

  /// Built-in fallback schemas mirroring `assets/mesh_tools.json`.
  @visibleForTesting
  List<M3xTool> get defaultTools => <M3xTool>[
        M3xTool(
          name: 'alerts_get_summary',
          app: app,
          packageName: packageName,
          description:
              'Returns a compact nationwide overview of Ukraine-wide air raid and civil defense alert status and counts (total active count, affected oblasts, breakdown by alert type, and last update timestamp).',
          parameters: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
          handler: getSummary,
        ),
        M3xTool(
          name: 'alerts_check_region',
          app: app,
          packageName: packageName,
          description:
              "Checks whether an air raid or civil defense alert is currently active in a specific Ukrainian oblast, raion, or city (e.g. 'Kyiv', 'Харків', 'Odesa'), or pass 'Ukraine' for a nationwide summary. Omit region to use the saved default region.",
          parameters: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'region': <String, dynamic>{
                'type': 'string',
                'description':
                    "Optional Ukrainian or English oblast, raion, or city name (e.g. 'Kyiv', 'Харків', 'Odesa'), or 'Ukraine' for a nationwide summary. Falls back to the saved default region if omitted.",
              },
            },
          },
          handler: checkRegion,
        ),
        M3xTool(
          name: 'alerts_list_active',
          app: app,
          packageName: packageName,
          description:
              'Returns a compact paginated list of currently active alerts in Ukraine, optionally filtered by alert_type.',
          parameters: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'alert_type': <String, dynamic>{
                'type': 'string',
                'enum': <String>[
                  'air_raid',
                  'artillery_shelling',
                  'urban_fights',
                  'chemical',
                  'nuclear',
                ],
                'description': 'Optional filter by alert type.',
              },
              'limit': <String, dynamic>{
                'type': 'integer',
                'description': 'Maximum number of alerts to return (default 10, clamped 1..15).',
              },
              'offset': <String, dynamic>{
                'type': 'integer',
                'description': 'Optional 0-based offset for pagination (default 0).',
              },
            },
          },
          handler: listActive,
        ),
      ];

  Map<String, dynamic> _buildSummaryPayload(AlertsSnapshot snapshot) {
    final affected = snapshot.affectedOblasts;
    final byLevel = snapshot.byLevel;
    final hasErrorWithoutData = snapshot.error != null && snapshot.alerts.isEmpty;

    return <String, dynamic>{
      'configured': true,
      'worker_url_set': true,
      'updated_at': snapshot.updatedAt,
      'last_checked_at': snapshot.fetchedAt.toIso8601String(),
      'stale': snapshot.stale,
      'total_active': snapshot.totalActive,
      'affected_oblasts': affected,
      'by_type': snapshot.byType,
      if (byLevel.isNotEmpty) 'by_level': byLevel,
      if (_defaultRegion.isNotEmpty) 'default_region': _defaultRegion,
      if (snapshot.error != null)
        'message': hasErrorWithoutData
            ? 'Failed to fetch alerts: ${snapshot.error}'
            : 'Using cached alerts because refresh failed: ${snapshot.error}'
      else if (snapshot.totalActive == 0)
        'message': 'No active alerts across Ukraine.',
    };
  }

  /// Tool 1: `alerts_get_summary`
  Future<Map<String, dynamic>> getSummary(Map<String, dynamic> args) async {
    final snapshot = await getSnapshot();
    return _buildSummaryPayload(snapshot);
  }

  /// Tool 2: `alerts_check_region`
  Future<Map<String, dynamic>> checkRegion(Map<String, dynamic> args) async {
    final rawArg = (args['region']?.toString() ?? '').trim();
    final effectiveQuery = rawArg.isNotEmpty ? rawArg : _defaultRegion.trim();

    if (effectiveQuery.isEmpty) {
      return <String, dynamic>{
        'configured': true,
        'query': '',
        'active': false,
        'match_count': 0,
        'matches': const <Map<String, dynamic>>[],
        'message':
            'No region specified and no default region is saved. Pass a region such as "м. Київ", "Київська область", or "Odesa Oblast".',
      };
    }

    if (_isNationwideQuery(effectiveQuery)) {
      final snapshot = await getSnapshot();
      final summary = _buildSummaryPayload(snapshot);
      return <String, dynamic>{
        ...summary,
        'query': effectiveQuery,
        'scope': 'nationwide',
        'active': snapshot.totalActive > 0,
        'match_count': snapshot.totalActive,
        'matches': snapshot.alerts.take(10).map((a) => a.toCompactJson()).toList(),
      };
    }

    final resolved = UkrainianLocations.findByCanonicalOrAlias(effectiveQuery);
    final snapshot = await getSnapshot();
    final allMatches = snapshot.alerts
        .where(
          (alert) => resolved != null
              ? matchesLocation(alert, resolved)
              : matchesRegion(alert, effectiveQuery),
        )
        .toList();
    final capped = allMatches.take(10).map((a) => a.toCompactJson()).toList();

    final normRaw = UkrainianLocations.normalizeKey(effectiveQuery);
    final isBareKyiv = normRaw == 'kyiv' || normRaw == 'kiev' || normRaw == 'київ';

    return <String, dynamic>{
      'configured': true,
      'query': effectiveQuery,
      if (resolved != null) 'resolved_location': resolved.canonicalName,
      if (resolved != null) 'resolved_location_en': resolved.englishName,
      'active': allMatches.isNotEmpty,
      'match_count': allMatches.length,
      'matches': capped,
      'updated_at': snapshot.updatedAt,
      'stale': snapshot.stale,
      if (snapshot.error != null)
        'message': 'Refresh warning: ${snapshot.error}'
      else if (isBareKyiv)
        'note':
            'Checked Kyiv City (м. Київ) only. Pass "Kyiv Oblast" or "Київська область" to check Київська область.',
    };
  }

  /// Tool 3: `alerts_list_active`
  Future<Map<String, dynamic>> listActive(Map<String, dynamic> args) async {
    final rawType = (args['alert_type']?.toString() ?? '').trim().toLowerCase();
    final parsedLimit = _parseIntArg(args['limit'], fallback: 10).clamp(1, 15);
    final parsedOffset = _parseIntArg(args['offset'], fallback: 0);
    final safeOffset = parsedOffset < 0 ? 0 : parsedOffset;

    final snapshot = await getSnapshot();
    final filtered = rawType.isEmpty
        ? snapshot.alerts
        : snapshot.alerts
            .where((a) => a.alertType.toLowerCase() == rawType)
            .toList();

    final slice = filtered.skip(safeOffset).take(parsedLimit).toList();
    final hasMore = safeOffset + slice.length < filtered.length;

    return <String, dynamic>{
      'configured': true,
      'total_active': snapshot.totalActive,
      if (rawType.isNotEmpty) 'filtered_total': filtered.length,
      'offset': safeOffset,
      'limit': parsedLimit,
      'returned': slice.length,
      'truncated': hasMore,
      'updated_at': snapshot.updatedAt,
      'stale': snapshot.stale,
      'alerts': slice.map((a) => a.toCompactJson()).toList(),
      if (snapshot.error != null) 'message': 'Refresh warning: ${snapshot.error}',
    };
  }

  static int _parseIntArg(dynamic raw, {required int fallback}) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  /// Normalizes a region string for fuzzy bilingual comparison.
  static String _normalizeRegionText(String input) =>
      UkrainianLocations.normalizeKey(input);

  static String _stripRegionNoise(String normalized) {
    return normalized
        .replaceAll(RegExp(r'\b(oblast|region|city|raion|district)\b'), ' ')
        .replaceAll(RegExp(r'(^|\s)(м\.|с\.|смт\.?)\s*'), ' ')
        .replaceAll(RegExp(r'\b(область|обл\.?|район|р-н|місто|громада)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isKyivCityAlert(AlertItem alert) {
    final title = _normalizeRegionText(alert.locationTitle);
    final titleEn = _normalizeRegionText(alert.locationTitleEn ?? '');
    final oblast = _normalizeRegionText(alert.locationOblast);
    return title == 'м. київ' ||
        title == 'київ' ||
        title == 'місто київ' ||
        oblast == 'м. київ' ||
        titleEn == 'kyiv city' ||
        titleEn == 'kyiv';
  }

  static bool _isSevastopolCityAlert(AlertItem alert) {
    final title = _normalizeRegionText(alert.locationTitle);
    final titleEn = _normalizeRegionText(alert.locationTitleEn ?? '');
    final oblast = _normalizeRegionText(alert.locationOblast);
    return title == 'м. севастополь' ||
        title == 'севастополь' ||
        title == 'місто севастополь' ||
        oblast == 'м. севастополь' ||
        titleEn == 'sevastopol city' ||
        titleEn == 'sevastopol';
  }

  /// Expands a query into bilingual English + Ukrainian matching tokens
  /// while keeping `м. Київ` strictly isolated from `Київська область` and
  /// `м. Севастополь` strictly isolated from `Автономна Республіка Крим`.
  static Set<String> expandRegionTerms(String query) {
    final norm = _normalizeRegionText(query);
    if (norm.isEmpty) return const <String>{};

    final resolved = UkrainianLocations.findByCanonicalOrAlias(norm);
    if (resolved != null) {
      if (resolved.canonicalName == UkrainianLocations.kyivCityCanonical) {
        return const <String>{'м. київ', 'kyiv city', 'місто київ'};
      }
      if (resolved.canonicalName == UkrainianLocations.kyivOblastCanonical) {
        return const <String>{
          'київська область',
          'київська',
          'київщина',
          'kyiv oblast',
          'kyivska',
          'kyivska oblast',
        };
      }
      if (resolved.canonicalName == UkrainianLocations.sevastopolCityCanonical) {
        return const <String>{
          'м. севастополь',
          'sevastopol city',
          'місто севастополь',
        };
      }
      if (resolved.canonicalName == UkrainianLocations.crimeaOblastCanonical) {
        return const <String>{
          'автономна республіка крим',
          'ар крим',
          'крим',
          'autonomous republic of crimea',
          'ar crimea',
          'crimea',
        };
      }

      final terms = <String>{
        _normalizeRegionText(resolved.canonicalName),
        _normalizeRegionText(resolved.baseCanonicalName),
        _normalizeRegionText(resolved.englishName),
        for (final alias in resolved.aliases) _normalizeRegionText(alias),
      }..removeWhere((t) => t.isEmpty);
      return terms;
    }

    final core = _stripRegionNoise(norm);
    final terms = <String>{norm};
    if (core.isNotEmpty) {
      terms.add(core);
    }

    for (final group in _bilingualRegionGroups) {
      final matched = group.any((alias) {
        if (norm.contains(alias) || (norm.length >= 3 && alias.contains(norm))) {
          return true;
        }
        if (core.isNotEmpty &&
            (core.contains(alias) || (core.length >= 3 && alias.contains(core)))) {
          return true;
        }
        return false;
      });
      if (matched) {
        terms.addAll(group);
      }
    }

    return terms;
  }

  /// Returns `true` when [alert] belongs to [location].
  ///
  /// Enforces strict administrative boundaries:
  /// - `'м. Київ'` matches only Kyiv City alerts and never Kyiv Oblast alerts.
  /// - `'Київська область'` matches Kyiv Oblast alerts and never `'м. Київ'`.
  /// - `'м. Севастополь'` and `'Автономна Республіка Крим'` are similarly isolated.
  /// - Raions and cities match alerts targeting them directly as well as
  ///   oblast-wide alerts for their `parentOblast`.
  static bool matchesLocation(AlertItem alert, UkrainianLocation location) {
    final title = _normalizeRegionText(alert.locationTitle);
    final titleEn = _normalizeRegionText(alert.locationTitleEn ?? '');
    final oblast = _normalizeRegionText(alert.locationOblast);
    final raion = _normalizeRegionText(alert.locationRaion ?? '');
    final locType = alert.locationType.trim().toLowerCase();

    if (location.canonicalName == UkrainianLocations.kyivCityCanonical) {
      return _isKyivCityAlert(alert);
    }
    if (location.canonicalName == UkrainianLocations.sevastopolCityCanonical) {
      return _isSevastopolCityAlert(alert);
    }
    if (location.canonicalName == UkrainianLocations.kyivOblastCanonical) {
      if (_isKyivCityAlert(alert)) return false;
      return oblast == 'київська область' ||
          title == 'київська область' ||
          titleEn == 'kyiv oblast';
    }
    if (location.canonicalName == UkrainianLocations.crimeaOblastCanonical) {
      if (_isSevastopolCityAlert(alert)) return false;
      return oblast == 'автономна республіка крим' ||
          title == 'автономна республіка крим' ||
          titleEn == 'autonomous republic of crimea';
    }

    final canon = _normalizeRegionText(location.canonicalName);
    final en = _normalizeRegionText(location.englishName);

    if (location.isOblast) {
      return oblast == canon || title == canon || titleEn == en;
    }

    if (_isKyivCityAlert(alert) || _isSevastopolCityAlert(alert)) {
      return false;
    }

    final parent = _normalizeRegionText(location.parentOblast ?? '');
    if (parent.isNotEmpty && oblast.isNotEmpty && oblast != parent) {
      return false;
    }

    if (parent.isNotEmpty &&
        (locType == 'oblast' || title == parent) &&
        (oblast == parent || title == parent)) {
      return true;
    }

    if (location.isRaion) {
      final candidates = <String>{
        canon,
        en,
        for (final alias in location.aliases) _normalizeRegionText(alias),
      }..removeWhere((c) => c.isEmpty);

      if (candidates.contains(title) ||
          candidates.contains(titleEn) ||
          (raion.isNotEmpty && candidates.contains(raion))) {
        return true;
      }
      final strippedCanon = _stripRegionNoise(canon);
      if (strippedCanon.isNotEmpty &&
          (title == '$strippedCanon район' || raion == '$strippedCanon район')) {
        return true;
      }
      return false;
    }

    // City or hromada: match exact location title / English title / aliases
    // within parentOblast.
    final baseCanon = _normalizeRegionText(location.baseCanonicalName);
    final strippedCity = baseCanon.startsWith('м. ')
        ? baseCanon.substring(3)
        : baseCanon;
    final candidates = <String>{
      baseCanon,
      strippedCity,
      en,
      if (en.endsWith(' city')) en.substring(0, en.length - 5),
      for (final alias in location.aliases) _normalizeRegionText(alias),
    }..removeWhere((c) => c.isEmpty);

    return candidates.contains(title) ||
        (titleEn.isNotEmpty && candidates.contains(titleEn));
  }

  /// Returns `true` when [alert] matches [query] via canonical location lookup
  /// or bilingual fallback.
  static bool matchesRegion(AlertItem alert, String query) {
    final resolved = UkrainianLocations.findByCanonicalOrAlias(query);
    if (resolved != null) {
      return matchesLocation(alert, resolved);
    }

    final norm = _normalizeRegionText(query);
    if (norm.isEmpty) return false;

    // Explicit guard if a raw unrecognized Kyiv/Sevastopol phrase was passed.
    final mentionsKyiv = norm.contains('kyiv') ||
        norm.contains('kiev') ||
        norm.contains('київ');
    if (mentionsKyiv) {
      final isOblastPhrase = norm.contains('oblast') ||
          norm.contains('област') ||
          norm.contains('region') ||
          norm.contains('обл') ||
          norm.contains('район') ||
          norm.contains('raion');
      if (isOblastPhrase) {
        return matchesLocation(
          alert,
          UkrainianLocations.findByCanonicalOrAlias(
            UkrainianLocations.kyivOblastCanonical,
          )!,
        );
      }
      return _isKyivCityAlert(alert);
    }

    final terms = expandRegionTerms(query);
    if (terms.isEmpty) return false;

    final haystack = _normalizeRegionText(
      '${alert.locationTitle} ${alert.locationTitleEn ?? ''} ${alert.locationOblast} ${alert.locationRaion ?? ''}',
    );
    return terms.any((term) => term.isNotEmpty && haystack.contains(term));
  }

  void dispose() {
    if (_ownsHttpClient) {
      _httpClient?.close();
    }
  }
}

/// Lightweight HTTP status exception used internally for non-2xx Worker responses.
class HttpExceptionWithStatus implements Exception {
  final int statusCode;
  final String message;

  const HttpExceptionWithStatus(this.statusCode, this.message);

  @override
  String toString() => message;
}
