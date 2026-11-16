import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:publicos_core/publicos_core.dart';

/// Human-readable names for the BCP-47 base codes ML Kit translates. Used by
/// post + comment widgets in legend copy ("Translate from German"). Falls
/// back to upper-case code at the call site for codes not listed here.
const kPostLangNames = <String, String>{
  'af': 'Afrikaans', 'ar': 'Arabic', 'be': 'Belarusian', 'bg': 'Bulgarian',
  'bn': 'Bengali', 'ca': 'Catalan', 'cs': 'Czech', 'cy': 'Welsh',
  'da': 'Danish', 'de': 'German', 'el': 'Greek', 'en': 'English',
  'eo': 'Esperanto', 'es': 'Spanish', 'et': 'Estonian', 'fa': 'Persian',
  'fi': 'Finnish', 'fr': 'French', 'ga': 'Irish', 'gl': 'Galician',
  'gu': 'Gujarati', 'he': 'Hebrew', 'hi': 'Hindi', 'hr': 'Croatian',
  'ht': 'Haitian', 'hu': 'Hungarian', 'id': 'Indonesian', 'is': 'Icelandic',
  'it': 'Italian', 'ja': 'Japanese', 'ka': 'Georgian', 'kn': 'Kannada',
  'ko': 'Korean', 'lt': 'Lithuanian', 'lv': 'Latvian', 'mk': 'Macedonian',
  'mr': 'Marathi', 'ms': 'Malay', 'mt': 'Maltese', 'nl': 'Dutch',
  'no': 'Norwegian', 'pl': 'Polish', 'pt': 'Portuguese', 'ro': 'Romanian',
  'ru': 'Russian', 'sk': 'Slovak', 'sl': 'Slovenian', 'sq': 'Albanian',
  'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil', 'te': 'Telugu',
  'th': 'Thai', 'tl': 'Tagalog', 'tr': 'Turkish', 'uk': 'Ukrainian',
  'ur': 'Urdu', 'vi': 'Vietnamese', 'zh': 'Chinese',
};

/// Single-file, on-device post translation helper.
///
/// Design constraints:
/// - **100% on-device.** Translation runs through Google ML Kit; the text never
///   leaves the phone. No API key, no account, no server call for translation.
/// - **Zero persistence.** This class stores nothing — no translations, no
///   detected-language labels. Callers hold results in transient widget state.
///   (The ~30MB language packs ML Kit downloads on first use are cached by
///   ML Kit itself on disk; that is ML Kit's storage, not ours.)
/// - **Mobile only.** ML Kit exists on Android + iOS only. Guard every call
///   site with [isSupported]; on web/desktop the affordance must not appear.
///
/// Usage from a post widget:
/// ```dart
/// final svc = TranslationService.instance;
/// final src = await svc.detect(post.body);            // 'es' | null
/// if (src != null && src != svc.deviceLanguage) {
///   // show "Translate from {src} to {svc.deviceLanguage}" legend
/// }
/// // on tap (after disclosing ~30MB if !isModelReady):
/// final body  = await svc.translate(post.body,  from: src!, to: svc.deviceLanguage);
/// final title = await svc.translate(post.title, from: src,  to: svc.deviceLanguage);
/// ```
class TranslationService {
  TranslationService._();
  static final TranslationService instance = TranslationService._();

  /// ML Kit is Android + iOS only. False everywhere else.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  final LanguageIdentifier _identifier =
      LanguageIdentifier(confidenceThreshold: 0.5);
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  /// Cache of live translator instances keyed "from-to". They hold native
  /// resources, so they are reused and closed in [dispose]. This is in-memory
  /// only and does not survive an app restart — not persistence of content.
  final Map<String, OnDeviceTranslator> _translators = {};

  /// Device UI language as a BCP-47 base code, e.g. 'en', 'es'.
  String get deviceLanguage =>
      ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();

  /// Detect the language of [text]. Returns a BCP-47 base code (e.g. 'es') or
  /// null when undetermined / below the confidence threshold. Uses the small
  /// built-in language-ID model (no download, fully offline, sub-ms).
  Future<String?> detect(String text) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    try {
      final code = await _identifier.identifyLanguage(t);
      if (code == 'und') return null;
      return _base(code);
    } catch (_) {
      return null;
    }
  }

  /// True when both packs for the pair are already on disk (no download needed).
  /// Drives the cost-disclosure decision before [translate].
  Future<bool> isModelReady(String from, String to) async {
    final f = _lang(from), t = _lang(to);
    if (f == null || t == null) return false;
    return await _modelManager.isModelDownloaded(f.bcpCode) &&
        await _modelManager.isModelDownloaded(t.bcpCode);
  }

  /// Download any missing packs for the pair (~30MB each). Caller should show
  /// the cost first when [isModelReady] is false. [requireWifi] defaults true.
  Future<void> ensureModel(String from, String to,
      {bool requireWifi = true}) async {
    final f = _lang(from), t = _lang(to);
    if (f == null || t == null) {
      throw ArgumentError('Unsupported translation pair: $from -> $to');
    }
    if (!await _modelManager.isModelDownloaded(f.bcpCode)) {
      await _modelManager.downloadModel(f.bcpCode, isWifiRequired: requireWifi);
    }
    if (!await _modelManager.isModelDownloaded(t.bcpCode)) {
      await _modelManager.downloadModel(t.bcpCode, isWifiRequired: requireWifi);
    }
  }

  /// Translate [text] from->to, downloading packs if needed. Returns [text]
  /// unchanged when the pair is unsupported or equal.
  Future<String> translate(String text,
      {required String from, required String to, bool requireWifi = true}) async {
    if (text.trim().isEmpty) return text;
    final f = _lang(from), t = _lang(to);
    if (f == null || t == null || f == t) return text;
    await ensureModel(from, to, requireWifi: requireWifi);
    final translator = _translators.putIfAbsent(
      '${f.bcpCode}-${t.bcpCode}',
      () => OnDeviceTranslator(sourceLanguage: f, targetLanguage: t),
    );
    return translator.translateText(text);
  }

  /// Whether ML Kit can translate this pair at all.
  bool supportsPair(String from, String to) =>
      _lang(from) != null && _lang(to) != null;

  /// Release native resources. Call on app teardown, not per-post.
  Future<void> dispose() async {
    await _identifier.close();
    for (final tr in _translators.values) {
      await tr.close();
    }
    _translators.clear();
  }

  // --- helpers ---------------------------------------------------------------

  String _base(String code) => code.split('-').first.toLowerCase();

  /// Map a BCP-47 base code to an ML Kit [TranslateLanguage], or null.
  TranslateLanguage? _lang(String code) =>
      BCP47Code.fromRawValue(_base(code));
}

/// User preferences for the on-device translation affordance. Keys live at
/// the UI layer (no Core typed wrapper — no SDK-internal side effects), but
/// the values are persisted through Core's generic settings store so they
/// round-trip across devices on the same account.
///
/// Two knobs:
/// - **enabled** — master on/off. Off ⇒ no detect call, no hint anywhere.
/// - **disabled sources** — set of BCP-47 base codes the user has marked
///   "I read this fluently, don't suggest." Default empty (suggest from
///   every detected source language that isn't the device locale).
///
/// In-memory cache avoids hammering the settings DB on every PostCard /
/// CommentCard init. Cache is dropped on every write so toggling in the
/// settings sheet propagates to the next card that mounts.
class TranslationPrefs {
  TranslationPrefs._();

  /// Persistence keys (kept stable — changing them resets every user's prefs).
  static const String kEnabledKey = 'post_translation_enabled';
  static const String kDisabledSourcesKey = 'post_translation_disabled_sources';
  static const String kWifiOnlyKey = 'post_translation_wifi_only';

  static bool? _enabledCache;
  static Set<String>? _disabledCache;
  static bool? _wifiOnlyCache;

  /// True when the user wants translate hints to appear. Default true.
  static Future<bool> isEnabled() async {
    if (_enabledCache != null) return _enabledCache!;
    try {
      final r = await PublicOSSettings.getSetting(kEnabledKey);
      final v = r?.value;
      _enabledCache = v == null ? true : v == 'true';
    } catch (_) {
      _enabledCache = true;
    }
    return _enabledCache!;
  }

  static Future<void> setEnabled(bool value) async {
    _enabledCache = value;
    try {
      final record = Record.asSettings(
        key: kEnabledKey,
        value: value ? 'true' : 'false',
        isSystem: true,
      );
      await PublicOSSettings.setSetting(kEnabledKey, record);
    } catch (_) {}
  }

  /// Whether language packs may download over mobile data. Default true
  /// (Wi-Fi only) — flip OFF to let a translate download its ~30 MB pack over
  /// cellular instead of waiting for Wi-Fi. Drives the `requireWifi` arg of
  /// [ensureModel] / [translate] at the call sites.
  static Future<bool> wifiOnly() async {
    if (_wifiOnlyCache != null) return _wifiOnlyCache!;
    try {
      final r = await PublicOSSettings.getSetting(kWifiOnlyKey);
      final v = r?.value;
      _wifiOnlyCache = v == null ? true : v == 'true';
    } catch (_) {
      _wifiOnlyCache = true;
    }
    return _wifiOnlyCache!;
  }

  static Future<void> setWifiOnly(bool value) async {
    _wifiOnlyCache = value;
    try {
      final record = Record.asSettings(
        key: kWifiOnlyKey,
        value: value ? 'true' : 'false',
        isSystem: true,
      );
      await PublicOSSettings.setSetting(kWifiOnlyKey, record);
    } catch (_) {}
  }

  /// Set of source language codes the user has toggled OFF. Default empty.
  static Future<Set<String>> disabledSources() async {
    if (_disabledCache != null) return _disabledCache!;
    try {
      final r = await PublicOSSettings.getSetting(kDisabledSourcesKey);
      final raw = r?.value ?? '';
      _disabledCache = raw.isEmpty
          ? <String>{}
          : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
    } catch (_) {
      _disabledCache = <String>{};
    }
    return _disabledCache!;
  }

  /// Should we suggest translating from [code]? True when global toggle is on
  /// AND the code is not on the user's disabled list. Caller still has to
  /// check that [code] differs from the device locale.
  static Future<bool> isSourceSuggested(String code) async {
    if (!await isEnabled()) return false;
    final disabled = await disabledSources();
    return !disabled.contains(code);
  }

  /// Flip a single language on/off. `suggested=false` adds to the disabled
  /// set; `suggested=true` removes it.
  static Future<void> setSourceSuggested(String code, bool suggested) async {
    final current = await disabledSources();
    final next = Set<String>.from(current);
    if (suggested) {
      next.remove(code);
    } else {
      next.add(code);
    }
    _disabledCache = next;
    try {
      final record = Record.asSettings(
        key: kDisabledSourcesKey,
        value: next.toList().join(','),
        isSystem: true,
      );
      await PublicOSSettings.setSetting(kDisabledSourcesKey, record);
    } catch (_) {}
  }

  /// Restore defaults: enabled=true, no disabled sources.
  static Future<void> reset() async {
    await setEnabled(true);
    await setWifiOnly(true);
    _disabledCache = <String>{};
    try {
      final record = Record.asSettings(
        key: kDisabledSourcesKey,
        value: '',
        isSystem: true,
      );
      await PublicOSSettings.setSetting(kDisabledSourcesKey, record);
    } catch (_) {}
  }
}
