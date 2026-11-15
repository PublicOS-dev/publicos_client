import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_core/publicos_core.dart';

void main() {
  group('PublicOS Core Integration', () {
    test('core starts uninitialized', () {
      expect(PublicOS.isInitialized, false);
      expect(PublicOS.isAuthenticated, false);
      expect(PublicOS.myPublicosAddress, null);
      expect(PublicOS.sessionBlockchainAddress, null);
    });

    test('core constants are set', () {
      expect(PublicOS.CHAIN_ID, 4489);
      expect(PublicOS.PUBLIC_RPC_URL, isNotEmpty);
    });

    test('Contact model can be created', () {
      final contact = Contact(
        publicosDisplayName: 'testuser',
        displayName: 'Test User',
      );
      expect(contact.publicosDisplayName, 'testuser');
      expect(contact.displayName, 'Test User');
      expect(contact.isOrgAccount, false);
    });

    test('Message model can be created', () {
      final msg = Message(
        id: 1,
        xmtpConversationTopic: 'test-topic',
        timestamp: DateTime.now(),
        content: const MessageContent(
          type: MessageType.text,
          value: 'Hello PublicOS',
        ),
        senderAddress: '0x1234',
      );
      expect(msg.id, 1);
      expect(msg.content.type, MessageType.text);
      expect(msg.content.value, 'Hello PublicOS');
    });

    test('Record model can be created', () {
      final record = Record.asProfile(
        key: 'Bio',
        value: 'Test bio',
        expiration: DateTime.now().add(const Duration(days: 365)),
        isExpired: false,
        opacity: 1.0,
      );
      expect(record.key, 'Bio');
      expect(record.value, 'Test bio');
      expect(record.type, RecordType.profile);
    });
  });
}
