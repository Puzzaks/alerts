## Update 1.1.5 (Nov 13, 2026) `NATIONWIDE CHECK_REGION FALLBACK & TOOL SCHEMA CLARITY`
#### Changes
- **Nationwide `alerts_check_region` Handling (`AlertsMeshService`)**:
  - Updated `checkRegion` so country-wide queries (`"ukraine"`, `"україна"`, `"украина"`, `"ua"`, `"all"`, `"nationwide"`, `"everywhere"`, `"всі"`, `"усі"` after stripping whitespace, punctuation, and case) return the nationwide summary (`total_active`, `affected_oblasts`, `by_type`, `scope: "nationwide"`, `active: totalActive > 0`, and nationwide `match_count` / `matches`) instead of falsely reporting `active: false, match_count: 0`.
- **Mesh Tool Schema Clarity (`assets/mesh_tools.json`, `AlertsMeshService.defaultTools`)**:
  - Clarified `alerts_get_summary` is for Ukraine-wide / nationwide alert status & counts and `alerts_check_region` accepts a specific Ukrainian oblast, raion, or city (or `"Ukraine"` for a nationwide summary), maintaining 1:1 schema parity.
- **Tests (`alerts_mesh_service_test.dart`)**:
  - Added unit tests covering `checkRegion({'region': 'Ukraine'})`, `checkRegion({'region': 'Україна'})`, and other nationwide aliases for both active and zero-alert states.
  - Bumped `alerts` to `1.1.5+26111313`.

## Update 1.1.4 (Nov 13, 2026) `MANIFEST CLEANUP, MESH SCHEMA PARITY & LOCALIZED FOOTER`
#### Changes
- **Android Manifest (`AndroidManifest.xml`)**:
  - Removed redundant hardcoded sibling `<package>` and `<provider>` entries from `<queries>`, relying on `m3x_mesh`'s decentralized `ACTION_MESH_NODE` intent discovery alongside standard `PROCESS_TEXT` and `VIEW` (`https`) queries.
- **Mesh Tool Schema Parity (`AlertsMeshService`)**:
  - Added `AlertsMeshService.toolsFromJsonString(...)` using `M3xTool.fromJson` and runtime asset loading of `assets/mesh_tools.json` during `init()` with a pure-Dart `defaultTools` fallback.
  - Strengthened `alerts_mesh_service_test.dart` to assert 1:1 parity on tool `name`, `app`, `packageName`, `description`, and full `parameters` JSON schemas, plus executable handler binding.
- **Localization (`SettingsPage`, `en.json`, `uk.json`)**:
  - Replaced the inline hardcoded mesh footer string in `SettingsPage` with `engine.t('settings_mesh_footer')` in both English and Ukrainian.
  - Bumped `alerts` to `1.1.4+26111312`.

## Update 1.1.3 (Nov 13, 2026) `STANDARDIZED CHANGELOG BOTTOM SHEET`
#### Changes
- **Settings UI (`SettingsPage`)**:
  - Replaced the bespoke `AlertDialog` changelog viewer with `SettingsBentoHeader.showChangelogDialog(...)`, rendering `CHANGELOG.md` inside the standardized Material 3 `DraggableScrollableSheet` modal bottom sheet with native Markdown formatting and `SelectionArea`.
- **Localization (`en.json`, `uk.json`)**:
  - Added `settings_no_changelog` empty-state translation key in English and Ukrainian.
  - Bumped `alerts` to `1.1.3+26111311`.

## Update 1.1.2 `FOREGROUND AUTO-REFRESH & LIFECYCLE GATE`
#### Changes
- **Engine (`AlertsEngine`)**:
  - Added periodic foreground auto-refresh (`defaultAutoRefreshInterval = 15s`, configurable `autoRefreshInterval`) started automatically on `init()`, while keeping `startHeadlessForMesh()` timer-free.
  - Added `setForeground(bool)` lifecycle gate to pause polling when backgrounded and immediately refresh + restart polling upon returning to the foreground.
  - Added `_disposed` guard (`_safeNotify()`) and timer cancellation in `dispose()` so late async completions never notify a disposed engine.
  - Bumped `alerts` to `1.1.2+26111310`.

## Update 1.1.1 `DISCLAIMER & INTRO COPY CLARITY`
#### Changes
- **Localization (`en.json`, `uk.json`)**:
  - Updated disclaimer and data-source copy (`settings_disclaimer_why_body`, `settings_source_unofficial_body`, `disclaimer_not_radar_*`, `disclaimer_not_exhaustive_*`) to accurately describe region-level administrative alert statuses from `alerts.in.ua` via the proxy cache rather than radar/target plotting.
  - Removed obsolete top-bar mention from `intro_location_optional_hint`.
  - Bumped `alerts` to `1.1.1+26111309`.

## Update 1.1.0 `LOCALIZATION, INTRO WIZARD & SETTINGS`
#### Changes
- **Bilingual Localization (`m3x_dict`)**:
  - Added `m3x_dict` dependency and bundled `assets/translations/` (`languages.json`, `en.json`, `uk.json`) with full English and Ukrainian support plus System Default language tracking.
  - Added localized region display helpers (`locationNameForLocale`, `alertTypeLabel`, `locationTypeLabel`) while keeping canonical Ukrainian names for `alerts.in.ua` / M3x Mesh queries.
- **First-Run Intro Wizard & Persistent Preferences**:
  - Added `alerts_intro_completed` persistence (`completeIntro()`, `resetIntro()`) and `languagePreferenceMode` / `setLanguage()` controls on `AlertsEngine` for the multi-step onboarding flow (language selection, default location picker, and mandatory 3-point safety disclaimer).
- **M3x Ecosystem & Settings Support**:
  - Bundled `CHANGELOG.md` and configured `M3x.init()` metadata parsing (`appVersionDisplay`, `appDescription`, `changelogContent`, `dependencies`) for `SettingsBentoHeader` and the dedicated Settings page.
  - Bumped `alerts` to `1.1.0+26111308`.

## Update 1.0.6 `WHOLE-OBLAST MAP STATUS, EXPANDABLE CARDS & DEFAULT LOCATION CATALOG`
#### Changes
- Added complete catalog of 27 top-level Ukrainian regions, 136 official raions, and official Ukrainian cities (`UkrainianLocations`) with strict disambiguation separating `м. Київ` from `Київська область` and `м. Севастополь` from `Автономна Республіка Крим`.
- Added `alert_level` (`red` / `yellow`) parsing, `by_level` aggregation, and whole-oblast severity indicators on the interactive Ukraine map.
- Added proportional Red / Yellow / Accent gradient hero card and expandable oblast alert cards.

## Update 1.0.3 `FIXED CLOUDFLARE WORKER ENDPOINT & CACHING`
#### Changes
- Switched live alert fetching to the fixed `https://alerts.puzzak.workers.dev/v1/active.json` endpoint with 8-second TTL cache, offline stale-cache fallback, and `SharedPreferences` persistence.

## Update 1.0.0 `INITIAL RELEASE — STANDALONE ALERTS & PAIOS MESH NODE`
#### Changes
- Initial Material 3 standalone Ukraine Air Alerts monitor with interactive oblast map (`UkraineOblastsMap`) and headless + foreground M3x Mesh tool hosting (`alerts_get_summary`, `alerts_check_region`, `alerts_list_active`).
