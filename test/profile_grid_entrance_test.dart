import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_client/components/profile/profile_grid.dart';
import 'package:publicos_core/publicos_core.dart';

/// Regression test for **"the cards jump when the chain fetch lands"**.
///
/// ## The bug
///
/// `profile_page` lays its profile out as an unkeyed `Column` whose `sections`
/// list is built from CONDITIONAL entries (`if (bio != null)`, `if (founder !=
/// null)`, `if (socialStrip != null)`). A profile renders local-first and then
/// a chain sync lands, which can ADD a section — so every later child of that
/// Column shifts one slot.
///
/// Unkeyed children are matched positionally, so the grid was matched against
/// a different widget, its `State` destroyed and rebuilt, and the private
/// `_entered` set (which remembers "this card already played its entrance")
/// reset to empty. Result: every card replayed the pop-in cascade on every
/// refresh, including cards that had not changed at all.
///
/// ## What is asserted
///
/// Not the animation — the *element identity* that the animation hangs off.
/// `ProfileCardPopIn` starts its controller in `initState`, so "does the card
/// re-animate?" is exactly "was its State recreated?". Comparing the `State`
/// object across the rebuild is therefore the honest assertion, and it is
/// stable in a way that timing a 400ms curve would not be.
void main() {
  Record card(String id) => Record.asProfile(
        key: 'card.$id',
        value: id,
        expiration: DateTime.now().add(const Duration(days: 365)),
        rank: id,
        width: 1,
        height: 1,
      );

  final records = [card('a'), card('b'), card('c')];

  /// Reproduces the profile's shape: a Column whose leading section count
  /// changes, with the card grid after it.
  Widget profileLike({required bool extraSection, required bool keyed}) {
    final grid = SizedBox(width: 400, child: ProfileGrid(records: records, isEditable: false, isEditMode: false));
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 8, key: ValueKey('header')),
            // The section that appears when the fetch lands (a bio, a social
            // strip, an org's founder row).
            if (extraSection) const SizedBox(height: 20),
            keyed
                ? KeyedSubtree(
                    key: const ValueKey('profile.cards.grid'),
                    child: grid,
                  )
                : grid,
          ],
        ),
      ),
    );
  }

  testWidgets('a section appearing does NOT recreate the keyed grid', (t) async {
    await t.pumpWidget(profileLike(extraSection: false, keyed: true));
    final before = t.state(find.byType(ProfileGrid));

    // The chain sync lands and adds a section above the grid.
    await t.pumpWidget(profileLike(extraSection: true, keyed: true));
    final after = t.state(find.byType(ProfileGrid));

    expect(identical(before, after), isTrue,
        reason: 'the grid State must survive a sibling being inserted above '
            'it — otherwise _entered resets and every card replays its '
            'entrance cascade');
  });

  testWidgets('WITHOUT the key the State is destroyed — the original bug',
      (t) async {
    // Pins the cause, so a future refactor that drops the key fails loudly
    // here instead of quietly restoring the jump.
    await t.pumpWidget(profileLike(extraSection: false, keyed: false));
    final before = t.state(find.byType(ProfileGrid));

    await t.pumpWidget(profileLike(extraSection: true, keyed: false));
    final after = t.state(find.byType(ProfileGrid));

    expect(identical(before, after), isFalse,
        reason: 'this is the bug being fixed: positional matching rebuilds '
            'the grid when the section count changes');
  });

  testWidgets('the cards themselves keep their elements across the shift',
      (t) async {
    await t.pumpWidget(profileLike(extraSection: false, keyed: true));
    final beforeEls = <Element>[
      for (final r in records) t.element(find.byKey(ValueKey<String>(r.key))),
    ];

    await t.pumpWidget(profileLike(extraSection: true, keyed: true));
    final afterEls = <Element>[
      for (final r in records) t.element(find.byKey(ValueKey<String>(r.key))),
    ];

    for (var i = 0; i < records.length; i++) {
      expect(identical(beforeEls[i], afterEls[i]), isTrue,
          reason: '${records[i].key} was rebuilt as a new element');
    }
  });

  testWidgets('a genuinely NEW card still arrives, without disturbing the rest',
      (t) async {
    // The other half of the requirement: unchanged cards must not re-animate,
    // but a card the fetch actually added must still appear.
    await t.pumpWidget(profileLike(extraSection: false, keyed: true));
    final gridState = t.state(find.byType(ProfileGrid));
    final aBefore = t.element(find.byKey(const ValueKey<String>('card.a')));

    final grown = [...records, card('d')];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 8, key: ValueKey('header')),
            KeyedSubtree(
              key: const ValueKey('profile.cards.grid'),
              child: SizedBox(width: 400, child: ProfileGrid(records: grown, isEditable: false, isEditMode: false)),
            ),
          ],
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 500));

    expect(identical(gridState, t.state(find.byType(ProfileGrid))), isTrue,
        reason: 'adding a record must not remount the grid');
    expect(identical(aBefore, t.element(find.byKey(const ValueKey<String>('card.a')))),
        isTrue,
        reason: 'an untouched card must keep its element when a sibling is added');
    expect(find.byKey(const ValueKey<String>('card.d')), findsOneWidget,
        reason: 'the new card must still be rendered');
  });
  // The pop-in must not return the bare child once its entrance
  // completes. That would change the tree's shape under the card, so every
  // card's subtree would be rebuilt from scratch ~400 ms after it appears
  // (pinned posts flash their skeleton, app cards re-create their webviews).
  testWidgets('a card keeps its State when its entrance completes', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: ProfileCardPopIn(index: 0, child: _Probe()),
    ));
    await t.pump(const Duration(milliseconds: 100)); // mid-entrance
    final during = t.state(find.byType(_Probe));
    await t.pump(const Duration(seconds: 1)); // entrance long done
    await t.pump();
    expect(identical(during, t.state(find.byType(_Probe))), isTrue,
        reason: 'the card below the pop-in must not be rebuilt when it settles');
  });
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}
