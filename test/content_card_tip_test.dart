import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show Color;
import 'package:publicos_client/components/profile/content_card.dart';
import 'package:publicos_core/publicos_core.dart';

// The tip action on a content card — shape, precedence over
// a link, and the no-expiry write.
void main() {
  const safe = '0x1111111111111111111111111111111111111111';
  const usdc = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

  Record cardWith(Map<String, dynamic> meta, {String? link}) =>
      Record.asProfile(
        key: 'card.test',
        value: 'hi',
        link: link,
        expiration: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        customMetadataAttributes: {'name': 'Tip me', ...meta},
      );

  test('tryParse accepts OX, native and an ERC-20 address', () {
    expect(CardTip.tryParse({'to': safe, 'chainId': 4489, 'token': 'OX'})?.isOx,
        isTrue);
    expect(
        CardTip.tryParse({'to': safe, 'chainId': 1, 'token': 'native'})
            ?.isNative,
        isTrue);
    expect(CardTip.tryParse({'to': safe, 'chainId': 8453, 'token': usdc})?.token,
        usdc);
  });

  test('tryParse rejects a bad address, token or chain', () {
    expect(CardTip.tryParse({'to': '0x12', 'chainId': 1, 'token': 'native'}),
        isNull);
    expect(CardTip.tryParse({'to': safe, 'chainId': 1, 'token': 'ETH'}),
        isNull);
    expect(CardTip.tryParse({'to': safe, 'chainId': '1', 'token': 'native'}),
        isNull);
    expect(CardTip.tryParse('not a map'), isNull);
  });

  test('a tip beats a leftover link on read, and the save drops the link', () {
    final r = cardWith({
      'tip': {'to': safe, 'chainId': 4489, 'token': 'OX'}
    }, link: 'https://example.com');
    final card = ContentCard.fromRecord(r);
    expect(card.hasTip, isTrue);
    expect(card.hasLink, isFalse);
    final out = card.toRecord(id: 'test');
    expect(out.link, isNull);
    expect(CardTip.tryParse(out.metadata['tip'])?.to, safe);
  });

  test('a card without a tip keeps its link', () {
    final card =
        ContentCard.fromRecord(cardWith({}, link: 'https://example.com'));
    expect(card.hasTip, isFalse);
    expect(card.hasLink, isTrue);
  });

  test('content cards are written with expiration 0 (never)', () {
    final out = const ContentCard(body: 'x').toRecord(id: 'test');
    expect(out.expiration.millisecondsSinceEpoch, 0);
  });

  test('a transparent tip card is not a spacer', () {
    const tip = CardTip(to: safe, chainId: 4489, token: 'OX');
    const c = Color(0x00000000);
    expect(const ContentCard(color: c).isSpacer, isTrue);
    expect(const ContentCard(color: c, tip: tip).isSpacer, isFalse);
  });
}
