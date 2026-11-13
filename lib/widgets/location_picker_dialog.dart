import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine.dart';
import '../services/ukrainian_locations.dart';

/// Opens the searchable, verified [UkrainianLocations] picker dialog and
/// persists the user's choice via [AlertsEngine.setDefaultRegion].
Future<void> showLocationPickerDialog(
  BuildContext context,
  AlertsEngine engine,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => LocationPickerDialog(engine: engine),
  );
}

/// Shared localized Material 3 dialog for picking or clearing a verified
/// Ukrainian oblast, raion, or city as [AlertsEngine.defaultRegion].
class LocationPickerDialog extends StatefulWidget {
  final AlertsEngine engine;

  const LocationPickerDialog({
    super.key,
    required this.engine,
  });

  @override
  State<LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<LocationPickerDialog> {
  late final TextEditingController _searchController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _selectCanonical(String canonicalName) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    await widget.engine.setDefaultRegion(canonicalName);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String _matchCountLabel(int count) {
    final engine = widget.engine;
    if (engine.dict.locale == 'uk') {
      final int mod100 = count % 100;
      final int mod10 = count % 10;
      if (mod10 == 1 && mod100 != 11) {
        return '$count ${engine.t('location_matches_one')}';
      }
      if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
        return '$count збіги';
      }
      return '$count ${engine.t('location_matches_many')}';
    }
    final suffix = count == 1
        ? engine.t('location_matches_one')
        : engine.t('location_matches_many');
    return '$count $suffix';
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final bool isUk = engine.dict.locale == 'uk';
    final String query = _searchController.text.trim();
    final List<UkrainianLocation> results = query.isEmpty
        ? UkrainianLocations.topLevelRegions
        : UkrainianLocations.search(query);
    final UkrainianLocation? currentLocation = engine.defaultLocation;
    final String currentCanonical = engine.defaultRegion.trim();

    final double dialogWidth = math.min(
      420.0,
      math.max(240.0, MediaQuery.sizeOf(context).width - 80.0),
    );
    final double dialogHeight = math.min(
      380.0,
      math.max(220.0, MediaQuery.sizeOf(context).height * 0.55),
    );

    return AlertDialog(
      title: Text(engine.t('location_picker_title')),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _searchController,
              enabled: !_isSaving,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: engine.t('location_search_label'),
                hintText: engine.t('location_search_hint'),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        tooltip: isUk ? 'Очистити пошук' : 'Clear search',
                        onPressed: _isSaving
                            ? null
                            : () {
                                _searchController.clear();
                                setState(() {});
                              },
                        icon: const Icon(Icons.close_rounded),
                      )
                    : null,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              query.isEmpty
                  ? '${engine.t('location_top_level_prefix')} (${UkrainianLocations.topLevelRegions.length})'
                  : _matchCountLabel(results.length),
              style: textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 20,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.location_off_outlined,
                              size: 36,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              engine.t('location_no_match_title'),
                              textAlign: TextAlign.center,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              engine.t('location_no_match_subtitle'),
                              textAlign: TextAlign.center,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: results.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                      itemBuilder: (context, index) {
                        final loc = results[index];
                        final bool isSelected = currentLocation == loc ||
                            currentCanonical == loc.canonicalName;
                        final String titleText =
                            engine.locationNameForLocale(loc);
                        final String subtitleText =
                            engine.locationSubtitleForLocale(loc);

                        return ListTile(
                          dense: true,
                          enabled: !_isSaving,
                          selected: isSelected,
                          selectedTileColor:
                              scheme.primaryContainer.withValues(alpha: 0.35),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          title: Text(
                            titleText,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            subtitleText,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: isSelected
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  size: 20,
                                  color: scheme.primary,
                                )
                              : null,
                          onTap: () => _selectCanonical(loc.canonicalName),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (currentCanonical.isNotEmpty || currentLocation != null)
          TextButton(
            onPressed: _isSaving ? null : () => _selectCanonical(''),
            child: Text(engine.t('location_clear')),
          ),
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text(engine.t('cancel')),
        ),
      ],
    );
  }
}
