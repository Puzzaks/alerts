import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:m3x/m3x.dart';
import 'package:provider/provider.dart';

import 'engine.dart';
import 'pages/home_page.dart';
import 'pages/intro_page.dart';

final AlertsEngine alertsEngine = AlertsEngine();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider<AlertsEngine>.value(
      value: alertsEngine,
      child: const AlertsApp(),
    ),
  );
}

@pragma('vm:entry-point')
Future<void> m3xMeshMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await alertsEngine.startHeadlessForMesh();
}

class AlertsApp extends StatefulWidget {
  const AlertsApp({super.key});

  @override
  State<AlertsApp> createState() => _AlertsAppState();
}

class _AlertsAppState extends State<AlertsApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onResume: () => _setForeground(true),
      onPause: () => _setForeground(false),
      onHide: () => _setForeground(false),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AlertsEngine>().init();
    });
  }

  void _setForeground(bool foreground) {
    if (!mounted) return;
    context.read<AlertsEngine>().setForeground(foreground);
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final ThemeData lightTheme = PuzzakTheme.buildTheme(
          brightness: Brightness.light,
          dynamicScheme: lightDynamic,
        );
        final ThemeData darkTheme = PuzzakTheme.buildTheme(
          brightness: Brightness.dark,
          dynamicScheme: darkDynamic,
        );

        return Consumer<AlertsEngine>(
          builder: (context, engine, _) {
            return MaterialApp(
              title: engine.t('app_title'),
              debugShowCheckedModeBanner: false,
              theme: lightTheme,
              darkTheme: darkTheme,
              themeMode: ThemeMode.system,
              home: StartupCrossFadeShell(
                appStarted: engine.appStarted,
                showOnboarding: !engine.introCompleted,
                onboardingChild: const IntroPage(),
                child: const HomePage(),
              ),
            );
          },
        );
      },
    );
  }
}
