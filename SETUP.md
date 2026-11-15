# Setup

This repository ships placeholders where the official build has its own
service identifiers. Replace them with your own before building. Written for
coders and for AI coding agents: every step names the file and the field.

## 1. Firebase (push notifications only)

Firebase is used only for push notifications through Firebase Cloud Messaging.
The app uses two Firebase projects: the default one for message pushes and a
second one for social pushes.

1. Create a Firebase project and add an Android app (package `com.publicos.dev`,
   or your own id, see step 3) and an iOS app (same bundle id).
2. Default project, either run `flutterfire configure` (it rewrites the four
   files below) or fill them by hand:
   - `android/app/google-services.json`: replace the file with the one Firebase
     gives you (`project_number`, `project_id`, `storage_bucket`,
     `mobilesdk_app_id`, `current_key`).
   - `ios/Runner/GoogleService-Info.plist`: replace the file with the one
     Firebase gives you (`API_KEY`, `GCM_SENDER_ID`, `PROJECT_ID`,
     `STORAGE_BUCKET`, `GOOGLE_APP_ID`).
   - `lib/firebase_options.dart`: in `android` and `ios`, set `apiKey`, `appId`,
     `messagingSenderId`, `projectId`, `storageBucket`.
   - `firebase.json`: `projectId` (twice) and the Android and iOS `appId`
     values. Only the FlutterFire CLI reads this file.
3. Second project (optional), for social pushes: create another Firebase
   project with an Android and an iOS app, then set the constants of
   `SocialFirebaseOptions` in `lib/social_push.dart`: `projectId`, `senderId`,
   `androidAppId`, `androidApiKey`, `iosAppId`, `iosApiKey`. No config file is
   needed for it; the values are passed to native code at runtime.
   Without it the social push token cannot be fetched, so social pushes do not
   arrive. Message pushes and the rest of the app do not depend on it.

## 2. Developer gate

`lib/pages/app_settings_page.dart`, constant `_devAddress` (placeholder: the
zero address). Set it to your own session address to unlock the developer
options in your build. Left as is, those options stay hidden.

## 3. Apple

1. Team id: in `ios/Runner.xcodeproj/project.pbxproj` replace every
   `DEVELOPMENT_TEAM = YOUR_TEAM_ID;` (6 places), or pick your team in Xcode
   for the `Runner` and `NotificationService` targets.
2. Bundle ids (still the official ones, change them to your own):
   `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj`:
   `com.publicos.dev`, `com.publicos.dev.NotificationService`,
   `com.publicos.dev.RunnerTests`. Also `com.publicos.dev` and
   `com.publicos.dev.message_sync` in `ios/Runner/Info.plist`, `BUNDLE_ID` in
   `ios/Runner/GoogleService-Info.plist` and `iosBundleId` in
   `lib/firebase_options.dart`.
3. App group, placeholder `group.YOUR.BUNDLE.ID.shared`. Set the same value in:
   - `ios/Runner/Runner.entitlements`
   - `ios/NotificationService/NotificationService.entitlements`
   - `ios/Runner/AppGroupBridge.swift` (`appGroupId`)
   - `ios/NotificationService/NotificationService.swift` (`kAppGroupId`)
4. Keychain access group, placeholder `$(AppIdentifierPrefix)YOUR.BUNDLE.ID.shared`
   in the same two entitlements files, and its suffix `YOUR.BUNDLE.ID.shared` in
   `ios/Runner/AppGroupBridge.swift` (`keychainAccessGroupSuffix`) and
   `ios/NotificationService/NotificationService.swift`
   (`kKeychainAccessGroupSuffix`). The four values must match.
5. `ios/Runner/Runner.entitlements` also declares the associated domain
   `applinks:publicos.dev`; a fork with its own links changes it.

On Android the application id is `com.publicos.dev` in
`android/app/build.gradle.kts` (`namespace` and `applicationId`); it must match
`package_name` in `google-services.json`.

## 4. Android signing

Release builds read `android/key.properties` (git-ignored). Create it with:

```
storeFile=/absolute/path/to/your-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

`android/app/build.gradle.kts` loads these four keys into the `release`
signing config. Debug builds (`flutter run`) do not need the file.

## 5. Dependencies

`pubspec.yaml` takes the PublicOS packages by git from
`https://github.com/PublicOS-dev/` (`publicos_core`, `publicos_web3_bridge`,
`zero_mentions`, and the overrides `video_player_android`, `zero_cached_video`,
`zero_cached_thumbnail`, `webview_flutter_android`, `webview_flutter_wkwebview`).
Nothing to clone by hand: `flutter pub get` fetches them.
