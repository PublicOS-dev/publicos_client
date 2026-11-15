//
// NotificationService.swift
// publicos_client iOS Notification Service Extension
//
// Wakes on `mutable-content: 1` APNs pushes. Decrypts the XMTP ciphertext via
// the shared App Group + Keychain access group, looks up sender/group/avatar
// from the shared contacts DB + zero_cached_image cache, mutates
// bestAttemptContent, hands back to iOS.
//
// On any failure (decrypt fail, contact lookup fail, container nil) it falls
// through to whatever bestAttemptContent already carries — which is the
// `Alert{Title:"New message"}` placeholder publicos_notif_server stuffs into
// every payload. So worst case the user sees what they see today.
//

import UserNotifications
import XMTP
import CryptoKit
import Security

let kAppGroupId = "group.YOUR.BUNDLE.ID.shared"
let kKeychainAccessGroupSuffix = "YOUR.BUNDLE.ID.shared"
// This device's social blob key K_s, mirrored by the app under a fixed name
// (lib/ios/ios_app_group.dart::mirrorSocialKey) because the extension knows
// no session address. Stored base64, like the XMTP DB key.
let kSocialKsSharedName = "social_ks_active"

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let attempt = bestAttempt else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo

        // A SOCIAL push: `{type: social, id, handle,
        // blob}` from the gateway's second Firebase project. No XMTP client is
        // needed: open the blob with this device's K_s from the shared
        // keychain, write the sentence, attach the actor's avatar. Any failure
        // leaves the "New activity" placeholder the gateway stuffed in.
        if let type = userInfo["type"] as? String, type == "social" {
            renderSocial(userInfo: userInfo, into: attempt)
            contentHandler(attempt)
            return
        }

        guard
            let encryptedB64 = userInfo["encryptedMessage"] as? String,
            let topic = userInfo["topic"] as? String,
            let encrypted = Data(base64Encoded: encryptedB64)
        else {
            NSLog("[NSE] payload missing encryptedMessage/topic — delivering placeholder")
            contentHandler(attempt)
            return
        }

        // Server-side keys: `messageType` (camelCase) is the canonical APNs
        // custom-data key emitted by publicos_notif_server's
        // buildFcmApnsCustomData. The snake_case alias is checked too as a
        // belt-and-braces against any upstream xmtp/example-notification-server-go
        // payload renames.
        let messageType = (userInfo["messageType"] as? String)
            ?? (userInfo["message_type"] as? String)
            ?? ""
        let isWelcome = messageType == "v3-welcome" || topic.contains("/w-")

        Task {
            do {
                let identity = try loadActiveIdentity()
                let dbKey = try loadXmtpDbKey(named: identity.dbKeychainKey)

                let env = resolveEnvironment(identity.environment)
                let options = ClientOptions(
                    api: ClientOptions.Api(env: env, isSecure: env != .local),
                    dbEncryptionKey: dbKey,
                    dbDirectory: identity.dbDir
                )

                XMTP.Client.register(codec: TextCodec())

                let publicIdentity = PublicIdentity(
                    kind: .ethereum,
                    identifier: identity.walletAddress
                )
                let client = try await XMTP.Client.build(
                    publicIdentity: publicIdentity,
                    options: options,
                    inboxId: identity.inboxId
                )

                if isWelcome {
                    try await renderWelcome(client: client, encrypted: encrypted, into: attempt, topic: topic)
                } else {
                    try await renderMessage(client: client, encrypted: encrypted, into: attempt, topic: topic)
                }

                attempt.threadIdentifier = topic
                contentHandler(attempt)
            } catch {
                NSLog("[NSE] enrichment failed: \(error.localizedDescription) — delivering placeholder")
                contentHandler(attempt)
            }
        }
    }

    // MARK: - Social pushes
    //
    // The Swift twin of publicos_client's `notifSentence` for the six social
    // kinds (utils/notification_kinds.dart). The extension shares
    // no code with Dart, so keep the two in step BY HAND, like
    // `messagePreview(for:)` below.

    private func renderSocial(userInfo: [AnyHashable: Any],
                              into attempt: UNMutableNotificationContent) {
        guard let blobB64 = userInfo["blob"] as? String,
              let blob = Data(base64Encoded: blobB64) else {
            NSLog("[NSE] social push without a blob — delivering placeholder")
            return
        }
        do {
            let key = try loadXmtpDbKey(named: kSocialKsSharedName)
            let fields = try openSocialBlob(blob, key: key)
            let kind = fields["kind"] as? String ?? ""
            let actor = fields["actor"] as? String ?? ""
            let itemUrl = fields["item_url"] as? String ?? ""
            let postUrl = fields["post_url"] as? String ?? ""

            let contact = lookupContactByAddress(actor)
            let name = (contact?.displayName).flatMap { $0.isEmpty ? nil : $0 }
                ?? shortAddress(actor)
            attempt.title = "PublicOS"
            attempt.body = socialSentence(kind: kind, who: name,
                                          isComment: itemUrl.contains("#comment-"))
            // Quote the real text, read from where it is published.
            if let preview = fetchSocialPreview(kind: kind, itemUrl: itemUrl) {
                attempt.body += ": \"\(preview)\""
            }
            if !postUrl.isEmpty { attempt.threadIdentifier = postUrl }
            if let avatarUrl = contact?.avatarUrl,
               let attachment = avatarAttachment(for: avatarUrl) {
                attempt.attachments = [attachment]
            }
        } catch {
            NSLog("[NSE] social blob did not open: \(error.localizedDescription) — delivering placeholder")
        }
    }

    /// base64(nonce ‖ ciphertext ‖ tag), AES-256-GCM, 12-byte nonce, no AAD —
    /// the layout the SSP server seals with and
    /// Core's `SocialCrypto.openBlob` opens.
    private func openSocialBlob(_ data: Data, key: Data) throws -> [String: Any] {
        guard data.count > 12 + 16 else { throw NSEError.manifestMalformed }
        let nonce = try AES.GCM.Nonce(data: data.prefix(12))
        let tag = data.suffix(16)
        let ciphertext = data.subdata(in: 12..<(data.count - 16))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        guard let obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw NSEError.manifestMalformed
        }
        return obj
    }

    private func socialSentence(kind: String, who: String, isComment: Bool) -> String {
        let es = Locale.preferredLanguages.first?.hasPrefix("es") ?? false
        switch kind {
        case "comment":
            return es ? "\(who) comentó tu publicación" : "\(who) commented on your post"
        case "reply":
            return es ? "\(who) respondió a tu comentario" : "\(who) replied to your comment"
        case "mention":
            return es ? "\(who) te mencionó" : "\(who) mentioned you"
        case "reaction":
            if isComment {
                return es ? "\(who) reaccionó a tu comentario" : "\(who) reacted to your comment"
            }
            return es ? "\(who) reaccionó a tu publicación" : "\(who) reacted to your post"
        case "follow_request":
            return es ? "\(who) pidió seguir tu canal" : "\(who) asked to follow your channel"
        case "follow_approved":
            return es ? "\(who) te aceptó en su canal" : "\(who) let you into their channel"
        default:
            return es ? "Nueva actividad" : "New activity"
        }
    }

    /// The Swift twin of publicos_client's `socialPreview`
    /// (utils/social_notifs.dart): the comment's `content` through the single-comment
    /// route (`…#comment-<uid>` → `…/comments/<uid>`), or the post's title /
    /// `content_text`. Unsigned: a private channel answers 401 and the sentence
    /// stands alone. 2.5 s budget inside the extension's 30 s. Nil on anything.
    private func fetchSocialPreview(kind: String, itemUrl: String) -> String? {
        if kind == "follow_request" || kind == "follow_approved" || itemUrl.isEmpty { return nil }
        var urlString = itemUrl
        var wantComment = false
        if let r = itemUrl.range(of: "#comment-") {
            urlString = String(itemUrl[..<r.lowerBound]) + "/comments/" + String(itemUrl[r.upperBound...])
            wantComment = true
        }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        let done = DispatchSemaphore(value: 0)
        var text: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if wantComment {
                guard let comment = obj["comment"] as? [String: Any],
                      (comment["is_deleted"] as? Bool) != true else { return }
                text = comment["content"] as? String
            } else {
                let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                text = title.isEmpty ? (obj["content_text"] as? String) : title
            }
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return trimPreview(text)
    }

    /// One line, whitespace collapsed, at most 80 characters with an ellipsis.
    private func trimPreview(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let one = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if one.isEmpty { return nil }
        if one.count <= 80 { return one }
        return String(one.prefix(79)) + "\u{2026}"
    }

    private func shortAddress(_ hex: String) -> String {
        guard hex.count > 10 else { return hex }
        return "\(hex.prefix(6))…\(hex.suffix(4))"
    }

    private func lookupContactByAddress(_ address: String) -> ContactRow? {
        guard let db = openContactsDb() else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT display_name, records
        FROM contacts
        WHERE publicos_address = ? COLLATE NOCASE
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (address as NSString).utf8String, -1, nil)
        return readContactRow(stmt: stmt)
    }

    override func serviceExtensionTimeWillExpire() {
        NSLog("[NSE] time expired — delivering best attempt")
        if let handler = contentHandler, let attempt = bestAttempt {
            handler(attempt)
        }
    }

    // MARK: - Message preview
    //
    // The Swift twin of PublicOSConversations.formatMessagePreview (Core,
    // publicos_conversations.dart). The NSE is Swift and shares NO code with
    // Dart, so the two must be kept in step BY HAND — if you add a content type
    // to one, add it to the other.
    //
    // Why this exists at all: `decoded.body` is
    //     content() as? String ?? encodedContent.fallback
    // and `fallback` is a proto3 string, i.e. "" whenever the sender never set
    // one — which xmtp_plugin's send path never does. So every non-text content
    // type used to render as an EMPTY notification body. `?? "New message"`
    // did not rescue it: that only fires on a THROW, not on an empty string.

    /// One-line preview for a decoded message. Never returns "".
    private func messagePreview(for decoded: DecodedMessage) -> String {
        // Text: the happy path, unchanged.
        if let text = try? decoded.content() as String, !text.isEmpty {
            return text
        }

        // Anything else: switch on the wire content type and decode the JSON
        // ourselves. The transaction codecs are OURS (registered in the Dart
        // plugin), so the Swift SDK has no codec for them and `body` is blank.
        guard let encoded = try? decoded.encodedContent else {
            return "New message"
        }
        let typeID = encoded.type.typeID
        let json = (try? JSONSerialization.jsonObject(with: encoded.content))
            as? [String: Any]

        switch typeID {
        case "transactionReference":
            return receiptPreview(json)
        case "walletSendCalls":
            return requestPreview(json)
        default:
            break
        }

        // A sender-set fallback is better than nothing; otherwise a generic.
        if let fallback = try? decoded.fallback, !fallback.isEmpty {
            return fallback
        }
        return "New message"
    }

    /// A receipt — "someone paid you".
    ///
    /// `metadata.amount` is the RAW on-chain integer paired with `decimals`.
    /// It is SENDER-SUPPLIED and only advisory: a non-conformant sender stamps
    /// the *human* value (4.0) alongside decimals:18, which divides down to ~0.
    /// `tokenAmountText` returns nil in that case and we drop the number —
    /// a notification must never announce a payment of zero.
    private func receiptPreview(_ json: [String: Any]?) -> String {
        // Tolerate a wrapped envelope: {"transactionReference": {...}}.
        let obj = (json?["transactionReference"] as? [String: Any]) ?? json
        guard let meta = obj?["metadata"] as? [String: Any],
              let amount = (meta["amount"] as? NSNumber)?.doubleValue,
              let decimals = (meta["decimals"] as? NSNumber)?.intValue,
              let text = tokenAmountText(amount, decimals,
                                         meta["currency"] as? String)
        else {
            return "sent you a payment 💸"
        }
        return "sent you \(text) 💸"
    }

    /// A payment request (an invoice).
    ///
    /// The authoritative amount lives in the ERC-20 calldata, not the metadata —
    /// but decoding it needs a token registry (to turn a contract address into
    /// symbol + decimals), which an NSE has no way to consult and no budget for
    /// a chain read. So we read the SELF-DESCRIBING metadata our own sender now
    /// writes (`currency` / `amount` / `decimals` — see message_input.dart).
    ///
    /// Advisory, exactly like a receipt's: it gets the same zero guard, and a
    /// sender that omits or botches it degrades to the description, then to a
    /// generic. Android does NOT rely on this — it decodes the calldata, which
    /// can't lie.
    private func requestPreview(_ json: [String: Any]?) -> String {
        guard let calls = json?["calls"] as? [[String: Any]] else {
            return "requested a payment 🧾"
        }

        for call in calls {
            guard let meta = call["metadata"] as? [String: Any] else { continue }
            // `amount` rides as a decimal STRING (raw base units) — a JSON
            // number would lose precision on an 18-decimal value.
            let raw: Double?
            if let s = meta["amount"] as? String {
                raw = Double(s)
            } else {
                raw = (meta["amount"] as? NSNumber)?.doubleValue
            }
            if let amount = raw,
               let decimals = (meta["decimals"] as? NSNumber)?.intValue,
               let text = tokenAmountText(amount, decimals,
                                          meta["currency"] as? String) {
                return "requested \(text) 🧾"
            }
        }

        // An agent's own invoice line is the next-best thing.
        for call in calls {
            if let d = (call["metadata"] as? [String: Any])?["description"]
                as? String, !d.isEmpty {
                return d.count > 100 ? String(d.prefix(100)) + "..." : d
            }
        }
        return "requested a payment 🧾"
    }

    /// Format a raw base-unit amount, or nil when it renders as zero.
    /// Integer math on the digit string — no Double division, which would lose
    /// precision on an 18-decimal value long before it mattered.
    private func tokenAmountText(_ amount: Double, _ decimals: Int,
                                 _ symbol: String?) -> String? {
        guard amount > 0, decimals >= 0 else { return nil }
        var digits = String(format: "%.0f", amount)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }

        var text: String
        if decimals == 0 {
            text = digits
        } else {
            if digits.count <= decimals {
                digits = String(repeating: "0", count: decimals - digits.count + 1)
                    + digits
            }
            let split = digits.index(digits.endIndex, offsetBy: -decimals)
            let whole = String(digits[digits.startIndex..<split])
            var frac = String(digits[split...])
            while frac.hasSuffix("0") { frac.removeLast() }
            if frac.count > 6 { frac = String(frac.prefix(6)) }  // display cap
            text = frac.isEmpty ? whole : "\(whole).\(frac)"
        }

        // The display cap collapses anything under 1e-6 to a bare "0" — refuse
        // it. This is the guard for the "0 OX" bug described above.
        if (Double(text) ?? 0) == 0 { return nil }

        if let s = symbol, !s.isEmpty { return "\(text) \(s)" }
        return text
    }

    // MARK: - Render paths

    private func renderMessage(client: XMTP.Client,
                               encrypted: Data,
                               into attempt: UNMutableNotificationContent,
                               topic: String) async throws {
        guard let conversation = try await client.conversations.findConversationByTopic(topic: topic) else {
            NSLog("[NSE] no local conversation for topic \(topic)")
            return
        }
        guard let decoded = try await conversation.processMessage(messageBytes: encrypted) else {
            NSLog("[NSE] processMessage returned nil")
            return
        }

        let preview = messagePreview(for: decoded)
        let senderInboxId = decoded.senderInboxId

        let sender = lookupContactByInboxId(senderInboxId)
        let senderName = sender?.displayName ?? shortInboxId(senderInboxId)

        var isGroup = false
        switch conversation {
        case .group: isGroup = true
        case .dm:    isGroup = false
        }

        if isGroup {
            let group = lookupContactByTopic(topic)
            attempt.title = group?.displayName ?? "Group"
            attempt.body = "\(senderName): \(preview)"
        } else {
            attempt.title = senderName
            attempt.body = preview
        }

        if let avatarUrl = sender?.avatarUrl,
           let attachment = avatarAttachment(for: avatarUrl) {
            attempt.attachments = [attachment]
        }
    }

    private func renderWelcome(client: XMTP.Client,
                               encrypted: Data,
                               into attempt: UNMutableNotificationContent,
                               topic: String) async throws {
        guard let conversation = try await client.conversations.fromWelcome(envelopeBytes: encrypted) else {
            NSLog("[NSE] fromWelcome returned nil")
            return
        }
        switch conversation {
        case .group(let group):
            let name = (try? group.name()) ?? "New group"
            attempt.title = name
            attempt.body = "You were added to the group"
        case .dm:
            attempt.title = "New conversation"
            attempt.body = "Tap to open"
        }
    }

    // MARK: - Active identity

    private struct ActiveIdentity {
        let inboxId: String
        let walletAddress: String
        let environment: String
        let dbDir: String
        let dbKeychainKey: String
    }

    private func loadActiveIdentity() throws -> ActiveIdentity {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) else {
            throw NSEError.appGroupUnavailable
        }
        let manifest = container.appendingPathComponent("active_xmtp.json")
        let data = try Data(contentsOf: manifest)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inboxId = json["inboxId"] as? String,
              let walletAddress = json["walletAddress"] as? String,
              let environment = json["environment"] as? String,
              let dbDir = json["dbDir"] as? String,
              let dbKeychainKey = json["dbKeychainKey"] as? String
        else {
            throw NSEError.manifestMalformed
        }
        return ActiveIdentity(
            inboxId: inboxId,
            walletAddress: walletAddress,
            environment: environment,
            dbDir: dbDir,
            dbKeychainKey: dbKeychainKey
        )
    }

    private func resolveEnvironment(_ env: String) -> XMTPEnvironment {
        switch env.lowercased() {
        case "dev":   return .dev
        case "local": return .local
        default:      return .production
        }
    }

    // MARK: - Keychain (shared access group)

    /// Reads a key written by flutter_secure_storage on the iOS side. The
    /// Dart package stores values as `kSecClassGenericPassword` with the
    /// account == key name and service == flutter_secure_storage's default
    /// service. Reading back from the shared access group requires the same
    /// access-group entitlement and the same service string.
    private func loadXmtpDbKey(named keyName: String) throws -> Data {
        let accessGroup = "\(appIdentifierPrefix())\(kKeychainAccessGroupSuffix)"

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyName,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // flutter_secure_storage_darwin defaults service to "flutter_secure_storage_service"
        query[kSecAttrService as String] = "flutter_secure_storage_service"

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSEError.keychainRead(status: status)
        }
        // flutter_secure_storage stores the value as a UTF-8 string; here that
        // string is the base64-encoded 32-byte DB key.
        if let str = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: str) {
            return decoded
        }
        // Fallback: caller stored raw bytes directly.
        return data
    }

    private func appIdentifierPrefix() -> String {
        // Resolves the team-id prefix by reading our own bundle seed via a
        // throwaway keychain query — Apple's documented way for extensions.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bundleSeedID",
            kSecAttrService as String: "",
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, &result)
        }
        if let attrs = result as? [String: Any],
           let accessGroup = attrs[kSecAttrAccessGroup as String] as? String {
            if let prefix = accessGroup.components(separatedBy: ".").first {
                return "\(prefix)."
            }
        }
        return ""
    }

    // MARK: - Contacts DB (raw sqlite3)

    private struct ContactRow {
        let displayName: String
        let avatarUrl: String?
    }

    private func contactsDbPath() -> String? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) else {
            return nil
        }
        return container
            .appendingPathComponent("Library/Application Support/publicos.sqlite")
            .path
    }

    private func openContactsDb() -> OpaquePointer? {
        guard let path = contactsDbPath(),
              FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            return db
        }
        return nil
    }

    private func lookupContactByInboxId(_ inboxId: String) -> ContactRow? {
        guard let db = openContactsDb() else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT display_name, records
        FROM contacts
        WHERE registered_inbox_i_ds LIKE ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        let pattern = "%\"\(inboxId)\"%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        return readContactRow(stmt: stmt)
    }

    private func lookupContactByTopic(_ topic: String) -> ContactRow? {
        guard let db = openContactsDb() else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT display_name, records
        FROM contacts
        WHERE xmtp_conversation_topic = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (topic as NSString).utf8String, -1, nil)
        return readContactRow(stmt: stmt)
    }

    private func readContactRow(stmt: OpaquePointer?) -> ContactRow? {
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let nameCStr = sqlite3_column_text(stmt, 0)
        let recordsCStr = sqlite3_column_text(stmt, 1)
        let displayName = nameCStr.map { String(cString: $0) } ?? ""
        let recordsJson = recordsCStr.map { String(cString: $0) }
        let avatarUrl = recordsJson.flatMap { parseAvatarUrl(fromRecordsJson: $0) }
        return ContactRow(displayName: displayName, avatarUrl: avatarUrl)
    }

    /// `records` is `List<{key: "profile.avatar.resolved", value: "<url>"}>` per
    /// PublicOS_Core's record schema (also matches the avatar pipeline used by
    /// `GlassContactIcon`).
    private func parseAvatarUrl(fromRecordsJson json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for entry in arr {
            guard let key = entry["key"] as? String else { continue }
            if key == "profile.avatar.resolved", let value = entry["value"] as? String {
                return value
            }
        }
        // Fallback to the on-chain (un-resolved) avatar field if no resolved value
        for entry in arr {
            guard let key = entry["key"] as? String else { continue }
            if key == "profile.avatar", let value = entry["value"] as? String {
                return value
            }
        }
        return nil
    }

    // MARK: - Avatar attachment

    /// ZeroCacheManager's path scheme: `<root>/<sha256(url-hex)>.<ext>` where
    /// ext is the lowercased URL extension if in the allowlist, else "".
    private func avatarAttachment(for url: String) -> UNNotificationAttachment? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) else {
            return nil
        }
        let cacheDir = container.appendingPathComponent("Library/Application Support/zero_cached_image")
        let hash = sha256Hex(of: url)
        let ext = pickExtension(from: url)
        let candidate = cacheDir.appendingPathComponent("\(hash)\(ext)")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            NSLog("[NSE] avatar cache miss for \(url) → \(candidate.lastPathComponent)")
            return nil
        }
        // UNNotificationAttachment requires the file to live in a unique
        // location; iOS moves it. We copy into the extension's tmpDir first
        // so we never disturb the on-disk cache the main app reads.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(candidate.pathExtension)
        do {
            try FileManager.default.copyItem(at: candidate, to: tmp)
            return try UNNotificationAttachment(identifier: "avatar", url: tmp, options: nil)
        } catch {
            NSLog("[NSE] avatar attachment build failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func pickExtension(from url: String) -> String {
        let allow: Set<String> = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"]
        let lower = url.lowercased()
        for ext in allow {
            if lower.hasSuffix(ext) { return ext }
        }
        return ""
    }

    // MARK: - Misc

    private func shortInboxId(_ id: String) -> String {
        if id.count <= 10 { return id }
        return String(id.prefix(6)) + "…" + String(id.suffix(4))
    }
}

enum NSEError: Error {
    case appGroupUnavailable
    case manifestMalformed
    case keychainRead(status: OSStatus)
}
