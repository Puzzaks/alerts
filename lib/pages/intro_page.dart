import 'package:flutter/material.dart';
import 'package:m3x_ui/m3x_ui.dart';
import 'package:provider/provider.dart';

import '../engine.dart';
import '../services/ukrainian_locations.dart';
import '../widgets/location_picker_dialog.dart';

/// Three-step Material 3 onboarding & mandatory disclaimer wizard:
/// 1. Language selection (`System default` / `English` / `Українська`)
/// 2. Mandatory Terms & Disclaimer (all 3 switches required before advancing)
/// 3. Optional Default Region selection (quick picks + full location search)
class IntroPage extends StatefulWidget {
  const IntroPage({super.key});

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage> {
  static const List<String> _quickPickCanonicals = <String>[
    'м. Київ',
    'Київська область',
    'Львівська область',
    'Харківська область',
  ];

  final PageController _pageController = PageController();
  int _currentPage = 0;

  bool _acceptedNotRadar = false;
  bool _acceptedNotExhaustive = false;
  bool _acceptedOfficial = false;
  bool _isCompleting = false;

  bool get _allAccepted =>
      _acceptedNotRadar && _acceptedNotExhaustive && _acceptedOfficial;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeInOutCubic,
    );
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _goToPage(_currentPage - 1);
    }
  }

  void _nextPage() {
    if (_currentPage == 1 && !_allAccepted) {
      return;
    }
    if (_currentPage < 2) {
      _goToPage(_currentPage + 1);
    }
  }

  Future<void> _finish(AlertsEngine engine) async {
    if (_isCompleting || !_allAccepted) return;
    setState(() => _isCompleting = true);
    await engine.completeIntro();
    if (mounted) {
      setState(() => _isCompleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AlertsEngine>(
      builder: (context, engine, _) {
        final scheme = Theme.of(context).colorScheme;
        final bool lockSwipeOnDisclaimer = _currentPage == 1 && !_allAccepted;

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: lockSwipeOnDisclaimer
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    onPageChanged: (index) {
                      if (index > 1 && !_allAccepted) {
                        _pageController.jumpToPage(1);
                        return;
                      }
                      setState(() => _currentPage = index);
                    },
                    children: [
                      _LanguageSlide(engine: engine),
                      _DisclaimerSlide(
                        engine: engine,
                        acceptedNotRadar: _acceptedNotRadar,
                        acceptedNotExhaustive: _acceptedNotExhaustive,
                        acceptedOfficial: _acceptedOfficial,
                        onToggleNotRadar: (val) =>
                            setState(() => _acceptedNotRadar = val),
                        onToggleNotExhaustive: (val) =>
                            setState(() => _acceptedNotExhaustive = val),
                        onToggleOfficial: (val) =>
                            setState(() => _acceptedOfficial = val),
                      ),
                      _LocationSlide(
                        engine: engine,
                        quickPickCanonicals: _quickPickCanonicals,
                      ),
                    ],
                  ),
                ),

                // Animated 24px pill indicator dots matching OnboardingWizard style
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List<Widget>.generate(3, (i) {
                      final bool active = _currentPage == i;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: active
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                        ),
                      );
                    }),
                  ),
                ),

                // Bottom navigation bar: no Skip on Slide 1 or Slide 2
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (_currentPage > 0)
                          TextButton.icon(
                            onPressed: _isCompleting ? null : _previousPage,
                            icon: const Icon(Icons.arrow_back_rounded, size: 18),
                            label: Text(engine.t('intro_back')),
                          )
                        else
                          const SizedBox(width: 84),
                        if (_currentPage == 0)
                          FilledButton(
                            onPressed: _nextPage,
                            child: Text(engine.t('intro_next')),
                          )
                        else if (_currentPage == 1)
                          Flexible(
                            child: FilledButton(
                              onPressed: _allAccepted ? _nextPage : null,
                              child: Text(
                                engine.t('disclaimer_accept_button'),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        else
                          FilledButton.icon(
                            onPressed:
                                _isCompleting ? null : () => _finish(engine),
                            icon: const Icon(Icons.check_rounded),
                            label: Text(engine.t('intro_finish')),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LanguageSlide extends StatelessWidget {
  final AlertsEngine engine;

  const _LanguageSlide({required this.engine});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final String mode = engine.languagePreferenceMode;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.translate_rounded,
                  size: 36,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                engine.t('intro_lang_title'),
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                engine.t('intro_lang_desc'),
                style: textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ChoiceCard(
                icon: Icons.settings_suggest_rounded,
                title: engine.t('settings_language_system'),
                subtitle: engine.t('intro_lang_system_sub'),
                selected: mode == 'system',
                onTap: () => engine.setLanguage('system'),
              ),
              const SizedBox(height: 10),
              ChoiceCard(
                icon: Icons.language_rounded,
                title: 'English',
                subtitle: 'English (International)',
                selected: mode == 'en',
                onTap: () => engine.setLanguage('en'),
              ),
              const SizedBox(height: 10),
              ChoiceCard(
                icon: Icons.flag_rounded,
                title: 'Українська',
                subtitle: 'Українська мова',
                selected: mode == 'uk',
                onTap: () => engine.setLanguage('uk'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisclaimerSlide extends StatelessWidget {
  final AlertsEngine engine;
  final bool acceptedNotRadar;
  final bool acceptedNotExhaustive;
  final bool acceptedOfficial;
  final ValueChanged<bool> onToggleNotRadar;
  final ValueChanged<bool> onToggleNotExhaustive;
  final ValueChanged<bool> onToggleOfficial;

  const _DisclaimerSlide({
    required this.engine,
    required this.acceptedNotRadar,
    required this.acceptedNotExhaustive,
    required this.acceptedOfficial,
    required this.onToggleNotRadar,
    required this.onToggleNotExhaustive,
    required this.onToggleOfficial,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bool allAccepted =
        acceptedNotRadar && acceptedNotExhaustive && acceptedOfficial;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 36,
                  color: scheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  engine.t('disclaimer_title'),
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  engine.t('disclaimer_intro_subtitle'),
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 18),
              CardGroup(
                children: [
                  CardContents.turn(
                    title: engine.t('disclaimer_not_radar_title'),
                    subtitle: engine.t('disclaimer_not_radar_body'),
                    value: acceptedNotRadar,
                    action: () => onToggleNotRadar(!acceptedNotRadar),
                    switcher: onToggleNotRadar,
                  ),
                  CardContents.turn(
                    title: engine.t('disclaimer_not_exhaustive_title'),
                    subtitle: engine.t('disclaimer_not_exhaustive_body'),
                    value: acceptedNotExhaustive,
                    action: () => onToggleNotExhaustive(!acceptedNotExhaustive),
                    switcher: onToggleNotExhaustive,
                  ),
                  CardContents.turn(
                    title: engine.t('disclaimer_official_title'),
                    subtitle: engine.t('disclaimer_official_body'),
                    value: acceptedOfficial,
                    action: () => onToggleOfficial(!acceptedOfficial),
                    switcher: onToggleOfficial,
                  ),
                ],
              ),
              if (!allAccepted) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    engine.t('disclaimer_toggle_hint'),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationSlide extends StatelessWidget {
  final AlertsEngine engine;
  final List<String> quickPickCanonicals;

  const _LocationSlide({
    required this.engine,
    required this.quickPickCanonicals,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final String selectedDisplay = engine.defaultRegion.isEmpty
        ? engine.t('location_not_set')
        : engine.defaultRegionDisplayName;
    final bool hasSelection = engine.defaultRegion.isNotEmpty;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.location_on_rounded,
                  size: 36,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                engine.t('intro_location_title'),
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                engine.t('intro_location_desc'),
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: hasSelection
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasSelection
                          ? Icons.check_circle_rounded
                          : Icons.location_searching_rounded,
                      size: 18,
                      color: hasSelection
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${engine.t('intro_location_selected_prefix')}: $selectedDisplay',
                        style: textTheme.labelLarge?.copyWith(
                          color: hasSelection
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => showLocationPickerDialog(context, engine),
                icon: const Icon(Icons.search_rounded),
                label: Text(engine.t('intro_location_choose_btn')),
              ),
              const SizedBox(height: 16),
              for (final canonical in quickPickCanonicals)
                if (UkrainianLocations.findByCanonicalOrAlias(canonical)
                    case final UkrainianLocation loc) ...[
                  ChoiceCard(
                    icon: loc.isSpecialCity
                        ? Icons.location_city_rounded
                        : Icons.map_rounded,
                    title: engine.locationNameForLocale(loc),
                    subtitle: engine.locationSubtitleForLocale(loc),
                    selected: engine.defaultRegion == loc.canonicalName,
                    onTap: () => engine.setDefaultRegion(
                      engine.defaultRegion == loc.canonicalName
                          ? ''
                          : loc.canonicalName,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              const SizedBox(height: 6),
              Text(
                engine.t('intro_location_optional_hint'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
