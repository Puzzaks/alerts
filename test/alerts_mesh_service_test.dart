import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alerts/engine.dart';
import 'package:alerts/services/alerts_mesh_service.dart';
import 'package:alerts/services/ukrainian_locations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:m3x_mesh/m3x_mesh.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response utf8JsonResponse(String body, [int statusCode = 200]) {
    return http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }

  final sampleWorkerPayload = jsonEncode(<String, dynamic>{
    'meta': <String, dynamic>{
      'updated_at': '2026-11-13T15:30:00Z',
    },
    'alerts': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': '1',
        'location_title': 'м. Київ',
        'location_oblast': 'Київська область',
        'location_type': 'city',
        'alert_type': 'air_raid',
        'started_at': '2026-11-13T15:10:00Z',
      },
      <String, dynamic>{
        'id': '2',
        'location_title': 'Харківський район',
        'location_oblast': 'Харківська область',
        'location_type': 'raion',
        'alert_type': 'artillery_shelling',
        'started_at': '2026-11-13T15:12:00Z',
      },
      <String, dynamic>{
        'id': '3',
        'location_title': 'Одеська область',
        'location_oblast': 'Одеська область',
        'location_type': 'oblast',
        'alert_type': 'air_raid',
        'started_at': '2026-11-13T15:15:00Z',
      },
    ],
  });

  group('AlertsMeshService', () {
    test('always uses hardcoded fixedWorkerUrl and ignores legacy prefs', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'alerts_worker_url': 'https://custom.example.invalid/v1/active.json',
      });

      final requestedUris = <Uri>[];
      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          requestedUris.add(request.url);
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      await service.init();

      expect(
        AlertsMeshService.fixedWorkerOrigin,
        'https://alerts.puzzak.workers.dev/',
      );
      expect(
        AlertsMeshService.fixedWorkerUrl,
        'https://alerts.puzzak.workers.dev/v1/active.json',
      );
      expect(service.isConfigured, isTrue);
      expect(service.hasWorkerUrl, isTrue);
      expect(service.workerOrigin, AlertsMeshService.fixedWorkerOrigin);
      expect(service.workerUrl, AlertsMeshService.fixedWorkerUrl);
      expect(
        service.endpointUri.toString(),
        'https://alerts.puzzak.workers.dev/v1/active.json',
      );

      final summary = await service.getSummary(const <String, dynamic>{});
      expect(summary['configured'], isTrue);
      expect(summary['worker_url_set'], isTrue);
      expect(summary['total_active'], 3);

      final probe = await service.testConnection();
      expect(probe.ok, isTrue);
      expect(probe.alertCount, 3);

      expect(requestedUris, hasLength(2));
      for (final uri in requestedUris) {
        expect(uri.toString(), AlertsMeshService.fixedWorkerUrl);
      }

      service.dispose();
    });

    test('supports injected endpointUri for unit tests and degrades gracefully on HTTP errors', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final customTestUri = Uri.parse('https://test.local/v1/active.json');
      Uri? capturedUri;

      final service = AlertsMeshService(
        endpointUri: customTestUri,
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          return http.Response('error', 500);
        }),
      );
      await service.init();

      final summary = await service.getSummary(const <String, dynamic>{});
      expect(capturedUri, customTestUri);
      expect(summary['configured'], isTrue);
      expect(summary['worker_url_set'], isTrue);
      expect(summary['stale'], isTrue);
      expect(summary['total_active'], 0);
      expect(summary['message'], contains('500'));

      final region = await service.checkRegion(const <String, dynamic>{'region': 'Kyiv'});
      expect(region['configured'], isTrue);
      expect(region['active'], isFalse);
      expect(region['match_count'], 0);
      expect(region['matches'], isEmpty);

      final listed = await service.listActive(const <String, dynamic>{});
      expect(listed['configured'], isTrue);
      expect(listed['total_active'], 0);
      expect(listed['alerts'], isEmpty);

      service.dispose();
    });

    test('supports bilingual English <-> Ukrainian oblast matching and default_region fallback', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AlertsMeshService.prefsDefaultRegionKey: 'Odesa',
      });
      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      await service.init();

      final kyiv = await service.checkRegion(const <String, dynamic>{'region': 'Kyiv'});
      expect(kyiv['configured'], isTrue);
      expect(kyiv['active'], isTrue);
      expect(kyiv['match_count'], 1);
      expect((kyiv['matches'] as List).first['location'], 'м. Київ');

      final kharkiv = await service.checkRegion(const <String, dynamic>{'region': 'харків'});
      expect(kharkiv['active'], isTrue);
      expect(kharkiv['match_count'], 1);
      expect((kharkiv['matches'] as List).first['oblast'], 'Харківська область');

      final odesaDefault = await service.checkRegion(const <String, dynamic>{});
      expect(odesaDefault['query'], 'Одеська область');
      expect(odesaDefault['resolved_location'], 'Одеська область');
      expect(odesaDefault['active'], isTrue);
      expect(odesaDefault['match_count'], 1);

      final ternopil = await service.checkRegion(const <String, dynamic>{'region': 'Ternopil'});
      expect(ternopil['active'], isFalse);
      expect(ternopil['match_count'], 0);
      expect(ternopil['matches'], isEmpty);

      service.dispose();
    });

    test('checkRegion returns nationwide summary when given country-wide queries', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );
      await service.init();

      for (final query in const <String>[
        'Ukraine',
        'Україна',
        '  украина! ',
        'U.A.',
        'all',
        'nation-wide',
        'everywhere',
        'всі',
        'усі',
      ]) {
        final result = await service.checkRegion(<String, dynamic>{'region': query});
        expect(result['configured'], isTrue, reason: 'Query: $query');
        expect(result['query'], query.trim(), reason: 'Query: $query');
        expect(result['scope'], 'nationwide', reason: 'Query: $query');
        expect(result['active'], isTrue, reason: 'Query: $query');
        expect(result['total_active'], 3, reason: 'Query: $query');
        expect(result['match_count'], 3, reason: 'Query: $query');
        expect((result['matches'] as List), hasLength(3), reason: 'Query: $query');
        expect(
          result['affected_oblasts'],
          containsAll(<String>[
            'Київська область',
            'Одеська область',
            'Харківська область',
          ]),
          reason: 'Query: $query',
        );
        expect(
          result['by_type'],
          <String, int>{'air_raid': 2, 'artillery_shelling': 1},
          reason: 'Query: $query',
        );
      }

      service.dispose();

      // When zero alerts are active across Ukraine, active is false with total_active == 0.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final quietService = AlertsMeshService(
        httpClient: MockClient(
          (_) async => utf8JsonResponse(jsonEncode(<String, dynamic>{'alerts': const <Map<String, dynamic>>[]})),
        ),
      );
      await quietService.init();
      final quiet = await quietService.checkRegion(const <String, dynamic>{'region': 'Ukraine'});
      expect(quiet['scope'], 'nationwide');
      expect(quiet['active'], isFalse);
      expect(quiet['total_active'], 0);
      expect(quiet['match_count'], 0);
      expect(quiet['matches'], isEmpty);
      expect(quiet['message'], 'No active alerts across Ukraine.');
      quietService.dispose();
    });

    test('generates compact summary from { meta, alerts } and raw { alerts } payloads', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      await service.init();

      final summary = await service.getSummary(const <String, dynamic>{});
      expect(summary['configured'], isTrue);
      expect(summary['worker_url_set'], isTrue);
      expect(summary['stale'], isFalse);
      expect(summary['updated_at'], '2026-11-13T15:30:00Z');
      expect(summary['total_active'], 3);
      expect(summary['by_type'], <String, int>{
        'air_raid': 2,
        'artillery_shelling': 1,
      });
      expect(
        summary['affected_oblasts'],
        containsAll(<String>[
          'Київська область',
          'Одеська область',
          'Харківська область',
        ]),
      );

      final rawOnly = AlertsMeshService.parseWorkerPayload(
        jsonEncode(<String, dynamic>{
          'alerts': <Map<String, dynamic>>[
            <String, dynamic>{
              'location_title': 'Львівська область',
              'alert_type': 'air_raid',
            },
          ],
        }),
        fetchedAt: DateTime.utc(2026, 11, 13, 16),
      );
      expect(rawOnly.totalActive, 1);
      expect(rawOnly.alerts.first.locationTitle, 'Львівська область');

      service.dispose();
    });

    test('caps alerts_list_active limit to 1..15 and supports offset and alert_type filter', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final manyAlerts = List<Map<String, dynamic>>.generate(
        20,
        (i) => <String, dynamic>{
          'id': 'id-$i',
          'location_title': 'Region $i',
          'location_oblast': 'Oblast $i',
          'alert_type': i.isEven ? 'air_raid' : 'artillery_shelling',
        },
      );
      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
          return http.Response(
            jsonEncode(<String, dynamic>{'alerts': manyAlerts}),
            200,
          );
        }),
      );
      await service.init();

      final overLimit = await service.listActive(const <String, dynamic>{'limit': 50});
      expect(overLimit['total_active'], 20);
      expect(overLimit['limit'], 15);
      expect(overLimit['returned'], 15);
      expect(overLimit['truncated'], isTrue);
      expect((overLimit['alerts'] as List).length, 15);

      final underLimit = await service.listActive(const <String, dynamic>{'limit': 0});
      expect(underLimit['limit'], 1);
      expect(underLimit['returned'], 1);

      final secondPage = await service.listActive(const <String, dynamic>{
        'offset': 15,
        'limit': 10,
      });
      expect(secondPage['returned'], 5);
      expect(secondPage['truncated'], isFalse);

      final filtered = await service.listActive(const <String, dynamic>{
        'alert_type': 'artillery_shelling',
        'limit': 15,
      });
      expect(filtered['filtered_total'], 10);
      expect(filtered['returned'], 10);

      service.dispose();
    });

    test('reuses cache within 8s and falls back to stale cache when offline', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      var now = DateTime.utc(2026, 11, 13, 15, 0, 0);
      var fetchCount = 0;
      var failRequests = false;

      final service = AlertsMeshService(
        nowProvider: () => now,
        httpClient: MockClient((request) async {
          expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
          fetchCount++;
          if (failRequests) {
            return http.Response('Service Unavailable', 503);
          }
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      await service.init();

      final first = await service.getSummary(const <String, dynamic>{});
      expect(first['stale'], isFalse);
      expect(fetchCount, 1);

      // Within 8 seconds: must reuse cached payload without hitting network.
      now = now.add(const Duration(seconds: 5));
      final second = await service.getSummary(const <String, dynamic>{});
      expect(second['stale'], isFalse);
      expect(fetchCount, 1);

      // Past 8 seconds + network failure: falls back to stale cached data.
      now = now.add(const Duration(seconds: 5));
      failRequests = true;
      final fallback = await service.getSummary(const <String, dynamic>{});
      expect(fetchCount, 2);
      expect(fallback['stale'], isTrue);
      expect(fallback['total_active'], 3);

      service.dispose();
    });

    test('registers M3x tools matching assets/mesh_tools.json 1:1 and binds handlers via toolsFromJsonString', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );

      final manifestFile = File('assets/mesh_tools.json');
      expect(manifestFile.existsSync(), isTrue);
      final rawManifest = manifestFile.readAsStringSync();
      final manifestJson = jsonDecode(rawManifest) as List<dynamic>;
      expect(manifestJson.length, 3);

      // Verify both pre-init built-in fallback schemas and post-init asset-loaded tools
      // match assets/mesh_tools.json 1:1 (name, app, packageName, description, parameters).
      void expectMatchesManifest(List<M3xTool> tools) {
        expect(tools, hasLength(manifestJson.length));
        for (var i = 0; i < manifestJson.length; i++) {
          final expected = Map<String, dynamic>.from(manifestJson[i] as Map);
          final actual = tools[i];
          expect(actual.name, expected['name'], reason: 'tool[$i].name');
          expect(actual.app, expected['app'], reason: 'tool[$i].app');
          expect(actual.packageName, expected['packageName'], reason: 'tool[$i].packageName');
          expect(actual.description, expected['description'], reason: 'tool[$i].description');
          expect(actual.parameters, equals(expected['parameters']), reason: 'tool[$i].parameters');
        }
      }

      expectMatchesManifest(service.defaultTools);
      expectMatchesManifest(service.tools);

      await service.init();
      expectMatchesManifest(service.tools);

      final parsedFromJson = service.toolsFromJsonString(rawManifest);
      expectMatchesManifest(parsedFromJson);

      final meshClient = M3xMeshClient(localAppId: AlertsMeshService.app);
      service.registerTools(meshClient);
      expectMatchesManifest(meshClient.localRegistry.tools);

      // Verify parsed tools bind live executable handlers.
      final summary = await parsedFromJson[0].invoke(const <String, dynamic>{});
      expect(summary['total_active'], 3);
      final region = await parsedFromJson[1].invoke(const <String, dynamic>{'region': 'Kyiv'});
      expect(region['active'], isTrue);
      final listed = await parsedFromJson[2].invoke(const <String, dynamic>{'limit': 2});
      expect((listed['alerts'] as List), hasLength(2));

      expect(
        () => service.toolsFromJsonString('[{"name":"unknown_tool"}]'),
        throwsStateError,
      );

      service.dispose();
    });

    test('AlertsEngine exposes fixed worker origin/url and fetches immediately on init', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requestedUris = <Uri>[];
      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          requestedUris.add(request.url);
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      final engine = AlertsEngine(meshService: service);

      expect(engine.workerOrigin, 'https://alerts.puzzak.workers.dev/');
      expect(engine.workerUrl, 'https://alerts.puzzak.workers.dev/v1/active.json');
      expect(engine.hasWorkerUrl, isTrue);

      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(requestedUris, hasLength(1));
      expect(requestedUris.single.toString(), AlertsMeshService.fixedWorkerUrl);
      expect(engine.totalActive, 3);

      engine.dispose();
    });

    test('parses alert_level/level, includes it in toJson/compact tools, and computes by_level', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final leveledPayload = jsonEncode(<String, dynamic>{
        'meta': <String, dynamic>{
          'updated_at': '2026-11-13T15:40:00Z',
          'by_level': <String, int>{'red': 2, 'yellow': 1},
        },
        'alerts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '10',
            'location_title': 'м. Київ',
            'location_oblast': 'Київська область',
            'location_type': 'city',
            'alert_type': 'air_raid',
            'alert_level': '  RED  ',
          },
          <String, dynamic>{
            'id': '11',
            'location_title': 'Одеська область',
            'location_oblast': 'Одеська область',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
            'level': 'Yellow',
          },
          <String, dynamic>{
            'id': '12',
            'location_title': 'Харківський район',
            'location_oblast': 'Харківська область',
            'location_type': 'raion',
            'alert_type': 'artillery_shelling',
            'alert_level': '   ',
            'level': 'red',
          },
          <String, dynamic>{
            'id': '13',
            'location_title': 'Львівська область',
            'location_oblast': 'Львівська область',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
          },
        ],
      });

      final service = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(leveledPayload)),
      );
      await service.init();

      final snapshot = await service.getSnapshot();
      expect(snapshot.alerts[0].alertLevel, 'red');
      expect(snapshot.alerts[1].alertLevel, 'yellow');
      expect(snapshot.alerts[2].alertLevel, 'red');
      expect(snapshot.alerts[3].alertLevel, isNull);
      expect(snapshot.byLevel, <String, int>{'red': 2, 'yellow': 1});

      expect(snapshot.alerts[0].toJson()['alert_level'], 'red');
      expect(snapshot.alerts[3].toJson().containsKey('alert_level'), isFalse);

      final summary = await service.getSummary(const <String, dynamic>{});
      expect(summary['by_level'], <String, int>{'red': 2, 'yellow': 1});

      final kyiv = await service.checkRegion(const <String, dynamic>{'region': 'Kyiv'});
      expect((kyiv['matches'] as List).first['alert_level'], 'red');

      final listed = await service.listActive(const <String, dynamic>{});
      final listedAlerts = listed['alerts'] as List;
      expect(listedAlerts[0]['alert_level'], 'red');
      expect(listedAlerts[1]['alert_level'], 'yellow');
      expect((listedAlerts[3] as Map).containsKey('alert_level'), isFalse);

      // Summary without alert_level omits by_level cleanly.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final serviceNoLevel = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );
      await serviceNoLevel.init();
      final noLevelSummary = await serviceNoLevel.getSummary(const <String, dynamic>{});
      expect(noLevelSummary.containsKey('by_level'), isFalse);

      service.dispose();
      serviceNoLevel.dispose();
    });
  });

  group('UkrainianLocations catalog & strict disambiguation', () {
    test('contains all 27 top-level admin regions and 136 official raions', () {
      expect(UkrainianLocations.topLevelRegions, hasLength(27));
      expect(UkrainianLocations.raions, hasLength(136));

      final topCanon = UkrainianLocations.topLevelRegions
          .map((l) => l.canonicalName)
          .toSet();
      expect(topCanon, contains('м. Київ'));
      expect(topCanon, contains('Київська область'));
      expect(topCanon, contains('м. Севастополь'));
      expect(topCanon, contains('Автономна Республіка Крим'));

      expect(
        UkrainianLocations.topLevelRegions.where((l) => l.isOblast),
        hasLength(25),
      );
      expect(
        UkrainianLocations.topLevelRegions.where((l) => l.isSpecialCity),
        hasLength(2),
      );

      expect(UkrainianLocations.search('moon'), isEmpty);
      expect(UkrainianLocations.findByCanonicalOrAlias('moon'), isNull);
      expect(UkrainianLocations.isValidLocation('moon'), isFalse);

      final kyivCity = UkrainianLocations.findByCanonicalOrAlias('Kyiv City');
      final kyivOblast = UkrainianLocations.findByCanonicalOrAlias('Kyiv Oblast');
      expect(kyivCity?.canonicalName, 'м. Київ');
      expect(kyivOblast?.canonicalName, 'Київська область');
      expect(kyivCity, isNot(equals(kyivOblast)));

      final bilaTserkvaRaion =
          UkrainianLocations.findByCanonicalOrAlias('Білоцерківський район');
      expect(bilaTserkvaRaion?.parentOblast, 'Київська область');
      expect(bilaTserkvaRaion?.type, 'raion');
    });

    test('strictly separates Kyiv City from Kyiv Oblast and Sevastopol from Crimea', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final payload = jsonEncode(<String, dynamic>{
        'meta': <String, dynamic>{'updated_at': '2026-11-13T17:00:00Z'},
        'alerts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'kyiv-city-1',
            'location_title': 'м. Київ',
            'location_title_en': 'Kyiv City',
            'location_oblast': 'м. Київ',
            'location_type': 'city',
            'alert_type': 'air_raid',
          },
          <String, dynamic>{
            'id': 'kyiv-oblast-1',
            'location_title': 'Білоцерківський район',
            'location_title_en': 'Bila Tserkva raion',
            'location_oblast': 'Київська область',
            'location_type': 'raion',
            'alert_type': 'air_raid',
          },
          <String, dynamic>{
            'id': 'sevastopol-1',
            'location_title': 'м. Севастополь',
            'location_oblast': 'м. Севастополь',
            'location_type': 'city',
            'alert_type': 'air_raid',
          },
          <String, dynamic>{
            'id': 'crimea-1',
            'location_title': 'Автономна Республіка Крим',
            'location_oblast': 'Автономна Республіка Крим',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
          },
        ],
      });

      final service = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(payload)),
      );
      await service.init();

      // Kyiv City must ONLY match м. Київ, never Білоцерківський район / Київська область.
      for (final q in const ['м. Київ', 'Kyiv City', 'Kyiv city', 'Kyiv']) {
        final res = await service.checkRegion(<String, dynamic>{'region': q});
        expect(res['resolved_location'], 'м. Київ', reason: 'Query: $q');
        expect(res['match_count'], 1, reason: 'Query: $q');
        expect((res['matches'] as List).single['location'], 'м. Київ');
      }

      // Kyiv Oblast must ONLY match Білоцерківський район, never м. Київ.
      for (final q in const ['Київська область', 'Kyiv Oblast', 'Kyivska']) {
        final res = await service.checkRegion(<String, dynamic>{'region': q});
        expect(res['resolved_location'], 'Київська область', reason: 'Query: $q');
        expect(res['match_count'], 1, reason: 'Query: $q');
        expect(
          (res['matches'] as List).single['location'],
          'Білоцерківський район',
        );
      }

      // Sevastopol vs AR Crimea isolation.
      final sev = await service.checkRegion(const <String, dynamic>{
        'region': 'м. Севастополь',
      });
      expect(sev['match_count'], 1);
      expect((sev['matches'] as List).single['location'], 'м. Севастополь');

      final crimea = await service.checkRegion(const <String, dynamic>{
        'region': 'Crimea',
      });
      expect(crimea['match_count'], 1);
      expect(
        (crimea['matches'] as List).single['location'],
        'Автономна Республіка Крим',
      );

      service.dispose();

      // Verify Kyiv City stays clear when only Kyiv Oblast has an alert.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final oblastOnlyPayload = jsonEncode(<String, dynamic>{
        'alerts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ko-only',
            'location_title': 'Київська область',
            'location_oblast': 'Київська область',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
          },
        ],
      });
      final serviceOblastOnly = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(oblastOnlyPayload)),
      );
      await serviceOblastOnly.init();
      final cityCheck = await serviceOblastOnly.checkRegion(
        const <String, dynamic>{'region': 'м. Київ'},
      );
      expect(cityCheck['active'], isFalse);
      expect(cityCheck['match_count'], 0);
      serviceOblastOnly.dispose();
    });

    test('validates setDefaultRegion, rejects invalid text like moon, and migrates legacy Kyiv city', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AlertsMeshService.prefsDefaultRegionKey: 'Kyiv city',
      });
      final service = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );
      final engine = AlertsEngine(meshService: service);
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // Migrates legacy 'Kyiv city' -> 'м. Київ' on init().
      expect(engine.defaultRegion, 'м. Київ');
      expect(engine.defaultLocation?.englishName, 'Kyiv City');
      expect(engine.isDefaultLocationAlerted, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AlertsMeshService.prefsDefaultRegionKey),
        'м. Київ',
      );

      // Invalid location 'moon' is rejected and never persisted.
      final rejected = await engine.setDefaultRegion('moon');
      expect(rejected, isFalse);
      expect(engine.defaultRegion, 'м. Київ');
      expect(
        prefs.getString(AlertsMeshService.prefsDefaultRegionKey),
        'м. Київ',
      );

      // Setting canonical 'Kyiv city' / 'Київська область' succeeds.
      expect(await engine.setDefaultRegion('Київська область'), isTrue);
      expect(engine.defaultRegion, 'Київська область');
      expect(engine.defaultLocation?.englishName, 'Kyiv Oblast');
      expect(
        prefs.getString(AlertsMeshService.prefsDefaultRegionKey),
        'Київська область',
      );

      expect(await engine.setDefaultRegion('Kyiv city'), isTrue);
      expect(engine.defaultRegion, 'м. Київ');

      // Clearing via '' and null succeeds.
      expect(await engine.setDefaultRegion(''), isTrue);
      expect(engine.defaultRegion, isEmpty);
      expect(engine.defaultLocation, isNull);
      expect(
        prefs.containsKey(AlertsMeshService.prefsDefaultRegionKey),
        isFalse,
      );

      expect(await engine.setDefaultRegion('м. Київ'), isTrue);
      expect(await engine.setDefaultRegion(null), isTrue);
      expect(engine.defaultRegion, isEmpty);

      engine.dispose();
    });
  });

  group('AlertsEngine localization, intro persistence & M3x metadata', () {
    test('languages.json, en.json, and uk.json parse cleanly with identical keys', () {
      final langsFile = File('assets/translations/languages.json');
      final enFile = File('assets/translations/en.json');
      final ukFile = File('assets/translations/uk.json');

      expect(langsFile.existsSync(), isTrue);
      expect(enFile.existsSync(), isTrue);
      expect(ukFile.existsSync(), isTrue);

      final langs = jsonDecode(langsFile.readAsStringSync()) as List<dynamic>;
      expect(langs.map((e) => (e as Map)['id']).toList(), <String>['en', 'uk']);

      final enMap = jsonDecode(enFile.readAsStringSync()) as Map<String, dynamic>;
      final ukMap = jsonDecode(ukFile.readAsStringSync()) as Map<String, dynamic>;

      expect(enMap.keys.toSet(), equals(ukMap.keys.toSet()));
      for (final entry in enMap.entries) {
        expect(entry.value, isA<String>());
        expect((entry.value as String).trim(), isNotEmpty, reason: 'en.${entry.key}');
        final ukVal = ukMap[entry.key];
        expect(ukVal, isA<String>(), reason: 'uk.${entry.key}');
        expect((ukVal as String).trim(), isNotEmpty, reason: 'uk.${entry.key}');
      }
    });

    test('AlertsEngine safely exposes dict pre-init, switches languages, and persists introCompleted', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AlertsMeshService.prefsDefaultRegionKey: 'м. Київ',
      });

      final service1 = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );
      final engine1 = AlertsEngine(
        meshService: service1,
        systemLocaleProvider: () => 'en',
      );

      // Safe before init() — no LateInitializationError.
      expect(engine1.appStarted, isFalse);
      expect(engine1.introCompleted, isFalse);
      expect(engine1.dict.locale, 'en');
      expect(engine1.languagePreferenceMode, 'system');

      await engine1.init();
      while (engine1.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(engine1.appStarted, isTrue);
      expect(engine1.introCompleted, isFalse);
      expect(engine1.languagePreferenceMode, 'system');
      expect(engine1.dict.locale, 'en');
      expect(engine1.dict.value('app_title'), 'Ukraine Air Alerts');
      expect(engine1.alertTypeLabel('air_raid'), 'Air Raid');

      final kyiv = engine1.defaultLocation!;
      expect(engine1.defaultRegion, 'м. Київ');
      expect(engine1.locationNameForLocale(kyiv), 'Kyiv City');
      expect(engine1.defaultRegionDisplayName, 'Kyiv City');

      // Switch to Ukrainian.
      await engine1.setLanguage('uk');
      expect(engine1.languagePreferenceMode, 'uk');
      expect(engine1.dict.locale, 'uk');
      expect(engine1.dict.value('app_title'), 'Повітряні тривоги України');
      expect(engine1.alertTypeLabel('air_raid'), 'Повітряна тривога');
      expect(engine1.alertTypeLabel('artillery_shelling'), 'Артобстріл');
      expect(engine1.locationNameForLocale(kyiv), 'м. Київ');
      expect(engine1.defaultRegionDisplayName, 'м. Київ');
      expect(engine1.defaultRegion, 'м. Київ');

      // Complete intro and verify persistence.
      await engine1.completeIntro();
      expect(engine1.introCompleted, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AlertsEngine.prefsIntroCompletedKey), isTrue);
      engine1.dispose();

      // Re-create engine to verify persisted language & intro flag across restarts.
      final service2 = AlertsMeshService(
        httpClient: MockClient((_) async => utf8JsonResponse(sampleWorkerPayload)),
      );
      final engine2 = AlertsEngine(
        meshService: service2,
        systemLocaleProvider: () => 'en',
      );
      await engine2.init();
      while (engine2.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(engine2.introCompleted, isTrue);
      expect(engine2.languagePreferenceMode, 'uk');
      expect(engine2.dict.locale, 'uk');
      expect(engine2.defaultRegion, 'м. Київ');
      expect(engine2.defaultRegionDisplayName, 'м. Київ');

      // Switch to explicit 'en', then back to 'system' (mocked as 'uk' here).
      await engine2.setLanguage('en');
      expect(engine2.languagePreferenceMode, 'en');
      expect(engine2.dict.locale, 'en');
      expect(engine2.locationNameForLocale(kyiv), 'Kyiv City');

      await engine2.setLanguage('system');
      expect(engine2.languagePreferenceMode, 'system');
      expect(engine2.dict.locale, 'en');

      // Reset intro flag.
      await engine2.resetIntro();
      expect(engine2.introCompleted, isFalse);
      expect(prefs.getBool(AlertsEngine.prefsIntroCompletedKey), isFalse);

      engine2.dispose();
    });
  });

  group('AlertsEngine foreground auto-refresh & lifecycle gate', () {
    test('init starts periodic foreground polling, setForeground pauses and resumes, and dispose cleans up', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var requestCount = 0;

      final service = AlertsMeshService(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
          requestCount++;
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      final engine = AlertsEngine(
        meshService: service,
        autoRefreshInterval: const Duration(milliseconds: 40),
      );

      expect(AlertsEngine.defaultAutoRefreshInterval, const Duration(seconds: 15));
      expect(engine.autoRefreshInterval, const Duration(milliseconds: 40));
      expect(engine.isForeground, isTrue);
      expect(engine.isAutoRefreshActive, isFalse);

      await engine.init();
      expect(engine.isAutoRefreshActive, isTrue);

      // Wait long enough for initial fetch + multiple 40ms periodic ticks.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (requestCount < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(requestCount, greaterThanOrEqualTo(3));

      // Backgrounding pauses the polling timer and prevents further requests.
      engine.setForeground(false);
      expect(engine.isForeground, isFalse);
      expect(engine.isAutoRefreshActive, isFalse);

      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final countWhileBackgrounded = requestCount;
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(requestCount, countWhileBackgrounded);

      // Resuming immediately triggers a fresh snapshot fetch and restarts polling.
      engine.setForeground(true);
      expect(engine.isForeground, isTrue);
      expect(engine.isAutoRefreshActive, isTrue);

      final resumeDeadline = DateTime.now().add(const Duration(seconds: 1));
      while (requestCount <= countWhileBackgrounded &&
          DateTime.now().isBefore(resumeDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requestCount, greaterThan(countWhileBackgrounded));

      final countAfterResume = requestCount;
      final tickDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (requestCount < countAfterResume + 2 &&
          DateTime.now().isBefore(tickDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(requestCount, greaterThanOrEqualTo(countAfterResume + 2));

      // Disposing stops the polling timer cleanly and prevents further fetches.
      engine.dispose();
      expect(engine.isAutoRefreshActive, isFalse);

      final countAfterDispose = requestCount;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(requestCount, countAfterDispose);
    });

    test('startHeadlessForMesh does not start periodic polling timer', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var requestCount = 0;

      final service = AlertsMeshService(
        httpClient: MockClient((_) async {
          requestCount++;
          return utf8JsonResponse(sampleWorkerPayload);
        }),
      );
      final engine = AlertsEngine(
        meshService: service,
        autoRefreshInterval: const Duration(milliseconds: 30),
      );

      await engine.startHeadlessForMesh();
      expect(engine.appStarted, isTrue);
      expect(engine.isAutoRefreshActive, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(requestCount, 0);
      expect(engine.isAutoRefreshActive, isFalse);

      engine.dispose();
    });

    test('late async refresh completing after dispose does not throw', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final responseGate = Completer<http.Response>();

      final service = AlertsMeshService(
        httpClient: MockClient((_) => responseGate.future),
      );
      final engine = AlertsEngine(
        meshService: service,
        autoRefreshInterval: const Duration(milliseconds: 40),
      );

      var notifications = 0;
      engine.addListener(() => notifications++);

      await engine.init();
      final notificationsBeforeDispose = notifications;

      // Dispose while the initial refreshNow() HTTP call is still in-flight.
      engine.dispose();
      expect(engine.isAutoRefreshActive, isFalse);

      responseGate.complete(utf8JsonResponse(sampleWorkerPayload));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(notifications, notificationsBeforeDispose);
    });
  });
}
