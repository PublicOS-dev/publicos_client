import 'package:flutter/material.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/l10n/app_localizations.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

/// Import key mode - mnemonic phrase or private key hex
enum ImportKeyMode { mnemonic, privateKey }

/// A glass-styled bottom sheet for importing ETH keys.
///
/// Single toggle, input, button. Supports mnemonic phrase or hex private key.
class ImportKeySheet extends StatefulWidget {
  /// Callback when user submits a mnemonic phrase.
  final Future<bool> Function(String mnemonic) onImportMnemonic;

  /// Callback when user submits a private key.
  final Future<bool> Function(String privateKey) onImportPrivateKey;

  /// Optional title for the sheet.
  final String? title;

  /// Optional subtitle for the sheet.
  final String? subtitle;

  const ImportKeySheet({
    super.key,
    required this.onImportMnemonic,
    required this.onImportPrivateKey,
    this.title,
    this.subtitle,
  });

  @override
  State<ImportKeySheet> createState() => _ImportKeySheetState();
}

class _ImportKeySheetState extends State<ImportKeySheet> {
  final TextEditingController _inputController = TextEditingController();
  ImportKeyMode _mode = ImportKeyMode.mnemonic;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  void _switchMode(ImportKeyMode mode) {
    if (_mode != mode) {
      setState(() {
        _mode = mode;
        _errorMessage = null;
      });
    }
  }

  String _hintText(AppLocalizations l) => _mode == ImportKeyMode.mnemonic
      ? l.importHintMnemonic
      : '0x1a2b3c4d5e6f...';

  String _inputLabel(AppLocalizations l) => _mode == ImportKeyMode.mnemonic
      ? l.importLabelMnemonic
      : l.importLabelPrivateKey;

  Future<void> _handleImport() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      final l10n = context.l10n;
      setState(() => _errorMessage = _mode == ImportKeyMode.mnemonic
          ? l10n.importEnterMnemonic
          : l10n.importEnterPrivateKey);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = _mode == ImportKeyMode.mnemonic
          ? await widget.onImportMnemonic(input)
          : await widget.onImportPrivateKey(input);
      if (success && mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = localizedError(context.l10n, e));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final l10n = context.l10n;

    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        decoration: BoxDecoration(
          color: tokens.background,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: tokens.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              (widget.title ?? l10n.keychainImportTitle).toUpperCase(),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: tokens.starkWhite,
              ),
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.textDim,
                  letterSpacing: 0.5,
                ),
              ),
            ],
            const SizedBox(height: 24),
            // Mode toggle
            Row(
              children: [
                Expanded(
                  child: _ModeToggle(
                    label: l10n.importModePhrase,
                    isSelected: _mode == ImportKeyMode.mnemonic,
                    onTap: () => _switchMode(ImportKeyMode.mnemonic),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeToggle(
                    label: l10n.importModePrivateKey,
                    isSelected: _mode == ImportKeyMode.privateKey,
                    onTap: () => _switchMode(ImportKeyMode.privateKey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Input label
            Text(
              _inputLabel(l10n),
              style: TextStyle(
                fontSize: 12,
                color: tokens.textDim,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            // Text input
            TextField(
              controller: _inputController,
              enabled: !_isLoading,
              maxLines: 4,
              onChanged: (_) => _clearError(),
              style: TextStyle(
                fontFamily: _mode == ImportKeyMode.privateKey
                    ? 'monospace'
                    : null,
                color: tokens.starkWhite,
              ),
              decoration: InputDecoration(
                hintText: _hintText(l10n),
                hintStyle: TextStyle(
                  fontFamily: _mode == ImportKeyMode.privateKey
                      ? 'monospace'
                      : null,
                  color: tokens.textDim,
                ),
                filled: true,
                fillColor: tokens.glassFillHover,
                // Borderless at rest — `fillColor` is the edge, same as the
                // search fields. ⚠ The ERROR tint stays: at rest it is the only
                // thing marking a bad key, and `focusedBorder` below is likewise
                // the only marker of focus. A state with no other carrier keeps
                // its border.
                enabledBorder: OutlineInputBorder(
                  borderSide: _errorMessage != null
                      ? BorderSide(color: errorColor.withValues(alpha: 0.5))
                      : BorderSide.none,
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: _errorMessage != null
                        ? errorColor
                        : tokens.starkWhite,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                disabledBorder: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 14,
                    color: errorColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        color: errorColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: tokens.starkWhite,
                  foregroundColor: tokens.background,
                  disabledBackgroundColor:
                      tokens.starkWhite.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isLoading ? null : _handleImport,
                child: _isLoading
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PhigitalLoadingWidget(
                            size: 14,
                            showShadows: false,
                            color: tokens.background,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            l10n.importImporting,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        l10n.keychainImport.toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeToggle({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 44,
        decoration: BoxDecoration(
          // Fill-only: unselected was `transparent` + a hairline, so dropping
          // the ring alone would have left an invisible segment. `glassFill`
          // takes the edge, and selected steps up rather than out.
          color: isSelected
              ? tokens.starkWhite.withValues(alpha: 0.14)
              : tokens.glassFill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: isSelected ? tokens.starkWhite : tokens.textDim,
            ),
          ),
        ),
      ),
    );
  }
}
