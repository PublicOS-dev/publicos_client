import 'dart:async';
import 'dart:convert';
import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/profile/edit_bio_sheet.dart';
import 'package:publicos_client/components/profile/bio_display_widget.dart';
import 'package:publicos_client/components/profile/profile_grid.dart';
import 'package:publicos_client/components/profile/social_strip.dart';
import 'package:publicos_client/components/profile/create_record_page.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/widgets/fullscreen_overlay.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';

/// Pure **display** surface for a contact's profile. ProfilePage fetches
/// nothing and shows no loader of its own — `browser.dart` owns the contact
/// lifecycle (local-first render → single `_syncFromChain` → push down a fresh
/// `widget.contact`), and the only loading affordance is browser's small
/// sync indicator. The one exception is the org founder, which this page
/// silently resolves from `Contact.founderAddress` and fades in.
class ProfilePage extends StatefulWidget {
  final bool isEditMode;
  final Contact? contact;

  /// Hard-reload the contact from chain — browser's `_syncFromChain`. Every
  /// write here (and pull-to-refresh) routes through this single point; the
  /// fresh contact comes back down as `widget.contact` and `didUpdateWidget`
  /// re-renders. Null only when the host has no chain-backed contact.
  final Future<void> Function()? onRefresh;

  /// Org membership for this contact, computed once by `browser.dart`'s
  /// `_syncFromChain`. Passed in rather than re-queried here.
  final bool isOrgMember;

  /// Set the viewer's avatar to an NFT card's pointer (the "use as avatar"
  /// action inside an NFT card's info dialog). Always a self-write — `browser`'s
  /// `_useNftAsAvatar`. Null disables the button.
  final Future<bool> Function(NftAvatarRef ref)? onUseNftAsAvatar;

  /// Top inset applied INSIDE the scroll view so content starts below the
  /// browser's expanded address bar and scrolls up under it. The browser passes
  /// its expanded header height here; 0 when not hosted under the overlapping
  /// address bar.
  final double topInset;

  const ProfilePage({
    super.key,
    required this.isEditMode,
    this.contact,
    this.onRefresh,
    this.isOrgMember = false,
    this.onUseNftAsAvatar,
    this.topInset = 0,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// Mirror of `widget.contact`, kept in sync via [initState] / [didUpdateWidget].
  /// Own-profile record edits also bump it via the `onRefresh` round-trip.
  Contact? _contact;

  /// The org's founder, silently resolved from `_contact.founderAddress`
  /// (local cache first, chain on miss). Null until resolved — the founder
  /// row fades in when it lands.
  Contact? _founderContact;

  /// A group chat's description (from `XmtpConversation`, edited in Group
  /// Settings), shown read-only as the profile "bio". Null for person/account
  /// profiles and until resolved.
  String? _groupDescription;

  Record? _previewRecord;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _resolveFounder();
    _resolveGroupDescription();
  }

  /// `browser.dart` owns the contact lifecycle: its `_syncFromChain` — the hard
  /// chain pull behind pull-to-refresh, own-profile edits, and the management
  /// tab's cast/start-vote callback — updates browser's `_contact` and rebuilds
  /// this page with a fresh `widget.contact`. Adopt it (no loader, no fetch),
  /// and re-resolve the founder if its address just arrived.
  @override
  void didUpdateWidget(ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.contact, widget.contact)) {
      _contact = widget.contact;
      if (oldWidget.contact?.founderAddress != widget.contact?.founderAddress) {
        _resolveFounder();
      }
      if (oldWidget.contact?.xmtpConversationTopic !=
          widget.contact?.xmtpConversationTopic) {
        _resolveGroupDescription();
      }
    }
  }

  bool get _isOwnProfile => _contact?.publicosAddress == AppStateNotifier.currentMyContact?.publicosAddress;

  bool get _canEdit => _isOwnProfile || (_contact?.isOrgAccount == true && widget.isOrgMember);

  /// Refresh the in-memory `AppStateNotifier.currentMyContact` cache from
  /// the local DB so sibling screens (explorer, etc.) see own-profile edits.
  /// `PublicOSContacts.setRecord` / `deleteRecord` already write-through to
  /// the DB; this just invalidates the global in-memory snapshot. This page
  /// itself re-renders via the `widget.onRefresh` → `didUpdateWidget` round-trip.
  Future<void> _refreshOwnContact() async {
    await AppStateNotifier.loadMyContact();
  }

  /// Silently resolve the org founder (`Contact.founderAddress`) into a full
  /// Contact for display — local cache first, chain on miss, then persisted.
  /// Never blocks the page or shows a loader; the founder row fades in when
  /// this lands. No-op for non-orgs / contacts without a `founderAddress`.
  Future<void> _resolveFounder() async {
    final addr = _contact?.founderAddress;
    if (addr == null) {
      if (_founderContact != null && mounted) {
        setState(() => _founderContact = null);
      }
      return;
    }
    // Already resolved to this founder — nothing to do.
    if (_founderContact?.publicosAddress?.eip55With0x.toLowerCase() ==
        addr.eip55With0x.toLowerCase()) {
      return;
    }
    Contact? resolved = await PublicOSContacts.searchContacts(addr.eip55With0x);
    if (resolved == null) {
      try {
        resolved = await PublicOSContacts.fetchContact(addr, requireRecords: true);
        await PublicOSContacts.saveContact(resolved);
      } catch (_) {
        return; // leave unresolved — retried on next visit
      }
    }
    if (!mounted) return;
    // Bail if the contact changed underneath us while we were resolving.
    if (_contact?.founderAddress?.eip55With0x.toLowerCase() !=
        addr.eip55With0x.toLowerCase()) {
      return;
    }
    setState(() => _founderContact = resolved);
  }

  /// Silently resolve a group chat's description from its `XmtpConversation`
  /// (local DB, no network — the single source of truth, edited in Group
  /// Settings) for read-only display as the profile "bio". No-op for
  /// person/account profiles (no conversation topic).
  Future<void> _resolveGroupDescription() async {
    final topic = _contact?.xmtpConversationTopic;
    if (topic == null) {
      if (_groupDescription != null && mounted) {
        setState(() => _groupDescription = null);
      }
      return;
    }
    final conv = await PublicOSConversations.getConversation(topic);
    if (!mounted) return;
    // Bail if the contact changed underneath us while we were resolving.
    if (_contact?.xmtpConversationTopic != topic) return;
    setState(() => _groupDescription = conv?.groupDescription?.trim());
  }

  /// After a successful org-record write, a threshold-N org has an open vote
  /// while a threshold-1 org executed the action in the same tx. One inline
  /// `getActiveVote` check picks the snackbar copy. Falls back to
  /// [appliedMessage] on any error.
  Future<String> _orgWriteMessage(
      String appliedMessage, String voteStartedMessage) async {
    final addr = _contact?.publicosAddress;
    if (addr == null) return appliedMessage;
    try {
      final voteOpen =
          await PublicOSGovernance.hasPendingVoteBy(
          addr.eip55With0x, PublicOS.myPublicosAddress);
      return voteOpen ? voteStartedMessage : appliedMessage;
    } catch (_) {
      return appliedMessage;
    }
  }

  Widget? _buildBioSection() {
    // Group chats show their description (from XmtpConversation, edited in Group
    // Settings) as a read-only bio. Resolved async by _resolveGroupDescription.
    if (_contact?.isGroupChat == true) {
      final desc = _groupDescription;
      if (desc == null || desc.isEmpty) return null; // no bio, no dead space
      return BioDisplayWidget(
        record: Record.asProfile(
          key: 'profile.bio',
          value: desc,
          expiration: DateTime.now().add(const Duration(days: 365)),
          // BioDisplayWidget's `record.bioTextColor ?? Colors.white` fallback is
          // dead — the getter returns transparent (not null) when unset — so the
          // text renders invisible without an explicit colour. Person bios set
          // this in _showBioDialog; mirror it here.
          customMetadataAttributes: {'bioTextColor': Colors.white.toARGB32()},
        ),
      );
    }

    // Person / account profiles: the editable bio record, if any.
    Record? bioRecord;
    if (_contact != null) {
      try {
        bioRecord = _contact!.records.firstWhere(
          (rec) => rec.profileSubtype == ProfileSubtype.text,
        );
        if (bioRecord.value.isEmpty) bioRecord = null;
      } catch (e) {
        bioRecord = null;
      }
    }

    // No bio and not editable - drop the section entirely (no dead space).
    if (bioRecord == null && !(_canEdit && widget.isEditMode)) {
      return null;
    }

    return GestureDetector(
      onTap: _canEdit && widget.isEditMode ? _showBioDialog : null,
      child: Stack(
        alignment: Alignment.topRight,
        children: [
          BioDisplayWidget(record: bioRecord),
          if (_canEdit && widget.isEditMode)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Container(
                width: 32,
                height: 32,
                // The edit pencil must NEVER borrow the bio record's colour:
                // a broken record whose `bioTextColor` is unset resolves to
                // transparent, which would draw the one control that lets the
                // user FIX that record invisibly. Fixed white, always visible.
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(PhigitalStyle.radiusButton),
                ),
                child: const Icon(Icons.edit_rounded, color: Colors.white, size: 16),
              ),
            ),
        ],
      ),
    );
  }

  void _showBioDialog() {
    Record? existingBioRecord;
    try {
      existingBioRecord = _contact?.records.firstWhere((rec) => rec.profileSubtype == ProfileSubtype.text);
    } catch (e) {
      existingBioRecord = null;
    }
    Record bioRecord = existingBioRecord ??
        Record.asProfile(
          key: "profile.bio",
          value: context.l10n.profilePageBioPlaceholder,
          expiration: DateTime.now().add(const Duration(days: 365)),
          icon: Icons.person_rounded.codePoint,
          customMetadataAttributes: {
            'bioTextColor': Colors.white.value,
            'bioBorderVisible': false,
            'bioBorderColor': Colors.grey.value,
            'bioBorderWidth': 1.0,
            'borderRadius': 16.0,
          },
        );

    if (!_canEdit) return;
    showEditBioSheet(
      context,
      record: bioRecord,
      onSave: (updatedRecord) async {
        Navigator.of(context).pop();
        await _updateRecord(updatedRecord);
      },
    );
  }

  /// Attach a fractional-index rank to a card/social record on write
  /// (profile_grid_ordering). A new record gets a rank after the current
  /// maximum (`keyBetween(maxRank, null)`); editing an already-ranked record
  /// keeps its rank so it stays in place. Non-grid records (bio / identity /
  /// settings) pass through untouched.
  Record _withRank(Record record) {
    final isSortable = record.type == RecordType.profile &&
        (record.profileSubtype == ProfileSubtype.card ||
            record.profileSubtype == ProfileSubtype.social);
    if (!isSortable || record.rank != null) return record;

    final existing = _contact?.records;
    if (existing == null) return record.copyWith(rank: keyBetween(null, null));

    // Preserve an existing record's rank on edit.
    for (final r in existing) {
      if (r.key == record.key && r.rank != null) {
        return record.copyWith(rank: r.rank);
      }
    }
    // New record → append after the current maximum rank.
    String? maxRank;
    for (final r in existing) {
      final rr = r.rank;
      if (rr != null && (maxRank == null || rr.compareTo(maxRank) > 0)) {
        maxRank = rr;
      }
    }
    return record.copyWith(rank: keyBetween(maxRank, null));
  }

  Future<void> _updateRecord(Record recordToUpdate) async {
    if (!_canEdit || _contact == null) return;
    final l10n = context.l10n;
    recordToUpdate = _withRank(recordToUpdate);
    final overlay = FullscreenOverlay.showTransaction(context, l10n.profilePageSavingToChain);
    try {
      bool success = false;
      if (_isOwnProfile) {
        success = await PublicOSContacts.setRecord(recordToUpdate);
        if (success) {
          overlay.updateMessage(l10n.profilePageRefreshingProfile);
          await _refreshOwnContact();
        }
      } else if (_contact?.isOrgAccount == true && widget.isOrgMember && _contact?.publicosAddress != null) {
        // Org record — route through governance. startVoteSetRecord resolves
        // once the startVote tx is confirmed mined (threshold-1 → executed in
        // that tx; threshold-N → vote now open).
        overlay.updateMessage(l10n.profilePageStartingVote);
        success = await PublicOSGovernance.startVoteSetRecord(
          _contact!.publicosAddress!,
          key: recordToUpdate.key,
          value: jsonEncode(recordToUpdate.toChainValue()),
          expiration: BigInt.from(recordToUpdate.expiration.millisecondsSinceEpoch),
          recordType: BigInt.from(recordToUpdate.type.index),
          customType: recordToUpdate.subtype ?? '',
        );
      }

      if (success) {
        // Single refresh point — browser's _syncFromChain re-renders this page
        // via didUpdateWidget. Own-profile also bumped the global cache above.
        await widget.onRefresh?.call();
        final isOrgVote = _contact?.isOrgAccount == true && !_isOwnProfile;
        final message = isOrgVote
            ? await _orgWriteMessage(
                l10n.profilePageProfileUpdated, l10n.profilePageVoteStarted)
            : l10n.profilePageProfileUpdated;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.fixed,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.profilePageBlockchainError),
              behavior: SnackBarBehavior.fixed,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.profilePageBlockchainError),
          behavior: SnackBarBehavior.fixed,
        ),
      );
    } finally {
      overlay.dismiss();
    }
  }

  /// Drag-reorder handler (profile_grid_ordering). [newOrder] is the full
  /// linear card order after the move; [moved] is the dragged card.
  /// - Legacy/mixed profile (any card unranked) → bake all ranks in one batch
  ///   write (the move is already baked into [newOrder]).
  /// - Fully ranked → single write: the moved card gets a fresh rank between its
  ///   new neighbours; every other card stays put.
  Future<void> _onReorderCards(List<Record> newOrder, Record moved) async {
    if (!_canEdit || _contact == null) return;

    final anyUnranked = newOrder.any((r) => r.rank == null);
    if (anyUnranked) {
      await _bakeRecords(PublicOSContacts.withRanks(newOrder));
      return;
    }

    final i = newOrder.indexWhere((r) => r.key == moved.key);
    if (i < 0) return;
    final prev = i > 0 ? newOrder[i - 1].rank : null;
    final next = i < newOrder.length - 1 ? newOrder[i + 1].rank : null;
    if (prev == next) return; // single card / no movement
    await _updateRecord(moved.copyWith(rank: keyBetween(prev, next)));
  }

  /// One-shot batch write of [records] with their (new) ranks — the profile
  /// "bake". Own profile → a single `setMultipleRecords` tx; org → a single
  /// `SET_MULTIPLE_RECORDS` governance vote. Mirrors [_updateRecord]'s
  /// overlay / refresh / snackbar shape.
  Future<void> _bakeRecords(List<Record> records) async {
    if (!_canEdit || _contact == null || records.isEmpty) return;
    final l10n = context.l10n;
    final overlay = FullscreenOverlay.showTransaction(context, l10n.profilePageSavingLayout);
    try {
      bool success = false;
      if (_isOwnProfile) {
        success = await PublicOSContacts.setMultipleRecords(records);
        if (success) {
          overlay.updateMessage(l10n.profilePageRefreshingProfile);
          await _refreshOwnContact();
        }
      } else if (_contact?.isOrgAccount == true &&
          widget.isOrgMember &&
          _contact?.publicosAddress != null) {
        overlay.updateMessage(l10n.profilePageStartingVote);
        success = await PublicOSGovernance.startVoteSetMultipleRecords(
          _contact!.publicosAddress!,
          records,
        );
      }

      if (success) {
        await widget.onRefresh?.call();
        final isOrgVote = _contact?.isOrgAccount == true && !_isOwnProfile;
        final message = isOrgVote
            ? await _orgWriteMessage(
                l10n.profilePageLayoutSaved, l10n.profilePageVoteStarted)
            : l10n.profilePageLayoutSaved;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), behavior: SnackBarBehavior.fixed),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.profilePageBlockchainError),
              behavior: SnackBarBehavior.fixed,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.profilePageBlockchainError),
          behavior: SnackBarBehavior.fixed,
        ),
      );
    } finally {
      overlay.dismiss();
    }
  }

  Future<void> _deleteRecord(Record record) async {
    if (!_canEdit || _contact == null) return;
    final l10n = context.l10n;
    final overlay = FullscreenOverlay.showTransaction(context, l10n.profilePageDeletingFromChain);
    try {
      bool success = false;
      if (_isOwnProfile) {
        success = await PublicOSContacts.deleteRecord(record.key);
        if (success) {
          overlay.updateMessage(l10n.profilePageRefreshingProfile);
          await _refreshOwnContact();
        }
      } else if (_contact?.isOrgAccount == true && widget.isOrgMember && _contact?.publicosAddress != null) {
        // Org record — route through governance (threshold-1 → deleted in the
        // startVote tx; threshold-N → vote now open).
        overlay.updateMessage(l10n.profilePageStartingVote);
        success = await PublicOSGovernance.startVoteDeleteRecord(
          _contact!.publicosAddress!,
          record.key,
        );
      }

      if (success) {
        await widget.onRefresh?.call();
        final isOrgVote = _contact?.isOrgAccount == true && !_isOwnProfile;
        final message = isOrgVote
            ? await _orgWriteMessage(
                l10n.profilePageRecordDeleted, l10n.profilePageVoteStarted)
            : l10n.profilePageRecordDeleted;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.fixed,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.profilePageBlockchainError),
              behavior: SnackBarBehavior.fixed,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.profilePageBlockchainError),
          behavior: SnackBarBehavior.fixed,
        ),
      );
    } finally {
      overlay.dismiss();
    }
  }

  Widget _buildJoinedSection() {
    // createdAt is filled by browser's `_withCreatedAt` (immutable once set);
    // _contact mirrors widget.contact, so just read it here. The space stays
    // reserved even while createdAt is null — otherwise sections below jump
    // when chain enrichment lands (first cold load + the brief window before
    // `_enrichContactTail`/`_syncFromChain` writes the value into the row).
    final createdAt = _contact?.createdAt;

    final l10n = context.l10n;
    final months = [
      l10n.profilePageMonthJanuary,
      l10n.profilePageMonthFebruary,
      l10n.profilePageMonthMarch,
      l10n.profilePageMonthApril,
      l10n.profilePageMonthMay,
      l10n.profilePageMonthJune,
      l10n.profilePageMonthJuly,
      l10n.profilePageMonthAugust,
      l10n.profilePageMonthSeptember,
      l10n.profilePageMonthOctober,
      l10n.profilePageMonthNovember,
      l10n.profilePageMonthDecember,
    ];
    final label = createdAt == null
        ? null
        : l10n.profilePageJoined(months[createdAt.month - 1], createdAt.year);

    // No horizontal inset of its own: the section's `_gutter` owns the left
    // edge, so the calendar icon sits under the avatar, flush with the bio
    // text, the social strip and the first grid tile. (A Padding here
    // would double the gutter.)
    return Row(
      children: [
        Opacity(
          opacity: label == null ? 0 : 1,
          child: Icon(
            Icons.calendar_today_outlined,
            size: 16,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          // Zero-width space when unknown keeps the line at its natural
          // height (matches the live label's font + size) without
          // painting any glyph.
          label ?? '​',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  void _navigateToFounderProfile() {
    if (_founderContact?.publicosAddress == null) return;
    AppNav.toProfile(context, _founderContact!.publicosAddress!.eip55With0x);
  }

  Widget? _buildFounderSection() {
    if (_contact?.isOrgAccount != true) {
      return null;
    }

    final memberCount = _contact?.orgMemberCount;
    final hasFounder = _founderContact != null;
    if (memberCount == null && !hasFounder) return null;

    final l10n = context.l10n;
    // No padding of its own — the content wrapper owns the gutter
    // (_kContentPad), like every other section. A horizontal inset here would
    // stack on top of it and push the members icon right of the avatar, bio
    // and joined row.
    return Row(
      children: [
        if (memberCount != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              children: [
                Icon(Icons.people_outline, size: 16, color: Colors.white.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  '$memberCount ',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  l10n.profilePageMemberCountWord(memberCount),
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        const Spacer(),
        // Founder fades in once silently resolved from founderAddress.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: hasFounder
              ? GestureDetector(
                  key: ValueKey(_founderContact!.publicosAddress?.eip55With0x),
                  onTap: _navigateToFounderProfile,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlassContactIcon(
                        contact: _founderContact!,
                        size: 28,
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Row(
                          children: [
                            Text(
                              l10n.profilePageFoundedBy,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                            Text(
                              _founderContact!.displayName,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }


  void _setSocialRichMode(bool rich) {
    final record = Record.asSettings(
      key: 'settings.social_display',
      value: rich ? 'rich' : 'icon',
      isSystem: false,
      expiration: DateTime.now().add(const Duration(days: 3650)),
    );
    _updateRecord(record);
  }

  void _onPreviewChanged(Record? preview) {
    // Deferred to avoid setState during widget tree finalization
    // (CreateRecordSheet.dispose calls onPreviewChanged synchronously).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _previewRecord = preview);
    });
  }

  void _openCreateSheet() {
    showCreateRecordSheet(
      context,
      onSave: (record) async {
        Navigator.of(context).pop();
        await _updateRecord(record);
      },
      onPreviewChanged: _onPreviewChanged,
      orgAddress: (_contact?.isOrgAccount == true && !_isOwnProfile)
          ? _contact?.publicosAddress
          : null,
    ).then((_) {
      if (mounted) setState(() => _previewRecord = null);
    });
  }

  void _openEditSheet(Record record) {
    showCreateRecordSheet(
      context,
      record: record,
      onSave: (updated) async {
        Navigator.of(context).pop();
        await _updateRecord(updated);
      },
      onPreviewChanged: _onPreviewChanged,
      orgAddress: (_contact?.isOrgAccount == true && !_isOwnProfile)
          ? _contact?.publicosAddress
          : null,
    ).then((_) {
      if (mounted) setState(() => _previewRecord = null);
    });
  }

  Widget _buildProfileContent() {
    if (_contact == null) return const SizedBox.shrink();

    // Split records by subtype
    final socialRecords = _contact!.records.where((r) =>
        r.type == RecordType.profile &&
        r.profileSubtype == ProfileSubtype.social).toList();

    final socialRichMode =
        _contact!.getRecordValue('settings.social_display') == 'rich';

    final cardRecords = _contact!.records.where((r) =>
        r.type == RecordType.profile &&
        r.profileSubtype == ProfileSubtype.card &&
        r.key != "_osux_profile_background_url_").toList();

    // Determine where preview goes
    Record? socialPreview;
    Record? cardPreview;
    if (_previewRecord != null) {
      if (_previewRecord!.profileSubtype == ProfileSubtype.social) {
        socialPreview = _previewRecord;
      } else {
        cardPreview = _previewRecord;
      }
    }

    final showSocial = socialRecords.isNotEmpty ||
        socialPreview != null ||
        (_canEdit && widget.isEditMode);
    final showGrid = (_canEdit && widget.isEditMode) ||
        cardRecords.isNotEmpty ||
        cardPreview != null;

    // Each section is built only when present; an absent section returns null
    // and is filtered out, so it contributes no spacing (no leftover spacers).
    // A single uniform gap between consecutive sections is the one source of
    // truth for vertical rhythm. The social strip is the exception: it gets
    // `socialGap` above AND below so it reads as its own block
    // between the joined row and the grid instead of blending into either.
    // Gaps sit
    // only BETWEEN present sections, so a missing one (e.g. no social links)
    // never leaves a doubled gap.
    const sectionGap = 14.0;
    const socialGap = 18.0;
    // The grid's leading gap is the strip's trailing gap when the strip is the
    // last section above it; otherwise the plain section gap.
    final gridGap = showSocial ? socialGap : sectionGap;

    // Every section hangs off one gutter (`_kContentPad`), so every *visible*
    // left edge lines up: bio card, calendar, first social icon / mini card,
    // first grid tile. Same pattern as publicos_desktop's `profile_pane.dart`.
    final Widget? socialStrip = !showSocial
        ? null
        : _gutter(
            child: SocialStrip(
              records: socialRecords,
              previewRecord: socialPreview,
              richMode: socialRichMode,
              isEditMode: _canEdit && widget.isEditMode,
              onAddSocial:
                  _canEdit && widget.isEditMode ? _openCreateSheet : null,
              onEditSocial:
                  _canEdit && widget.isEditMode ? _openEditSheet : null,
              onDeleteSocial:
                  _canEdit && widget.isEditMode ? _deleteRecord : null,
              onRichModeChanged:
                  _canEdit && widget.isEditMode ? _setSocialRichMode : null,
            ),
          );

    final founder = _buildFounderSection();
    final bio = _buildBioSection();
    // Bio first, then an org's members + founder row.
    final sections = <Widget>[
      if (bio != null) _gutter(child: bio),
      if (founder != null) _gutter(child: founder),
      _gutter(child: _buildJoinedSection()),
      if (socialStrip != null) socialStrip,
    ];

    // Gap *before* section i: socialGap when either neighbour is the strip
    // (identity check — null sections were filtered, so indexes float).
    double gapBefore(int i) =>
        (identical(sections[i], socialStrip) ||
                identical(sections[i - 1], socialStrip))
            ? socialGap
            : sectionGap;

    return RefreshIndicator(
      onRefresh: widget.onRefresh ?? () async {},
      // Drop the spinner below the address bar instead of behind it.
      edgeOffset: widget.topInset,
      child: Container(
        constraints: const BoxConstraints.expand(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: widget.topInset, bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: sectionGap),
              for (int i = 0; i < sections.length; i++) ...[
                if (i > 0) SizedBox(height: gapBefore(i)),
                sections[i],
              ],
              if (showGrid) ...[
                SizedBox(height: gridGap),
                // KEYED, and it is load-bearing. `sections` above
                // is built from CONDITIONAL entries — "null sections were
                // filtered, so indexes float", as gapBefore already says. When
                // the chain sync lands and adds a bio, a social record or the
                // founder row, every later child of this Column shifts one
                // slot. Unkeyed children are matched positionally, so the grid
                // would be matched against a different widget, its State
                // destroyed, and `_ProfileGridState._entered` reset — which
                // made EVERY card replay its entrance cascade on every
                // refresh. That is the "cards jump when the fetch arrives"
                // bug. A stable key makes Flutter match it by key instead, so
                // the grid keeps its State and only genuinely new cards pop.
                //
                // The key sits on the OUTERMOST widget of this slot: key
                // matching happens between siblings, so keying ProfileGrid
                // itself would not save it from an unkeyed _gutter wrapper
                // being rebuilt around it.
                KeyedSubtree(
                  key: const ValueKey('profile.cards.grid'),
                  child: _gutter(
                  inset: 2,
                  child: ProfileGrid(
                    records: cardRecords,
                    previewRecord: cardPreview,
                    onRecordTap: (_canEdit && widget.isEditMode)
                        ? (r) => _openEditSheet(r)
                        : null,
                    onRecordDeleted: _deleteRecord,
                    isEditable: _canEdit,
                    isEditMode: widget.isEditMode,
                    onAddTap: (_canEdit && widget.isEditMode)
                        ? _openCreateSheet
                        : null,
                    onReorder: (_canEdit && widget.isEditMode)
                        ? _onReorderCards
                        : null,
                    onUseNftAsAvatar: widget.onUseNftAsAvatar,
                    nftOwner: _contact,
                  ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The one horizontal gutter every profile section hangs off.
  ///
  /// Several widgets carry their own internal horizontal padding or margin
  /// (RecordButton draws inside a 2px margin; the bio card pads its *text* 16
  /// but the card's own edge is what we align). Left alone they'd each land on
  /// a different edge — the ragged look this fixes. [inset] is how much the
  /// child already pads and is subtracted, so every section's **visible** left
  /// edge is exactly [_kContentPad]. Twin of publicos_desktop's `_gutter`.
  static const double _kContentPad = 16;
  Widget _gutter({required Widget child, double inset = 0}) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: (_kContentPad - inset).clamp(0, _kContentPad),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    // No horizontal padding here — each section applies `_gutter` itself so
    // internal insets can be compensated per widget.
    return Container(
      constraints: const BoxConstraints.expand(),
      child: _buildProfileContent(),
    );
  }
}
