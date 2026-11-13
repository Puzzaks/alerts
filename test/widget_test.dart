import 'dart:async';
import 'dart:convert';

import 'package:alerts/engine.dart';
import 'package:alerts/main.dart';
import 'package:alerts/pages/home_page.dart';
import 'package:alerts/pages/intro_page.dart';
import 'package:alerts/pages/settings_page.dart';
import 'package:alerts/services/alerts_mesh_service.dart';
import 'package:alerts/widgets/ukraine_map.dart';
import 'package:alerts/widgets/ukraine_map_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:m3x_ui/m3x_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonAlertsResponse(
  List<Map<String, dynamic>> alerts, {
  String? updatedAt,
}) {
  final effectiveUpdatedAt = updatedAt ??
      DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: 45))
          .toIso8601String();
  final body = jsonEncode(<String, dynamic>{
    'meta': <String, dynamic>{'updated_at': effectiveUpdatedAt},
    'alerts': alerts,
  });
  return http.Response.bytes(
    utf8.encode(body),
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

void main() {
  tearDown(() {
    rootBundle.clear();
  });

  testWidgets(
      'AlertsApp renders clean Ukraine map, AppBar Settings & Refresh buttons, Hero card, and volunteer footer without PAIOS Mesh clutter on HomePage',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final mockClient = MockClient((request) async {
      expect(request.url.toString(), AlertsMeshService.fixedWorkerUrl);
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(UkraineOblastsMap), findsOneWidget);
    expect(ukraineOblastPolygons.length, 27);

    // Clean AppBar: title, Settings icon, and Refresh icon; no location button
    expect(find.text('Ukraine Air Alerts'), findsOneWidget);
    expect(find.text('PAIOS Mesh'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.settings_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Default Region / Oblast'),
      ),
      findsNothing,
    );

    // Map header, legend dots, and PAIOS Mesh Tools are absent from HomePage
    expect(find.text('Ukraine Map'), findsNothing);
    expect(find.text('Tap to expand · Pinch & pan'), findsNothing);
    expect(find.text('Pinch to zoom · Drag to pan'), findsNothing);
    expect(find.text('Oblast'), findsNothing);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Clear'), findsNothing);
    expect(find.text('All clear'), findsNothing);
    expect(find.text('PAIOS Mesh Tools'), findsNothing);
    expect(find.text('alerts_get_summary'), findsNothing);

    expect(find.text('0'), findsNothing);
    expect(find.text('All clear — no active alerts'), findsNWidgets(2));
    expect(find.textContaining('Checked '), findsNothing);
    expect(find.textContaining('Updated '), findsOneWidget);

    expect(find.text('Live Active Alerts'), findsOneWidget);
    expect(find.text('Disclaimer'), findsOneWidget);

    final refreshBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Refresh alerts'),
        matching: find.byType(IconButton),
      ),
    );
    expect(refreshBtn.onPressed, isNotNull);
  });

  testWidgets('HomePage shows subtle loading indicator during initial fetch',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final completer = Completer<http.Response>();
    final mockClient = MockClient((request) => completer.future);

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() => engine.init());

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Checking live alerts…'), findsOneWidget);
    expect(find.text('Loading live alerts…'), findsOneWidget);

    final refreshBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Refreshing alerts…'),
        matching: find.byType(IconButton),
      ),
    );
    expect(refreshBtn.onPressed, isNull);

    await tester.runAsync(() async {
      completer.complete(_jsonAlertsResponse(const <Map<String, dynamic>>[]));
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Checking live alerts…'), findsNothing);
    expect(find.text('All clear — no active alerts'), findsNWidgets(2));

  });

  testWidgets(
      'HomePage groups alerts into localized expandable oblast cards, uses whole-oblast Red/Yellow/Clear statuses, and hides redundant labels',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
      AlertsMeshService.prefsDefaultRegionKey: 'Київська область',
    });

    final startedKyiv = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 15))
        .toIso8601String();
    final startedKharkiv1 = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1, minutes: 16))
        .toIso8601String();
    final startedKharkiv2 = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 25))
        .toIso8601String();
    final startedOdesa = DateTime.now()
        .toUtc()
        .subtract(const Duration(seconds: 30))
        .toIso8601String();

    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '1',
            'location_title': 'Вишгородська громада',
            'location_oblast': 'Київська область',
            'location_type': 'hromada',
            'alert_type': 'air_raid',
            'alert_level': 'red',
            'started_at': startedKyiv,
          },
          <String, dynamic>{
            'id': '2',
            'location_title': 'Харківський район',
            'location_oblast': 'Харківська область',
            'location_type': 'raion',
            'alert_type': 'artillery_shelling',
            'alert_level': 'red',
            'started_at': startedKharkiv1,
          },
          <String, dynamic>{
            'id': '3',
            'location_title': 'Ізюмська громада',
            'location_oblast': 'Харківська область',
            'location_type': 'hromada',
            'alert_type': 'air_raid',
            'alert_level': 'yellow',
            'started_at': startedKharkiv2,
          },
          <String, dynamic>{
            'id': '4',
            'location_title': 'Одеська область',
            'location_oblast': 'Одеська область',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
            'alert_level': 'yellow',
            'started_at': startedOdesa,
          },
        ],
      );
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('4 active alerts'), findsOneWidget);
    expect(find.text('4 active'), findsOneWidget);
    expect(find.text('Air Raid: 3'), findsOneWidget);
    expect(find.text('Artillery Shelling: 1'), findsOneWidget);
    expect(find.text('Affected oblasts (3)'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    // Localized oblast chips + group headers in English mode
    expect(find.text('Kyiv Oblast'), findsNWidgets(2));
    expect(find.text('Kharkiv Oblast'), findsNWidgets(2));
    expect(find.text('Odesa Oblast'), findsNWidgets(2));
    expect(find.text('1 alert'), findsNWidgets(2));
    expect(find.text('2 alerts'), findsOneWidget);

    // Nested items collapsed by default
    expect(find.text('Вишгородська громада'), findsNothing);
    expect(find.text('Kharkiv Raion'), findsNothing);
    expect(find.text('Ізюмська громада'), findsNothing);
    expect(find.text('Artillery Shelling'), findsNothing);
    expect(find.text('Yellow'), findsNothing);

    // Tap Kharkiv oblast card ('2 alerts') to expand it
    await tester.ensureVisible(find.text('2 alerts'));
    await tester.tap(find.text('2 alerts'));
    await tester.pumpAndSettle();

    expect(find.text('Kharkiv Raion'), findsOneWidget);
    expect(find.text('Ізюмська громада'), findsOneWidget);
    expect(find.text('Artillery Shelling'), findsOneWidget);
    expect(find.text('Yellow'), findsOneWidget);
    expect(find.text('Air Raid'), findsNothing);
    expect(find.textContaining(' · '), findsAtLeastNWidgets(2));
    expect(find.textContaining(' ago'), findsAtLeastNWidgets(3));

    // Unexpanded Kyiv Oblast still collapsed
    expect(find.text('Вишгородська громада'), findsNothing);

    // Tap Kharkiv oblast card again to collapse it
    await tester.tap(find.text('2 alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Kharkiv Raion'), findsNothing);
    expect(find.text('Ізюмська громада'), findsNothing);

    // Verify unified whole-oblast Red / Yellow / Clear statuses across 27 regions
    final statuses = UkraineOblastsMap.computeStatuses(
      alerts: engine.alerts,
      affectedOblasts: engine.affectedOblasts,
      defaultRegion: engine.defaultRegion,
    );
    expect(statuses, hasLength(27));
    final kyivStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-32');
    expect(kyivStatus.status, OblastAlertStatus.red);
    expect(kyivStatus.isDefaultRegion, isTrue);
    expect(kyivStatus.alertCount, 1);

    final kyivCityStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-30');
    expect(kyivCityStatus.status, OblastAlertStatus.clear);
    expect(kyivCityStatus.isDefaultRegion, isFalse);
    expect(kyivCityStatus.alertCount, 0);

    final kharkivStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-63');
    expect(kharkivStatus.status, OblastAlertStatus.red);
    expect(kharkivStatus.alertCount, 2);

    final odesaStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-51');
    expect(odesaStatus.status, OblastAlertStatus.yellow);
    expect(odesaStatus.hasYellowOnly, isTrue);

    final segments = countOblastStatusSegments(statuses);
    expect(segments.red, 2);
    expect(segments.yellow, 1);
    expect(segments.clear, 24);

  });

  testWidgets(
      'SettingsPage renders SettingsBentoHeader, strict Default Region picker, Language switcher, PAIOS Mesh tools, and read-only Disclaimer info',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    // Navigate from HomePage AppBar to SettingsPage
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(SettingsBentoHeader), findsOneWidget);

    // Zero toggles/switches on SettingsPage (disclaimer is strictly read-only)
    expect(
      find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byType(Switch),
      ),
      findsNothing,
    );

    // Preferences & PAIOS Mesh Tools visible
    expect(find.text('Default location'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Replay setup & disclaimer'), findsOneWidget);
    expect(find.text('PAIOS Mesh Tools'), findsOneWidget);
    expect(find.text('alerts_get_summary'), findsOneWidget);
    expect(find.text('alerts_check_region'), findsOneWidget);
    expect(find.text('alerts_list_active'), findsOneWidget);

    // Scroll down to verify Disclaimer & Data Sources info-only rows
    await tester.scrollUntilVisible(
      find.text('Follow official sources'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Disclaimer & Data Sources'), findsOneWidget);
    expect(find.text('Unofficial informational monitor'), findsOneWidget);
    expect(find.text('Region-level status only'), findsOneWidget);
    expect(find.text('Coverage is not exhaustive'), findsOneWidget);
    expect(find.text('Follow official sources'), findsOneWidget);

    // Scroll back up to Default location card and test LocationPickerDialog
    await tester.scrollUntilVisible(
      find.text('Default location'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Default location'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Top-level regions (27)'), findsOneWidget);
    expect(find.text('Kyiv City'), findsOneWidget);
    expect(find.text('Kyiv Oblast'), findsOneWidget);
    expect(find.text('Save'), findsNothing);

    // Arbitrary unrecognized query ("moon") shows empty state with zero save option
    await tester.enterText(find.byType(TextField), 'moon');
    await tester.pump();
    expect(find.byIcon(Icons.location_off_outlined), findsOneWidget);
    expect(find.text('No matching Ukrainian location'), findsOneWidget);
    expect(find.text('Kyiv City'), findsNothing);
    expect(engine.defaultRegion, '');

    // Clear search, then search "Kyiv" and select "Kyiv City"
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Top-level regions (27)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Kyiv');
    await tester.pump();
    expect(find.text('Kyiv City'), findsOneWidget);
    expect(find.text('Special status city'), findsOneWidget);

    await tester.tap(find.text('Kyiv City'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(engine.defaultRegion, 'м. Київ');
    expect(find.textContaining('Kyiv City'), findsOneWidget);

    // Re-open picker and clear default region
    await tester.tap(find.text('Default location'));
    await tester.pumpAndSettle();
    expect(find.text('Clear region'), findsOneWidget);
    await tester.tap(find.text('Clear region'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(engine.defaultRegion, '');
    expect(find.textContaining('Not set'), findsOneWidget);

    // Switch language to Ukrainian via Settings Language dialog
    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Українська'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(engine.dict.locale, 'uk');
    expect(find.text('Налаштування'), findsWidgets);
    expect(find.text('За замовчуванням'), findsOneWidget);

  });

  testWidgets('Hero card renders inline error banner with Retry action on failure',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    var failNext = true;
    final mockClient = MockClient((request) async {
      if (failNext) {
        return http.Response('Upstream error', 502);
      }
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Retry'), findsOneWidget);
    expect(engine.errorMessage, isNotNull);

    failNext = false;
    await tester.ensureVisible(find.text('Retry'));
    await tester.pump();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.runAsync(() async {
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Retry'), findsNothing);
    expect(engine.errorMessage, isNull);

  });

  test(
      'buildHeroStatusGradient produces valid proportional Red -> Yellow -> Accent stops',
      () {
    final lightScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.dark,
    );

    void verifyValidStops(LinearGradient gradient) {
      final stops = gradient.stops!;
      expect(gradient.begin, Alignment.centerLeft);
      expect(gradient.end, Alignment.centerRight);
      expect(stops.length, gradient.colors.length);
      expect(stops.first, 0.0);
      expect(stops.last, 1.0);
      for (int i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
        expect(stops[i], inInclusiveRange(0.0, 1.0));
      }
    }

    final clearGradient = buildHeroStatusGradient(
      colorScheme: lightScheme,
      redCount: 0,
      yellowCount: 0,
      clearCount: 25,
    );
    verifyValidStops(clearGradient);
    expect(clearGradient.colors, hasLength(2));
    expect(clearGradient.colors[0], clearGradient.colors[1]);
    expect(clearGradient.stops, <double>[0.0, 1.0]);

    final threeSegment = buildHeroStatusGradient(
      colorScheme: lightScheme,
      redCount: 5,
      yellowCount: 5,
      clearCount: 15,
    );
    verifyValidStops(threeSegment);
    expect(threeSegment.colors, hasLength(6));
    expect(threeSegment.stops![1], closeTo(0.20 - 0.015, 0.0001));
    expect(threeSegment.stops![2], closeTo(0.20 + 0.015, 0.0001));
    expect(threeSegment.stops![3], closeTo(0.40 - 0.015, 0.0001));
    expect(threeSegment.stops![4], closeTo(0.40 + 0.015, 0.0001));

    final twoSegment = buildHeroStatusGradient(
      colorScheme: darkScheme,
      redCount: 10,
      yellowCount: 0,
      clearCount: 15,
    );
    verifyValidStops(twoSegment);
    expect(twoSegment.colors, hasLength(4));
    expect(twoSegment.stops![1], closeTo(0.40 - 0.015, 0.0001));
    expect(twoSegment.stops![2], closeTo(0.40 + 0.015, 0.0001));

    final tinySegments = buildHeroStatusGradient(
      colorScheme: lightScheme,
      redCount: 1,
      yellowCount: 1,
      clearCount: 23,
    );
    verifyValidStops(tinySegments);
    expect(tinySegments.colors, hasLength(6));

    final allRed = buildHeroStatusGradient(
      colorScheme: lightScheme,
      redCount: 25,
      yellowCount: 0,
      clearCount: 0,
    );
    verifyValidStops(allRed);
    expect(allRed.colors, hasLength(2));
    expect(allRed.colors[0], allRed.colors[1]);
  });

  testWidgets(
      'Tapping map card expands downward without upward shift, morphs bottom card keeping 48x48 badge + headline + Updated subtitle, and collapses back',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
      AlertsMeshService.prefsDefaultRegionKey: 'Київська область',
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '1',
            'location_title': 'Вишгородська громада',
            'location_oblast': 'Київська область',
            'location_type': 'hromada',
            'alert_type': 'air_raid',
            'alert_level': 'red',
          },
          <String, dynamic>{
            'id': '2',
            'location_title': 'Одеська область',
            'location_oblast': 'Одеська область',
            'location_type': 'oblast',
            'alert_type': 'air_raid',
            'alert_level': 'yellow',
          },
        ],
      );
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    // Compact mode: scrollable sections visible, InteractiveViewer absent
    expect(find.text('Live Active Alerts'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);

    final compactMapRect = tester.getRect(find.byType(UkraineOblastsMap));
    final compactHeroRect = tester.getRect(
      find.ancestor(
        of: find.text('2 active alerts'),
        matching: find.byType(Material),
      ).first,
    );

    // Tap anywhere inside the map card to smoothly expand downward
    await tester.tap(find.byType(UkraineOblastsMap));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    // Mid-animation: map top edge stays anchored (no upward shift) while height grows
    final midMapRect = tester.getRect(
      find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(UkraineOblastsMap),
      ),
    );
    expect(midMapRect.top, closeTo(compactMapRect.top, 0.5));
    expect(midMapRect.height, greaterThan(compactMapRect.height));

    await tester.pumpAndSettle();

    // Expanded mode: scrollable sections hidden, InteractiveViewer + expanded bottom header active
    expect(find.text('Live Active Alerts'), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(UkraineOblastsMap), findsOneWidget);
    expect(find.text('2 active alerts'), findsOneWidget);
    expect(find.textContaining('Updated '), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

    // Verify 48x48 icon badge is preserved inside the expanded bottom card
    final badgeFinder = find.ancestor(
      of: find.byIcon(Icons.warning_amber_rounded),
      matching: find.byType(Container),
    );
    expect(tester.getSize(badgeFinder.first), const Size(48, 48));

    final expandedMapRect = tester.getRect(find.byType(UkraineOblastsMap));
    expect(expandedMapRect.top, closeTo(compactMapRect.top, 0.5));
    expect(expandedMapRect.height, greaterThan(compactMapRect.height));

    final expandedStripRect = tester.getRect(
      find.ancestor(
        of: find.text('2 active alerts'),
        matching: find.byType(Material),
      ).first,
    );
    expect(expandedStripRect.top, greaterThan(compactHeroRect.top));
    expect(expandedStripRect.height, greaterThanOrEqualTo(88.0));
    expect(expandedStripRect.height, lessThan(compactHeroRect.height));

    // Tap Kyiv Oblast polygon in expanded mode to show floating overlay chip
    final statuses = UkraineOblastsMap.computeStatuses(
      alerts: engine.alerts,
      affectedOblasts: engine.affectedOblasts,
      defaultRegion: engine.defaultRegion,
    );
    final kyivStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-32');
    final mapPaintFinder = find.descendant(
      of: find.byType(UkraineOblastsMap),
      matching: find.byType(CustomPaint),
    );
    final mapBox = tester.renderObject<RenderBox>(mapPaintFinder);
    final mapSize = mapBox.size;
    final kyivCenter = Offset(
      kyivStatus.polygon.center.dx * mapSize.width,
      kyivStatus.polygon.center.dy * mapSize.width,
    );
    await tester.tapAt(mapBox.localToGlobal(kyivCenter));
    await tester.pump();

    expect(find.byType(OblastOverlayChip), findsOneWidget);
    expect(find.text('Kyiv Oblast · 1 active alert'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    // Tapping Kyiv City enclave hits UA-30 on top of UA-32
    final kyivCityStatus =
        statuses.firstWhere((s) => s.polygon.isoCode == 'UA-30');
    final kyivCityCenter = Offset(
      kyivCityStatus.polygon.center.dx * mapSize.width,
      kyivCityStatus.polygon.center.dy * mapSize.width,
    );
    await tester.tapAt(mapBox.localToGlobal(kyivCityCenter));
    await tester.pump();
    expect(find.text('Kyiv City · All clear'), findsOneWidget);

    // Tapping bottom gradient status card smoothly collapses back to compact UI
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Live Active Alerts'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(OblastOverlayChip), findsNothing);

  });

  test(
      'ukraineOblastPolygons includes Kyiv City and Sevastopol enclaves after parent oblasts',
      () {
    expect(ukraineOblastPolygons, hasLength(27));
    final isoList = ukraineOblastPolygons.map((p) => p.isoCode).toList();
    expect(isoList, containsAll(<String>['UA-30', 'UA-32', 'UA-40', 'UA-43']));
    expect(isoList.indexOf('UA-30'), greaterThan(isoList.indexOf('UA-32')));
    expect(isoList.indexOf('UA-40'), greaterThan(isoList.indexOf('UA-43')));

    final kyivCity =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-30');
    expect(kyivCity.ukName, 'м. Київ');
    expect(kyivCity.enName, 'Kyiv City');

    final sevastopol =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-40');
    expect(sevastopol.ukName, 'м. Севастополь');
    expect(sevastopol.enName, 'Sevastopol City');
  });

  test(
      'UkraineOblastsMap.computeStatuses isolates Kyiv City from Kyiv Oblast and Sevastopol from Crimea',
      () {
    final kyivCityAlertStatuses = UkraineOblastsMap.computeStatuses(
      alerts: const <AlertItem>[
        AlertItem(
          id: 'kc-1',
          locationTitle: 'м. Київ',
          locationOblast: 'Київська область',
          locationType: 'city',
          alertType: 'air_raid',
          alertLevel: 'red',
        ),
        AlertItem(
          id: 'sev-1',
          locationTitle: 'м. Севастополь',
          locationOblast: 'Автономна Республіка Крим',
          locationType: 'city',
          alertType: 'air_raid',
          alertLevel: 'yellow',
        ),
      ],
      affectedOblasts: const <String>[],
      defaultRegion: 'м. Київ',
    );

    final kyivCity =
        kyivCityAlertStatuses.firstWhere((s) => s.polygon.isoCode == 'UA-30');
    final kyivOblast =
        kyivCityAlertStatuses.firstWhere((s) => s.polygon.isoCode == 'UA-32');
    final sevastopol =
        kyivCityAlertStatuses.firstWhere((s) => s.polygon.isoCode == 'UA-40');
    final crimea =
        kyivCityAlertStatuses.firstWhere((s) => s.polygon.isoCode == 'UA-43');

    expect(kyivCity.isDefaultRegion, isTrue);
    expect(kyivCity.status, OblastAlertStatus.red);
    expect(kyivCity.alertCount, 1);

    expect(kyivOblast.isDefaultRegion, isFalse);
    expect(kyivOblast.status, OblastAlertStatus.clear);
    expect(kyivOblast.alertCount, 0);

    expect(sevastopol.status, OblastAlertStatus.yellow);
    expect(sevastopol.alertCount, 1);

    expect(crimea.status, OblastAlertStatus.clear);
    expect(crimea.alertCount, 0);

    // Sub-oblast city in Kyiv Oblast highlights Kyiv Oblast only, not Kyiv City
    final bilaTserkvaDefaultStatuses = UkraineOblastsMap.computeStatuses(
      alerts: const <AlertItem>[],
      affectedOblasts: const <String>[],
      defaultRegion: 'м. Біла Церква',
    );
    expect(
      bilaTserkvaDefaultStatuses
          .firstWhere((s) => s.polygon.isoCode == 'UA-32')
          .isDefaultRegion,
      isTrue,
    );
    expect(
      bilaTserkvaDefaultStatuses
          .firstWhere((s) => s.polygon.isoCode == 'UA-30')
          .isDefaultRegion,
      isFalse,
    );
  });

  test('lerpHeroStatusGradient smoothly interpolates mismatched stop counts', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final clearG = buildHeroStatusGradient(
      colorScheme: scheme,
      redCount: 0,
      yellowCount: 0,
      clearCount: 27,
    );
    final mixedG = buildHeroStatusGradient(
      colorScheme: scheme,
      redCount: 5,
      yellowCount: 5,
      clearCount: 17,
    );
    final mid = lerpHeroStatusGradient(clearG, mixedG, 0.5);
    expect(mid.stops, isNotNull);
    expect(mid.stops!.length, mid.colors.length);
    expect(mid.stops!.first, 0.0);
    expect(mid.stops!.last, 1.0);
    for (int i = 1; i < mid.stops!.length; i++) {
      expect(mid.stops![i], greaterThan(mid.stops![i - 1]));
    }
  });

  testWidgets(
      'UkraineOblastsMap uses vivid saturated red/yellow colors and localizes Kyiv City vs Kyiv Oblast cleanly across en and uk locales',
      (WidgetTester tester) async {
    expect(UkraineOblastsMap.redAlertColor.a, 1.0);
    expect(UkraineOblastsMap.yellowAlertColor.a, 1.0);
    expect(UkraineOblastsMap.redAlertColor, const Color(0xFFE53935));
    expect(UkraineOblastsMap.yellowAlertColor, const Color(0xFFFFD600));

    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
      AlertsMeshService.prefsDefaultRegionKey: 'м. Київ',
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '1',
            'location_title': 'м. Київ',
            'location_oblast': 'Київська область',
            'location_type': 'city',
            'alert_type': 'air_raid',
            'alert_level': 'red',
          },
          <String, dynamic>{
            'id': '2',
            'location_title': 'Вишгородська громада',
            'location_oblast': 'Київська область',
            'location_type': 'hromada',
            'alert_type': 'air_raid',
            'alert_level': 'yellow',
          },
        ],
      );
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    // In English locale, Kyiv City and Kyiv Oblast are grouped separately and localized
    expect(find.text('Kyiv City'), findsOneWidget);
    expect(find.text('Kyiv Oblast'), findsAtLeastNWidgets(1));
    expect(find.text('Default'), findsOneWidget);

    // Switch to Ukrainian locale and verify Ukrainian group headers and labels
    await tester.runAsync(() => engine.setLanguage('uk'));
    await tester.pump();
    expect(find.text('м. Київ'), findsOneWidget);
    expect(find.text('Київська область'), findsAtLeastNWidgets(1));
    expect(find.text('Обране'), findsOneWidget);
    expect(find.text('2 активні тривоги'), findsOneWidget);

    // Ensure dark mode theme colorScheme.error is not used for red alert polygons
    final darkScheme = ThemeData.dark(useMaterial3: true).colorScheme;
    expect(UkraineOblastsMap.redAlertColor, isNot(darkScheme.error));

  });

  test(
      'UkraineOblastsMap caches normalized Path per isoCode and hit-tests enclaves accurately',
      () {
    final kyivCity =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-30');
    final kyivOblast =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-32');

    final pathA = UkraineOblastsMap.normalizedPathFor(kyivCity);
    final pathB = UkraineOblastsMap.normalizedPathFor(kyivCity);
    expect(identical(pathA, pathB), isTrue);
    expect(pathA.contains(kyivCity.center), isTrue);

    final scaled = UkraineOblastsMap.buildPolygonPath(
      kyivOblast,
      const Size(600, 400),
    );
    expect(
      scaled.contains(Offset(kyivOblast.center.dx * 600, kyivOblast.center.dy * 600)),
      isTrue,
    );
  });

  testWidgets(
      'Expand/collapse morph renders zero Opacity saveLayers in status card and keeps expanded map size constant during animation',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': '1',
          'location_title': 'Київська область',
          'location_oblast': 'Київська область',
          'location_type': 'oblast',
          'alert_type': 'air_raid',
          'alert_level': 'red',
        },
      ]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    // Trigger expand and sample multiple frames mid-animation
    await tester.tap(find.byType(UkraineOblastsMap));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));

    final midCustomPaintSize1 = tester
        .renderObject<RenderBox>(
          find.descendant(
            of: find.descendant(
              of: find.byType(InteractiveViewer),
              matching: find.byType(UkraineOblastsMap),
            ),
            matching: find.byType(CustomPaint),
          ),
        )
        .size;

    // No Opacity widgets used anywhere in HomePage during morphing
    expect(
      find.descendant(of: find.byType(HomePage), matching: find.byType(Opacity)),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 70));

    final midCustomPaintSize2 = tester
        .renderObject<RenderBox>(
          find.descendant(
            of: find.descendant(
              of: find.byType(InteractiveViewer),
              matching: find.byType(UkraineOblastsMap),
            ),
            matching: find.byType(CustomPaint),
          ),
        )
        .size;

    // Cached expanded map CustomPaint keeps constant size across morph frames
    expect(midCustomPaintSize1, equals(midCustomPaintSize2));

    await tester.pumpAndSettle();
  });

  testWidgets(
      'IntroPage translates live between en and uk, blocks advancing past Slide 2 until all 3 disclaimer switches are enabled, and finishes to HomePage',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);
    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(IntroPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    expect(find.text('Choose your language'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);

    // Switch live to Ukrainian
    await tester.tap(find.text('Українська'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(engine.dict.locale, 'uk');
    expect(find.text('Оберіть мову'), findsOneWidget);
    expect(find.text('Далі'), findsOneWidget);

    // Switch live back to English
    await tester.tap(find.text('English'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(engine.dict.locale, 'en');
    expect(find.text('Choose your language'), findsOneWidget);

    // Advance to Slide 2 (Mandatory Terms & Disclaimer)
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Terms and disclaimer'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);
    expect(find.byType(Switch), findsNWidgets(3));

    // Accept button is disabled before all 3 switches are toggled
    FilledButton acceptBtn() => tester.widget<FilledButton>(
          find.ancestor(
            of: find.text('I understand and accept the terms'),
            matching: find.byType(FilledButton),
          ),
        );
    expect(acceptBtn().onPressed, isNull);

    // Attempt swipe forward on PageView — blocked by NeverScrollableScrollPhysics
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('Terms and disclaimer'), findsOneWidget);
    expect(find.text('Set your default location'), findsNothing);

    // Toggle first two switches — still disabled
    await tester.ensureVisible(find.text('Region-level status only'));
    await tester.tap(find.text('Region-level status only'));
    await tester.pump();
    await tester.ensureVisible(find.text('Coverage is not exhaustive'));
    await tester.tap(find.text('Coverage is not exhaustive'));
    await tester.pump();
    expect(acceptBtn().onPressed, isNull);

    // Toggle third switch — button enables
    await tester.ensureVisible(find.text('Follow official sources'));
    await tester.pump();
    await tester.tap(find.text('Follow official sources'));
    await tester.pump();
    expect(acceptBtn().onPressed, isNotNull);

    // Advance to Slide 3 (Default Region Selection)
    await tester.tap(find.text('I understand and accept the terms'));
    await tester.pumpAndSettle();

    expect(find.text('Set your default location'), findsOneWidget);
    expect(find.text('Choose location'), findsOneWidget);

    // Tap quick-pick ChoiceCard for Kyiv City
    await tester.ensureVisible(find.text('Kyiv City'));
    await tester.tap(find.text('Kyiv City'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(engine.defaultRegion, 'м. Київ');
    expect(find.text('Selected: Kyiv City'), findsOneWidget);

    // Finish intro -> transitions to HomePage
    await tester.tap(find.text('Finish'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(engine.introCompleted, isTrue);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(IntroPage), findsNothing);

  });

  testWidgets(
      'OblastOverlayChip renders localized Ukrainian labels when isUkrainian is true',
      (WidgetTester tester) async {
    final kyivCity =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-30');
    final kyivOblast =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-32');
    final odesaOblast =
        ukraineOblastPolygons.firstWhere((p) => p.isoCode == 'UA-51');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              OblastOverlayChip(
                status: OblastMapStatus(
                  polygon: kyivCity,
                  status: OblastAlertStatus.clear,
                  alertCount: 0,
                  isDefaultRegion: true,
                ),
                onClose: () {},
                isUkrainian: true,
              ),
              OblastOverlayChip(
                status: OblastMapStatus(
                  polygon: kyivOblast,
                  status: OblastAlertStatus.red,
                  alertCount: 1,
                  isDefaultRegion: false,
                ),
                onClose: () {},
                isUkrainian: true,
              ),
              OblastOverlayChip(
                status: OblastMapStatus(
                  polygon: odesaOblast,
                  status: OblastAlertStatus.yellow,
                  alertCount: 2,
                  isDefaultRegion: false,
                ),
                onClose: () {},
                isUkrainian: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('м. Київ · Тривог немає'), findsOneWidget);
    expect(find.text('За замовчуванням'), findsOneWidget);
    expect(find.text('Київська область · 1 тривога'), findsOneWidget);
    expect(
      find.text('Одеська область · 2 тривоги · Жовтий рівень'),
      findsOneWidget,
    );
  });

  testWidgets(
      'AlertsApp pauses and resumes AlertsEngine auto-refresh across app lifecycle changes',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);

    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    expect(engine.isForeground, isTrue);
    expect(engine.isAutoRefreshActive, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(engine.isForeground, isFalse);
    expect(engine.isAutoRefreshActive, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.isForeground, isTrue);
    expect(engine.isAutoRefreshActive, isTrue);

    engine.stopAutoRefresh();
  });

  testWidgets(
      'SettingsPage Version card opens standardized SettingsBentoHeader changelog bottom sheet instead of AlertDialog',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AlertsEngine.prefsIntroCompletedKey: true,
    });
    final mockClient = MockClient((request) async {
      return _jsonAlertsResponse(const <Map<String, dynamic>>[]);
    });

    final service = AlertsMeshService(httpClient: mockClient);
    final engine = AlertsEngine(
      meshService: service,
      systemLocaleProvider: () => 'en',
    );
    addTearDown(engine.dispose);

    await tester.runAsync(() async {
      await engine.init();
      while (engine.isRefreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AlertsEngine>.value(
        value: engine,
        child: const AlertsApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(SettingsBentoHeader), findsOneWidget);

    await tester.tap(find.text('Version'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.byIcon(Icons.change_circle_outlined), findsOneWidget);
    expect(find.text('Changelog'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);

    engine.stopAutoRefresh();
  });
}
