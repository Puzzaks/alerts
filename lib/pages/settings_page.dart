import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:m3x/m3x.dart';
import 'package:provider/provider.dart';

import '../engine.dart';
import '../services/alerts_mesh_service.dart';
import '../widgets/location_picker_dialog.dart';

/// Standalone Material 3 Settings, Localization, PAIOS Mesh, and Disclaimer
/// page for Ukraine Air Alerts.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _languageDisplayName(AlertsEngine engine) {
    switch (engine.languagePreferenceMode) {
      case 'en':
        return 'English';
      case 'uk':
        return 'Українська';
      default:
        return engine.t('settings_language_system');
    }
  }

  Future<void> _showLanguageDialog(
    BuildContext context,
    AlertsEngine engine,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        final String mode = engine.languagePreferenceMode;
        final double dialogWidth = math.min(
          420.0,
          math.max(240.0, MediaQuery.sizeOf(dialogCtx).width - 80.0),
        );

        Future<void> pick(String lang) async {
          await engine.setLanguage(lang);
          if (dialogCtx.mounted) {
            Navigator.of(dialogCtx).pop();
          }
        }

        return AlertDialog(
          title: Text(engine.t('settings_language')),
          content: SizedBox(
            width: dialogWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChoiceCard(
                  icon: Icons.settings_suggest_rounded,
                  title: engine.t('settings_language_system'),
                  subtitle: engine.t('intro_lang_system_sub'),
                  selected: mode == 'system',
                  onTap: () => pick('system'),
                ),
                const SizedBox(height: 8),
                ChoiceCard(
                  icon: Icons.language_rounded,
                  title: 'English',
                  subtitle: 'English (International)',
                  selected: mode == 'en',
                  onTap: () => pick('en'),
                ),
                const SizedBox(height: 8),
                ChoiceCard(
                  icon: Icons.translate_rounded,
                  title: 'Українська',
                  subtitle: 'Українська мова',
                  selected: mode == 'uk',
                  onTap: () => pick('uk'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(engine.t('cancel')),
            ),
          ],
        );
      },
    );
  }

  static String _formatChangelogSubtitle(String rawVersion) {
    final String trimmed = rawVersion.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('v') ? trimmed : 'v$trimmed';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AlertsEngine>(
      builder: (context, engine, _) {
        final scheme = Theme.of(context).colorScheme;
        final bool isUk = engine.dict.locale == 'uk';
        final String currentLocationLabel = engine.defaultRegion.isEmpty
            ? engine.t('location_not_set')
            : engine.defaultRegionDisplayName;

        return SliverPageScaffold(
          title: engine.t('settings'),
          maxContentWidth: 760,
          children: [
            const SizedBox(height: 6),
            SettingsBentoHeader(
              appName: M3x.appName.isNotEmpty
                  ? M3x.appName
                  : engine.t('app_title'),
              subtitle: engine.appDescription.isNotEmpty
                  ? engine.appDescription
                  : engine.t('settings_bento_subtitle'),
              icon: Icons.notifications_active_rounded,
              versionDisplay: engine.appVersionDisplay,
              versionTitle: engine.t('settings_version_label'),
              modulesTitle:
                  '${engine.dependencies.length} ${engine.t('settings_packages_label')}',
              modulesSubtitle: engine.t('settings_tap_to_view'),
              onVersionTap: () => SettingsBentoHeader.showChangelogDialog(
                context,
                title: engine.t('settings_changelog_title'),
                subtitle: _formatChangelogSubtitle(engine.appVersionDisplay),
                changelogContent: engine.changelogContent,
                emptyMessage: engine.t('settings_no_changelog'),
              ),
              onModulesTap: () => SettingsBentoHeader.showDependenciesDialog(
                context,
                title:
                    '${engine.t('settings_packages_title')} (${engine.dependencies.length})',
                dependencies: engine.dependencies,
                workspaceBadge: engine.t('settings_packages_workspace_badge'),
                pubBadge: engine.t('settings_packages_pub_badge'),
              ),
            ),
            Category.settings(
              title: engine.t('settings_preferences'),
              context: context,
            ),
            CardGroup(
              children: [
                CardContents.tapIcon(
                  title: engine.t('location_default_title'),
                  subtitle:
                      '$currentLocationLabel · ${engine.t('location_default_subtitle')}',
                  icon: Icons.location_on_rounded,
                  color: scheme.onPrimaryContainer,
                  colorBG: scheme.primaryContainer,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  action: () => showLocationPickerDialog(context, engine),
                ),
                CardContents.tapIcon(
                  title: engine.t('settings_language'),
                  subtitle: _languageDisplayName(engine),
                  icon: Icons.translate_rounded,
                  color: scheme.onSecondaryContainer,
                  colorBG: scheme.secondaryContainer,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  action: () => _showLanguageDialog(context, engine),
                ),
                CardContents.tapIcon(
                  title: engine.t('settings_replay_intro'),
                  subtitle: engine.t('settings_replay_intro_subtitle'),
                  icon: Icons.verified_user_outlined,
                  color: scheme.onTertiaryContainer,
                  colorBG: scheme.tertiaryContainer,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  action: () async {
                    await engine.resetIntro();
                    if (context.mounted) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                ),
              ],
            ),
            Category.settings(
              title: engine.t('settings_mesh_title'),
              context: context,
              trailing: _SettingsCountPill(
                label:
                    '${engine.registeredTools.length} ${engine.t('settings_mesh_tools_count')}',
              ),
            ),
            _MeshToolsCardGroup(
              tools: engine.registeredTools,
              statusBadgeLabel: engine.t('settings_mesh_subtitle'),
              isUkrainian: isUk,
            ),
            TextPart.info(
              title: engine
                  .t('settings_mesh_footer')
                  .replaceAll('{package}', AlertsMeshService.packageName),
              subtitle: '',
              action: () {},
              context: context,
            ),
            Category.settings(
              title: engine.t('settings_disclaimer_section'),
              context: context,
            ),
            CardGroup(
              children: [
                _DisclaimerInfoRow(
                  icon: Icons.info_outline_rounded,
                  iconBg: scheme.secondaryContainer,
                  iconFg: scheme.onSecondaryContainer,
                  title: engine.t('settings_source_unofficial_title'),
                  body: engine.t('settings_source_unofficial_body'),
                ),
                _DisclaimerInfoRow(
                  icon: Icons.radar_rounded,
                  iconBg: scheme.errorContainer,
                  iconFg: scheme.onErrorContainer,
                  title: engine.t('disclaimer_not_radar_title'),
                  body: engine.t('disclaimer_not_radar_body'),
                ),
                _DisclaimerInfoRow(
                  icon: Icons.warning_amber_rounded,
                  iconBg: scheme.errorContainer,
                  iconFg: scheme.onErrorContainer,
                  title: engine.t('disclaimer_not_exhaustive_title'),
                  body: engine.t('disclaimer_not_exhaustive_body'),
                ),
                _DisclaimerInfoRow(
                  icon: Icons.campaign_outlined,
                  iconBg: scheme.errorContainer,
                  iconFg: scheme.onErrorContainer,
                  title: engine.t('disclaimer_official_title'),
                  body: engine.t('disclaimer_official_body'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SettingsCountPill extends StatelessWidget {
  final String label;

  const _SettingsCountPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MeshToolsCardGroup extends StatelessWidget {
  final List<M3xTool> tools;
  final String statusBadgeLabel;
  final bool isUkrainian;

  const _MeshToolsCardGroup({
    required this.tools,
    required this.statusBadgeLabel,
    required this.isUkrainian,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (tools.isEmpty) {
      return CardGroup(
        children: [
          CardContents.static(
            title: isUkrainian
                ? 'Немає зареєстрованих інструментів'
                : 'No mesh tools registered',
            subtitle: isUkrainian
                ? 'Очікування ініціалізації M3x Mesh'
                : 'Waiting for M3x Mesh initialization',
          ),
        ],
      );
    }

    return CardGroup(
      children: [
        for (final tool in tools)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(
                      _toolIcon(tool.name),
                      size: 18,
                      color: scheme.primary,
                    ),
                    Text(
                      tool.name,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            size: 13,
                            color: scheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            statusBadgeLabel,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  tool.description,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static IconData _toolIcon(String name) {
    switch (name) {
      case 'alerts_get_summary':
        return Icons.summarize_rounded;
      case 'alerts_check_region':
        return Icons.travel_explore_rounded;
      case 'alerts_list_active':
        return Icons.format_list_bulleted_rounded;
      default:
        return Icons.extension_rounded;
    }
  }
}

class _DisclaimerInfoRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconFg;
  final String title;
  final String body;

  const _DisclaimerInfoRow({
    required this.icon,
    required this.iconBg,
    required this.iconFg,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 20, color: iconFg),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
