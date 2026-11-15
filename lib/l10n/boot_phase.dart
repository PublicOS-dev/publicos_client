import 'package:publicos_client/l10n/app_localizations.dart';

/// Boot / init progress phases.
///
/// `app_initializer` runs with no `BuildContext`, so it can't localize. It
/// emits these as `.name` codes through the existing String channels
/// (`AppStateNotifier.setLoadingMessage` / the `runBoot` `onStatus` sink); the
/// loader widgets (InitializationScreen, the select-account screen) map the
/// code → a localized label via [bootPhaseLabel].
enum BootPhase {
  initializing,
  checkingAuth,
  checkingLogin,
  restoringSession,
  connectingChain,
  loadingKeys,
  connectingFeed,
  loadingMessages,
  settingUpNotifs,
  opening,
}

/// Stable error codes `app_initializer` puts on `AppStateNotifier.errorMessage`.
class BootErr {
  static const coreInit = 'BOOT_ERR_CORE_INIT';
  static const authNeeded = 'BOOT_ERR_AUTH_NEEDED';
  static const unexpected = 'BOOT_ERR_UNEXPECTED';
}

/// Map a [BootPhase] `.name` code (or null/unknown) → a localized loader label.
/// Unknown input is returned verbatim (e.g. a `lastError` that slipped through).
String? bootPhaseLabel(AppLocalizations l10n, String? code) {
  switch (code) {
    case 'initializing':
      return l10n.bootInitializing;
    case 'checkingAuth':
      return l10n.bootCheckingAuth;
    case 'checkingLogin':
      return l10n.bootCheckingLogin;
    case 'restoringSession':
      return l10n.bootRestoringSession;
    case 'connectingChain':
      return l10n.bootConnectingChain;
    case 'loadingKeys':
      return l10n.bootLoadingKeys;
    case 'connectingFeed':
      return l10n.bootConnectingFeed;
    case 'loadingMessages':
      return l10n.bootLoadingMessages;
    case 'settingUpNotifs':
      return l10n.bootSettingUpNotifs;
    case 'opening':
      return l10n.bootOpening;
    default:
      return code;
  }
}

/// Map a [BootErr] code → localized error copy. Returns null when [code] isn't a
/// boot-error code, so the caller can fall back to `localizedError` for a raw
/// (e.g. `PublicOS.lastError`) value.
String? bootErrorLabel(AppLocalizations l10n, String? code) {
  switch (code) {
    case BootErr.coreInit:
      return l10n.bootErrCoreInit;
    case BootErr.authNeeded:
      return l10n.bootErrAuthNeeded;
    case BootErr.unexpected:
      return l10n.bootErrUnexpected;
    default:
      return null;
  }
}
