import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_client/components/profile/profile_grid.dart';
import 'package:publicos_core/publicos_core.dart';

/// Drives the real [ProfileGrid] through a real long-press drag and reads the
/// positions it actually lays out. Everything here is the shipping widget —
/// the packer, the frozen hit-test geometry and the freeze are all private, so
/// the only honest way to test them is through the interaction that uses them.
///
/// NOTE: never `pumpAndSettle` while a card is in flight. The landing slot's
/// glow repeats forever by design, so there is no steady state to settle to;
/// pump past [_kSettle] (220ms) instead and read the positions.

Record card(String id, {String? rank, int w = 1, int h = 1}) =>
    Record.asProfile(
      key: 'card.$id',
      value: id,
      expiration: DateTime.now().add(const Duration(days: 365)),
      rank: rank,
      width: w,
      height: h,
    );

/// Grid-local top-left of a card, read off the laid-out render tree.
Offset originOf(WidgetTester tester, String id) {
  final grid = tester.getTopLeft(find.byType(ProfileGrid));
  final cell = tester.getTopLeft(find.byKey(ValueKey<String>('card.$id')));
  return cell - grid;
}

Future<void> pumpGrid(
  WidgetTester tester,
  List<Record> records, {
  Future<void> Function(List<Record>, Record)? onReorder,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        child: ProfileGrid(
          records: records,
          isEditable: true,
          isEditMode: true,
          onReorder: onReorder,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}


/// A tall page: filler, the grid, filler — so the grid can sit at a viewport
/// edge with real scroll extent on both sides of it.
Future<ScrollController> pumpTallPage(
  WidgetTester tester,
  List<Record> records, {
  Future<void> Function(List<Record>, Record)? onReorder,
}) async {
  final controller = ScrollController();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 600,
        child: SingleChildScrollView(
          controller: controller,
          child: Column(children: [
            const SizedBox(height: 800),
            ProfileGrid(
              records: records,
              isEditable: true,
              isEditMode: true,
              onReorder: onReorder,
            ),
            const SizedBox(height: 800),
          ]),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  // 4 columns over a 400px box: cellWidth = (400 - 4*3) / 4 = 97, pitch = 101.
  const double pitch = 101;

  testWidgets('ranked cards pack in rank order, one per column', (t) async {
    await pumpGrid(t, [
      card('a', rank: 'a'),
      card('b', rank: 'b'),
      card('c', rank: 'c'),
    ]);
    expect(originOf(t, 'a').dx, moreOrLessEquals(0, epsilon: 0.5));
    expect(originOf(t, 'b').dx, moreOrLessEquals(pitch, epsilon: 0.5));
    expect(originOf(t, 'c').dx, moreOrLessEquals(pitch * 2, epsilon: 0.5));
  });

  testWidgets('dragging C onto A previews the post-drop layout live', (t) async {
    await pumpGrid(
      t,
      [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
      onReorder: (_, __) async {},
    );

    final gesture =
        await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.c'))));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));

    // Move C over A's cell (column 0). The drag is still in flight.
    await gesture.moveTo(t.getCenter(find.byKey(const ValueKey('card.a'))));
    // TWO pumps, not one. The first flushes the pointer event and rebuilds —
    // which is when the position tween STARTS, so that frame still paints the
    // old slot. The second advances it past [_kSettle].
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    // The preview must show the layout the DROP would produce, not a
    // highlighted target: C in column 0, A and B pushed right.
    expect(originOf(t, 'c').dx, moreOrLessEquals(0, epsilon: 0.5),
        reason: 'dragged card previews at its landing slot');
    expect(originOf(t, 'a').dx, moreOrLessEquals(pitch, epsilon: 0.5),
        reason: 'displaced card animates to its future position');
    expect(originOf(t, 'b').dx, moreOrLessEquals(pitch * 2, epsilon: 0.5));

    await gesture.up();
    await t.pumpAndSettle();
  });

  testWidgets('the previewed layout is exactly what is committed', (t) async {
    List<Record>? committed;
    Record? moved;
    await pumpGrid(
      t,
      [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
      onReorder: (order, m) async {
        committed = order;
        moved = m;
      },
    );

    final gesture =
        await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.c'))));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(t.getCenter(find.byKey(const ValueKey('card.a'))));
    await t.pump(const Duration(milliseconds: 300)); // past _kSettle
    await gesture.up();
    await t.pumpAndSettle();

    expect(moved?.key, 'card.c');
    expect(committed?.map((r) => r.key).toList(), [
      'card.c',
      'card.a',
      'card.b',
    ]);
  });

  testWidgets('dropping past the last card appends', (t) async {
    List<Record>? committed;
    await pumpGrid(
      t,
      [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
      onReorder: (order, _) async => committed = order,
    );

    final gridTL = t.getTopLeft(find.byType(ProfileGrid));
    final gesture =
        await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.a'))));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    // Column 3 of row 0 — past C, and empty.
    await gesture.moveTo(gridTL + const Offset(pitch * 3 + 48, 48));
    await t.pump(const Duration(milliseconds: 300)); // past _kSettle
    await gesture.up();
    await t.pumpAndSettle();

    expect(committed?.map((r) => r.key).toList(), [
      'card.b',
      'card.c',
      'card.a',
    ]);
  });

  testWidgets('dropping a card back where it started writes nothing', (t) async {
    var calls = 0;
    await pumpGrid(
      t,
      [card('a', rank: 'a'), card('b', rank: 'b')],
      onReorder: (_, __) async => calls++,
    );

    final gesture =
        await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.a'))));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(t.getCenter(find.byKey(const ValueKey('card.a'))));
    await t.pump(const Duration(milliseconds: 300)); // past _kSettle
    await gesture.up();
    await t.pumpAndSettle();

    expect(calls, 0);
  });

  testWidgets('the grid freezes the previewed layout until the save resolves',
      (t) async {
    final save = Completer<void>();
    // The host's records deliberately never change — this is the failed-write
    // case. The cards must hold the previewed layout while the write is in
    // flight, then animate back once it resolves.
    await pumpGrid(
      t,
      [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
      onReorder: (_, __) => save.future,
    );

    final gesture =
        await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.c'))));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(t.getCenter(find.byKey(const ValueKey('card.a'))));
    await t.pump(const Duration(milliseconds: 300)); // past _kSettle
    await gesture.up();
    await t.pumpAndSettle();

    // Frozen: C holds column 0 even though the host still reports the old order.
    expect(originOf(t, 'c').dx, moreOrLessEquals(0, epsilon: 0.5),
        reason: 'previewed layout held while the write is in flight');

    save.complete();
    await t.pumpAndSettle();

    // Unfrozen, and the write failed, so the cards are back where they were.
    expect(originOf(t, 'a').dx, moreOrLessEquals(0, epsilon: 0.5));
    expect(originOf(t, 'c').dx, moreOrLessEquals(pitch * 2, epsilon: 0.5));
  });

  group('auto-scroll while dragging', () {
    testWidgets('holding a card at the top edge scrolls the page up',
        (t) async {
      final ctrl = await pumpTallPage(
        t,
        [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
        onReorder: (_, __) async {},
      );
      // Put the grid at the very bottom of the viewport — the state a tall
      // profile is in when the card you want to move is the last one.
      ctrl.jumpTo(300);
      await t.pumpAndSettle();
      final before = ctrl.offset;

      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.a'))));
      await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));

      // Hold near the TOP edge of the viewport and stop moving.
      await gesture.moveTo(const Offset(200, 20));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }

      expect(ctrl.offset, lessThan(before),
          reason: 'the page scrolls itself while the card is held at the edge');

      await gesture.up();
      await t.pumpAndSettle();
    });

    testWidgets('the page does NOT scroll while the card is mid-viewport',
        (t) async {
      final ctrl = await pumpTallPage(
        t,
        [card('a', rank: 'a'), card('b', rank: 'b')],
        onReorder: (_, __) async {},
      );
      ctrl.jumpTo(700); // grid roughly centred
      await t.pumpAndSettle();
      final before = ctrl.offset;

      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.a'))));
      await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(200, 300)); // dead centre
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }

      expect(ctrl.offset, before,
          reason: 'no scroll unless the card is actually near an edge');

      await gesture.up();
      await t.pumpAndSettle();
    });

    testWidgets('the landing slot keeps tracking while the page auto-scrolls',
        (t) async {
      // THE trap this feature would otherwise ship with: during auto-scroll
      // the finger never moves, so nothing but the scroll tick can tell the
      // grid that the content slid underneath it.
      List<Record>? committed;
      final ctrl = await pumpTallPage(
        t,
        [
          card('a', rank: 'a'),
          card('b', rank: 'b'),
          card('c', rank: 'c'),
          card('d', rank: 'd'),
          card('e', rank: 'e'), // wraps to row 1
        ],
        onReorder: (order, _) async => committed = order,
      );
      // Grid low in the viewport so there is room to scroll up into it.
      ctrl.jumpTo(500);
      await t.pumpAndSettle();

      // Pick up E (row 1) and hold it at the top edge.
      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.e'))));
      await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(50, 20));
      await t.pump();
      final resolvedBeforeScroll = originOf(t, 'e');

      // Finger held still; only the page moves.
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }

      expect(ctrl.offset, lessThan(500));
      expect(originOf(t, 'e'), isNot(resolvedBeforeScroll),
          reason: 'the preview re-resolved off the scroll, not the pointer');

      await gesture.up();
      await t.pumpAndSettle();
      // And whatever it previewed is what got committed — the invariant the
      // scroll path must not be allowed to break.
      expect(committed, isNotNull);
      expect(committed!.length, 5);
    });

    testWidgets('releasing OUTSIDE the grid still commits the preview',
        (t) async {
      // The regression this guards: the drop used to run off a grid-level
      // DragTarget, which only accepts a release inside its own bounds. Drag
      // a card to the top edge to make the page scroll, let go there — the
      // finger is over the filler, not the grid — and the move was silently
      // discarded. Which is precisely the gesture auto-scroll exists to
      // enable, so the two features cancelled each other out.
      List<Record>? committed;
      final ctrl = await pumpTallPage(
        t,
        [card('a', rank: 'a'), card('b', rank: 'b'), card('c', rank: 'c')],
        onReorder: (order, _) async => committed = order,
      );
      ctrl.jumpTo(760); // grid low in the viewport
      await t.pumpAndSettle();

      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.c'))));
      await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      // Well above the grid — over the filler box.
      await gesture.moveTo(const Offset(50, 30));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      // Sanity: the finger really is off the grid.
      final gridRect = t.getRect(find.byType(ProfileGrid));
      expect(gridRect.contains(const Offset(50, 30)), isFalse);

      await gesture.up();
      await t.pumpAndSettle();

      expect(committed, isNotNull,
          reason: 'a release off the grid must still write the preview');
      expect(committed!.first.key, 'card.c',
          reason: 'dragging above the grid resolves to the first slot');
    });

    testWidgets('auto-scroll stops when the drag ends', (t) async {
      final ctrl = await pumpTallPage(
        t,
        [card('a', rank: 'a'), card('b', rank: 'b')],
        onReorder: (_, __) async {},
      );
      ctrl.jumpTo(300);
      await t.pumpAndSettle();

      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const ValueKey('card.a'))));
      await t.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(200, 20));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await t.pumpAndSettle();

      final settled = ctrl.offset;
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(ctrl.offset, settled, reason: 'the scroller was stopped on drop');
    });
  });
}
