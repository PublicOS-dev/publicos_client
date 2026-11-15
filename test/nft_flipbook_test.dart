// SvgFlipbook: on-chain SVG art that is a frame flipbook (elements taking turns
// through a discrete <animate> on visibility) splits into still frames, and
// anything else is left alone (parse returns null, the SVG paints as before).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_client/components/nft_image.dart';

// The shape of BitMON #683 (mainnet 0x6E6b13A7...bdeB): three
// groups, one visible per third of a 390 ms loop.
String _anim(String values) =>
    '<animate attributeName="visibility" calcMode="discrete" values="$values" '
    'keyTimes="0;0.333333333;0.666666667;1" dur="390ms" repeatCount="indefinite"/>';

final String _bitmon = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
    '<g visibility="visible">${_anim('visible;hidden;hidden;visible')}<path id="a" d="M0 0h1v1h-1z"/></g>'
    '<g visibility="hidden">${_anim('hidden;visible;hidden;hidden')}<path id="b" d="M1 0h1v1h-1z"/></g>'
    '<g visibility="hidden">${_anim('hidden;hidden;visible;hidden')}<path id="c" d="M2 0h1v1h-1z"/></g>'
    '</svg>';

/// Which of the three groups a frame shows, e.g. "a" or "ab".
String _shown(String frame) {
  final out = StringBuffer();
  for (final m in RegExp(r'<g([^>]*)><path id="(\w)"').allMatches(frame)) {
    if (!m.group(1)!.contains('display="none"')) out.write(m.group(2));
  }
  return out.toString();
}

void main() {
  test('a three-frame flipbook splits into three stills, one group each', () {
    final book = SvgFlipbook.parse(_bitmon)!;
    expect(book.frames.length, 3);
    expect(book.loopMicros, 390000);
    expect(book.starts, [0, 130000, 260000]);
    expect(book.frames.map(_shown).toList(), ['a', 'b', 'c']);
    for (final f in book.frames) {
      expect(f.contains('<animate'), isFalse);
      expect('<path'.allMatches(f).length, 3); // nothing lost, only hidden
    }
  });

  test('the frame follows the clock and loops', () {
    final book = SvgFlipbook.parse(_bitmon)!;
    expect(book.frameAt(0), 0);
    expect(book.frameAt(129999), 0);
    expect(book.frameAt(130000), 1);
    expect(book.frameAt(389999), 2);
    expect(book.frameAt(390000), 0);
    expect(book.untilNext(100000), 30000);
    expect(book.untilNext(380000), 10000);
  });

  test('no animation, or one we do not play, is left alone', () {
    expect(SvgFlipbook.parse('<svg><path d="M0 0h1v1h-1z"/></svg>'), isNull);
    // a colour animation
    expect(
        SvgFlipbook.parse('<svg><path d="M0 0"><animate attributeName="fill" '
            'values="red;blue" dur="1s" repeatCount="indefinite"/></path></svg>'),
        isNull);
    // two clocks
    expect(SvgFlipbook.parse(_bitmon.replaceFirst('390ms', '500ms')), isNull);
    // plays once
    expect(
        SvgFlipbook.parse(_bitmon.replaceAll('repeatCount="indefinite"', 'repeatCount="1"')),
        isNull);
    // faster than we flip
    expect(SvgFlipbook.parse(_bitmon.replaceAll('390ms', '60ms')), isNull);
  });

  test('display works like visibility, and key times may be left out', () {
    const svg = '<svg><g><animate attributeName="display" calcMode="discrete" '
        'values="inline;none" dur="1s" repeatCount="indefinite"/><path id="a" d="M0 0"/></g></svg>';
    final book = SvgFlipbook.parse(svg)!;
    expect(book.starts, [0, 500000]);
    expect(book.frames.map(_shown).toList(), ['a', '']);
  });

  testWidgets('an on-chain flipbook SVG builds and holds one frame at a time', (tester) async {
    final uri = Uri.dataFromString(_bitmon, mimeType: 'image/svg+xml', base64: true).toString();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 64, height: 64, child: NftImage(url: uri))),
    ));
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.children.length, 3);
    await tester.pumpWidget(const SizedBox.shrink()); // dispose: the timer must go with it
  });
}
