import Flutter
import UIKit
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var initialDeepLink: String?
    // Retained for the lifetime of the "open with" sheet — a local would be
    // deallocated before the user picks an app.
    private var docController: UIDocumentInteractionController?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Capture cold-start deep link
        if let url = launchOptions?[.url] as? URL {
            initialDeepLink = url.absoluteString
        }

        // Set up pull channel for Dart to request initial link
        let controller = window?.rootViewController as! FlutterViewController

        // Bridge for iOS Notification Service Extension support — exposes the
        // App Group container path + shared-Keychain helpers to Dart.
        AppGroupBridge.register(with: controller.binaryMessenger)

        let channel = FlutterMethodChannel(
            name: "com.publicos/deeplink",
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "getInitialLink" {
                result(self?.initialDeepLink)
                self?.initialDeepLink = nil
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        // "Open with" for received documents — hand a cached file to the user's
        // chosen app via UIDocumentInteractionController.
        let openChannel = FlutterMethodChannel(
            name: "com.publicos/openfile",
            binaryMessenger: controller.binaryMessenger
        )
        openChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(false); return }
            if call.method == "openFile",
               let args = call.arguments as? [String: Any],
               let path = args["path"] as? String {
                let dc = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
                dc.delegate = self
                self.docController = dc
                let presented = dc.presentOpenInMenu(
                    from: controller.view.bounds,
                    in: controller.view,
                    animated: true
                )
                result(presented)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        // Social push token: the SECOND Firebase
        // project's FCM token for this device. firebase_messaging serves the
        // default app only; the iOS SDK hands out one token per sender id on
        // top of the one APNs token, so nothing else is initialised. nil until
        // the APNs token is set (the plugin sets it at launch): the caller
        // retries at the next boot registration.
        let socialChannel = FlutterMethodChannel(
            name: "com.publicos/social_push",
            binaryMessenger: controller.binaryMessenger
        )
        socialChannel.setMethodCallHandler { call, result in
            guard call.method == "getToken",
                  let args = call.arguments as? [String: Any],
                  let senderId = args["senderId"] as? String else {
                result(FlutterMethodNotImplemented)
                return
            }
            if Messaging.messaging().apnsToken == nil {
                result(nil)
                return
            }
            Messaging.messaging().retrieveFCMToken(forSenderID: senderId) { token, error in
                if let error = error {
                    result(FlutterError(code: "TOKEN_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(token)
                }
            }
        }

        // Screenshot blocking for ONE screen: the keychain's key QR ("Add to
        // another inbox"). Other QRs stay capturable.
        let secureChannel = FlutterMethodChannel(
            name: "com.publicos/secure_screen",
            binaryMessenger: controller.binaryMessenger
        )
        secureChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "enable":
                self?.setSecureScreen(true)
                result(true)
            case "disable":
                self?.setSecureScreen(false)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// iOS has no "block screenshots" switch. The known way to keep content
    /// out of screenshots and recordings is the secure text field's layer:
    /// whatever is drawn inside it comes out blank in a capture while
    /// isSecureTextEntry is on (the trick password fields rely on). The first
    /// enable moves the window's layer into a hidden secure field once; after
    /// that, on/off is just the field's isSecureTextEntry.
    private var secureField: UITextField?

    private func setSecureScreen(_ on: Bool) {
        guard let window = window else { return }
        if secureField == nil {
            if !on { return }
            let field = UITextField()
            field.isSecureTextEntry = true
            field.isUserInteractionEnabled = false
            field.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(field)
            field.centerXAnchor.constraint(equalTo: window.centerXAnchor).isActive = true
            field.centerYAnchor.constraint(equalTo: window.centerYAnchor).isActive = true
            window.layer.superlayer?.addSublayer(field.layer)
            // The secure container is the field's first sublayer before
            // iOS 17 and its last from iOS 17 on.
            if #available(iOS 17.0, *) {
                field.layer.sublayers?.last?.addSublayer(window.layer)
            } else {
                field.layer.sublayers?.first?.addSublayer(window.layer)
            }
            secureField = field
        }
        secureField?.isSecureTextEntry = on
    }

    // Warm-start custom scheme handler
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(
            name: "com.publicos/deeplink",
            binaryMessenger: controller.binaryMessenger
        )
        channel.invokeMethod("onDeepLink", arguments: url.absoluteString)
        return true
    }
}

extension AppDelegate: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        return window?.rootViewController ?? UIViewController()
    }
}
