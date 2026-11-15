import 'package:flutter/material.dart';
import 'package:publicos_client/components/phigital_bottom_sheet.dart';
import 'package:publicos_client/components/system_app_scaffold.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';

/// The protocol agreement, shown only before a NEW account is made: adding a
/// device to an existing account means the user already saw it.
///
/// The new key's create-account consent carries the current PROTOCOL version
/// (`signCreateAccountConsent` reads it live), so the account accepts this
/// text when it is minted. Agreement clause 16: no app may ask for that
/// signature without first showing the agreement. This sheet is that showing.
///
/// [agreement] is loaded by the caller (`PublicOSAgreements.currentText`,
/// never a bundled copy), so a load failure stays in the caller's own error
/// line and the sheet only reads. Same reading rule as the citizenship claim:
/// ACCEPT AND CONTINUE exists only once the reader reached the end of the
/// text; a text that fits without scrolling counts as read.
///
/// Returns `true` only when the user accepted.
Future<bool> showProtocolAgreementSheet(
  BuildContext context, {
  required ({BigInt version, String text}) agreement,
}) async {
  final accepted = ValueNotifier<bool>(false);
  await showPhigitalBottomSheet<void>(
    context: context,
    // The body paints its own glass.
    wrapInChrome: false,
    builder: (_, __) => ProtocolAgreementSheet(
      agreement: agreement,
      accepted: accepted,
    ),
  );
  final result = accepted.value;
  accepted.dispose();
  return result;
}

class ProtocolAgreementSheet extends StatefulWidget {
  final ({BigInt version, String text}) agreement;

  /// Flipped to true on ACCEPT. Owned by the caller, because a sheet
  /// dismissed by a drag returns nothing.
  final ValueNotifier<bool> accepted;

  const ProtocolAgreementSheet({
    super.key,
    required this.agreement,
    required this.accepted,
  });

  @override
  State<ProtocolAgreementSheet> createState() => _ProtocolAgreementSheetState();
}

class _ProtocolAgreementSheetState extends State<ProtocolAgreementSheet> {
  final ScrollController _scroll = ScrollController();
  bool _reachedEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // A text short enough to need no scrolling has been read once painted.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkFitsWithoutScroll());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _checkFitsWithoutScroll() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent <= 0 && !_reachedEnd) {
      setState(() => _reachedEnd = true);
    }
  }

  void _onScroll() {
    if (_reachedEnd || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 12) {
      setState(() => _reachedEnd = true);
    }
  }

  void _accept() {
    widget.accepted.value = true;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.surfaceDeep,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: tokens.borderSubtle, width: 1),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.borderMedium,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.protocolAgreementTitle,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        color: tokens.starkWhite,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: tokens.starkWhite),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ProtocolAgreementReader(
                agreement: widget.agreement,
                scroll: _scroll,
                reachedEnd: _reachedEnd,
                onAccept: _accept,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The reading pane shared by the mobile sheet and the desktop dialog: lead,
/// version, the bordered scrolling text, and the earned ACCEPT button.
class ProtocolAgreementReader extends StatelessWidget {
  final ({BigInt version, String text}) agreement;
  final ScrollController scroll;
  final bool reachedEnd;
  final VoidCallback onAccept;

  const ProtocolAgreementReader({
    super.key,
    required this.agreement,
    required this.scroll,
    required this.reachedEnd,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.protocolAgreementLead,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.starkWhite.withValues(alpha: 0.85),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.protocolAgreementVersion(agreement.version.toString()),
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          // The agreement, in its own box: "reached the end" is a fact about
          // THIS box, not about the sheet.
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: tokens.glassFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tokens.borderSubtle),
              ),
              clipBehavior: Clip.antiAlias,
              child: Scrollbar(
                controller: scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Text(
                    agreement.text,
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      color: tokens.starkWhite,
                      fontSize: 14,
                      height: 1.55,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          // The button is EARNED by reading; the hint holds its height so
          // nothing jumps when it appears.
          SizedBox(
            height: 48,
            child: reachedEnd
                ? SystemAppActionButton(
                    label: l10n.protocolAgreementAccept,
                    icon: Icons.check_rounded,
                    onTap: onAccept,
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.keyboard_double_arrow_down_rounded,
                          size: 18, color: tokens.textDim),
                      const SizedBox(width: 8),
                      Text(
                        l10n.protocolAgreementScrollHint,
                        style: TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          color: tokens.textDim,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
