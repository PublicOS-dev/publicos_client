import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/phigital_bottom_sheet.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/providers/provider_config.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class RegisterProviderSheet extends StatefulWidget {
  final ProviderConfig config;
  final VoidCallback? onRegistered;

  const RegisterProviderSheet({
    super.key,
    required this.config,
    this.onRegistered,
  });

  static Future<void> show(
    BuildContext context,
    ProviderConfig config, {
    VoidCallback? onRegistered,
  }) {
    return showPhigitalBottomSheet(
      context: context,
      useDraggable: true,
      initialChildSize: 0.7,
      builder: (context, isDark) => RegisterProviderSheet(
        config: config,
        onRegistered: onRegistered,
      ),
    );
  }

  @override
  State<RegisterProviderSheet> createState() => _RegisterProviderSheetState();
}

class _RegisterProviderSheetState extends State<RegisterProviderSheet> {
  final _formKey = GlobalKey<FormState>();
  final _slugController = TextEditingController();
  final _titleController = TextEditingController();
  final _requiredPointerController = TextEditingController();
  final _regionController = TextEditingController();
  final _websiteController = TextEditingController();

  bool _isSaving = false;
  String? _error;

  ProviderConfig get config => widget.config;

  @override
  void dispose() {
    _slugController.dispose();
    _titleController.dispose();
    _requiredPointerController.dispose();
    _regionController.dispose();
    _websiteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    if (!_formKey.currentState!.validate()) return;

    if (!PublicOS.isAuthenticated || PublicOS.currentBlockchainPrivateKey == null) {
      setState(() => _error = l10n.registerProviderSheetNotAuthenticated);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final creds = PublicOS.currentBlockchainPrivateKey!;
      final slug = _slugController.text.trim();
      final title = _titleController.text.trim();
      final requiredPointerValue = _requiredPointerController.text.trim();
      final region = _regionController.text.trim();
      final website = _websiteController.text.trim();

      // Build pointer arrays (only non-empty optional pointers)
      // Note: region is now a required struct field, not a pointer
      final pointerTypes = <String>[];
      final pointerValues = <String>[];
      if (website.isNotEmpty) {
        pointerTypes.add('website');
        pointerValues.add(website);
      }

      debugPrint('[RegisterProvider] Starting ${config.typeName} registration');
      debugPrint('[RegisterProvider] slug="$slug" title="$title" pointer="$requiredPointerValue"');
      debugPrint('[RegisterProvider] pointers: types=$pointerTypes values=$pointerValues');

      // Single atomic transaction: register + set all pointers
      final String txHash;
      if (config.typeName == 'BSP') {
        txHash = await PublicOSBsp.bspRegistryManagerContract.registerBSPWithPointers(
          (slug: slug, title: title, apiUrl: requiredPointerValue, region: region, pointerTypes: pointerTypes, pointerValues: pointerValues),
          credentials: creds,
        );
      } else {
        txHash = await PublicOSBsp.socialServerRegistryManagerContract.registerSocialServerWithPointers(
          (slug: slug, title: title, apiUrl: requiredPointerValue, region: region, pointerTypes: pointerTypes, pointerValues: pointerValues),
          credentials: creds,
        );
      }

      debugPrint('[RegisterProvider] tx sent: $txHash — polling for receipt...');

      // Wait for on-chain confirmation (same pattern as PublicOSContacts)
      final confirmed = await TxUtils.waitForReceipt(
        txHash,
        label: 'RegisterProvider(${config.typeName} $slug)',
      );
      if (!confirmed) {
        throw Exception('Transaction reverted or timed out');
      }

      debugPrint('[RegisterProvider] Registration confirmed on-chain');

      if (!mounted) return;

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.registerProviderSheetRegisteredSuccess(config.typeName, slug),
          ),
        ),
      );
      widget.onRegistered?.call();
    } catch (e) {
      debugPrint('[RegisterProvider] ERROR: $e');
      if (!mounted) return;
      setState(() {
        _error = localizedError(l10n, e);
        _isSaving = false;
      });
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helperText,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ThemeProvider.tealPrimary, width: 2),
      ),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              l10n.registerProviderSheetTitle(config.typeName),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.registerProviderSheetSubtitle(config.typeLabel),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),

            // Slug
            TextFormField(
              controller: _slugController,
              enabled: !_isSaving,
              decoration: _inputDecoration(
                label: l10n.registerProviderSheetSlugLabel,
                hint: l10n.registerProviderSheetSlugHint,
                helperText: l10n.registerProviderSheetSlugHelper,
              ),
              textInputAction: TextInputAction.next,
              onChanged: (value) {
                final lower = value.toLowerCase();
                if (lower != value) {
                  _slugController.value = _slugController.value.copyWith(
                    text: lower,
                    selection: TextSelection.collapsed(offset: lower.length),
                  );
                }
              },
              validator: (value) {
                final slug = value?.trim() ?? '';
                if (slug.isEmpty) return l10n.registerProviderSheetSlugRequired;
                if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(slug)) {
                  return l10n.registerProviderSheetSlugInvalid;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Title
            TextFormField(
              controller: _titleController,
              enabled: !_isSaving,
              decoration: _inputDecoration(
                label: l10n.registerProviderSheetTitleLabel,
                hint: l10n.registerProviderSheetTitleHint,
              ),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.registerProviderSheetTitleRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Required pointer (RPC URL or API URL)
            TextFormField(
              controller: _requiredPointerController,
              enabled: !_isSaving,
              decoration: _inputDecoration(
                label: config.requiredPointerLabel,
                hint: l10n.registerProviderSheetRequiredPointerHint,
              ),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.registerProviderSheetRequiredPointerRequired(
                    config.requiredPointerLabel,
                  );
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Region (optional)
            TextFormField(
              controller: _regionController,
              enabled: !_isSaving,
              decoration: _inputDecoration(
                label: l10n.registerProviderSheetRegionLabel,
                hint: l10n.registerProviderSheetRegionHint,
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),

            // Website (optional)
            TextFormField(
              controller: _websiteController,
              enabled: !_isSaving,
              decoration: _inputDecoration(
                label: l10n.registerProviderSheetWebsiteLabel,
                hint: l10n.registerProviderSheetWebsiteHint,
              ),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 24),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _isSaving ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: ThemeProvider.tealPrimary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const PhigitalLoadingWidget(size: 20, showShadows: false)
                    : Text(
                        l10n.registerProviderSheetTitle(config.typeName),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),

            // Error display
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
