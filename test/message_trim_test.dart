import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_client/components/messages/message_widget.dart';

/// Cut rules for the "trim long messages" reading setting (kMessageTrimMaxChars,
/// toggled from the conversation-settings sheet). The interesting cases are the
/// URL boundaries: a cut must never split a link into a tappable half-URL.
void main() {
  const budget = kMessageTrimMaxChars; // 280

  group('messageTrimCut', () {
    test('short text is not trimmable', () {
      expect(messageTrimCut('hey', budget), isNull);
    });

    test('text exactly at the budget is not trimmable', () {
      expect(messageTrimCut('a' * budget, budget), isNull);
    });

    test('one char over the budget cuts at the budget', () {
      expect(messageTrimCut('a' * (budget + 1), budget), budget);
    });

    test('null or zero budget disables trimming', () {
      final long = 'a' * 1000;
      expect(messageTrimCut(long, null), isNull);
      expect(messageTrimCut(long, 0), isNull);
    });

    test('a cut landing inside a URL backs up to the URL start', () {
      // URL starts 10 chars before the budget and runs well past it.
      final head = 'a' * (budget - 10);
      final text = '${head}https://example.com/a/very/long/path/that/runs/past';
      expect(messageTrimCut(text, budget), head.length);
    });

    test('a URL that ends before the cut is left intact', () {
      final text = 'see https://example.com now ${'a' * budget}';
      // Cut stays at the budget — the link is fully inside the visible part.
      expect(messageTrimCut(text, budget), budget);
    });

    test('a lone over-budget URL is not trimmable', () {
      final text = 'https://example.com/${'p' * 400}';
      expect(messageTrimCut(text, budget), isNull);
    });

    test('a URL after the cut does not move it', () {
      final text = '${'a' * (budget + 50)} https://example.com';
      expect(messageTrimCut(text, budget), budget);
    });
  });
}
