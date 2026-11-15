import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class RegisterAppBottomSheet extends StatefulWidget {
  final VoidCallback? onSuccess;
  final AppBookmark? existingApp; // For edit mode

  const RegisterAppBottomSheet({
    super.key,
    this.onSuccess,
    this.existingApp,
  });

  @override
  State<RegisterAppBottomSheet> createState() => _RegisterAppBottomSheetState();
}

class _RegisterAppBottomSheetState extends State<RegisterAppBottomSheet> {
  final _formKey = GlobalKey<FormState>();
  final _appNameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _iconUrlController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _warningsController = TextEditingController();
  final _categoryOneController = TextEditingController();
  final _categoryTwoController = TextEditingController();
  final _urlController = TextEditingController();
  final _appStoreLinkController = TextEditingController();
  final _playStoreLinkController = TextEditingController();
  final _apkDownloadController = TextEditingController();
  final _ipaDownloadController = TextEditingController();

  bool _isLoading = false;
  int _currentStep = 0;
  bool get _isEditMode => widget.existingApp != null;

  @override
  void initState() {
    super.initState();
    if (_isEditMode) {
      _populateFieldsFromExistingApp();
    }
  }

  void _populateFieldsFromExistingApp() {
    final app = widget.existingApp!;
    _appNameController.text = app.appName;
    _displayNameController.text = app.displayName;
    _iconUrlController.text = app.icon ?? '';
    _descriptionController.text = app.description ?? '';
    _warningsController.text = app.getPointer('warnings')?.value ?? '';
    _categoryOneController.text = app.getPointer('category_one')?.value ?? '';
    _categoryTwoController.text = app.getPointer('category_two')?.value ?? '';
    _urlController.text = app.url ?? '';
    _appStoreLinkController.text = app.getPointer('appstore_link')?.value ?? '';
    _playStoreLinkController.text =
        app.getPointer('playstore_link')?.value ?? '';
    _apkDownloadController.text = app.getPointer('apk_download')?.value ?? '';
    _ipaDownloadController.text = app.getPointer('ipa_download')?.value ?? '';
  }

  @override
  void dispose() {
    _appNameController.dispose();
    _displayNameController.dispose();
    _iconUrlController.dispose();
    _descriptionController.dispose();
    _warningsController.dispose();
    _categoryOneController.dispose();
    _categoryTwoController.dispose();
    _urlController.dispose();
    _appStoreLinkController.dispose();
    _playStoreLinkController.dispose();
    _apkDownloadController.dispose();
    _ipaDownloadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Phigital colors
    final cardBorder = PhigitalStyle.cardBorder(isDark);
    final subtleBg = PhigitalStyle.subtleTint(isDark);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: ThemeProvider.tealPrimary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _isEditMode ? Icons.edit_rounded : Icons.app_registration_rounded,
                      color: ThemeProvider.tealPrimary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    _isEditMode
                        ? context.l10n.registerAppBottomSheetTitleEdit
                        : context.l10n.registerAppBottomSheetTitleRegister,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),

            // Divider with subtle bg
            Container(
              height: 1,
              color: cardBorder,
            ),

            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStepIndicator(theme, isDark),
                      const SizedBox(height: 24),
                      if (_currentStep == 0) _buildBasicInfoStep(theme, isDark),
                      if (_currentStep == 1) _buildMetadataStep(theme, isDark),
                      if (_currentStep == 2) _buildLinksStep(theme, isDark),
                    ],
                  ),
                ),
              ),
            ),

            // Actions (bottom bar)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: subtleBg,
                border: Border(
                  top: BorderSide(color: cardBorder),
                ),
              ),
              child: Row(
                children: [
                  if (_currentStep > 0)
                    Expanded(
                      child: _buildPhigitalButton(
                        label: context.l10n.registerAppBottomSheetBack,
                        icon: Icons.arrow_back_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                        isPrimary: false,
                        onTap: _isLoading ? null : () => setState(() => _currentStep--),
                        isDark: isDark,
                      ),
                    ),
                  if (_currentStep > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _buildPhigitalButton(
                      label: _currentStep == 2
                          ? (_isEditMode
                              ? context.l10n.registerAppBottomSheetUpdateApp
                              : context.l10n.registerAppBottomSheetTitleRegister)
                          : context.l10n.registerAppBottomSheetNext,
                      icon: _currentStep == 2
                          ? Icons.check_rounded
                          : Icons.arrow_forward_rounded,
                      color: ThemeProvider.tealPrimary,
                      isPrimary: true,
                      isLoading: _isLoading,
                      onTap: _isLoading ? null : _handleNext,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
  }

  Widget _buildPhigitalButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool isPrimary,
    required bool isDark,
    VoidCallback? onTap,
    bool isLoading = false,
  }) {
    if (isPrimary) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: onTap == null ? color.withValues(alpha: 0.5) : color,
            borderRadius: BorderRadius.circular(10),
            boxShadow: onTap == null
                ? []
                : [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 0,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                const PhigitalLoadingWidget(size: 18, showShadows: false)
              else
                Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Secondary button
    final btnBg = PhigitalStyle.subtleTint(isDark);
    final btnBorder = PhigitalStyle.subtleBorder(isDark);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: btnBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: btnBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator(ThemeData theme, bool isDark) {
    return Row(
      children: [
        _buildStepDot(
            0, context.l10n.registerAppBottomSheetStepBasicInfo, theme, isDark),
        Expanded(
          child: Container(
            height: 2,
            color: _currentStep >= 1
                ? ThemeProvider.tealPrimary
                : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
          ),
        ),
        _buildStepDot(
            1, context.l10n.registerAppBottomSheetStepMetadata, theme, isDark),
        Expanded(
          child: Container(
            height: 2,
            color: _currentStep >= 2
                ? ThemeProvider.tealPrimary
                : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
          ),
        ),
        _buildStepDot(
            2, context.l10n.registerAppBottomSheetStepLinks, theme, isDark),
      ],
    );
  }

  Widget _buildStepDot(int step, String label, ThemeData theme, bool isDark) {
    final isActive = _currentStep >= step;
    final isCurrent = _currentStep == step;

    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8), // Phigital squared corners
            color: isActive ? ThemeProvider.tealPrimary : Colors.transparent,
            border: Border.all(
              color: isActive
                  ? ThemeProvider.tealPrimary
                  : (isDark ? Colors.grey.shade600 : Colors.grey.shade400),
              width: 2,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: ThemeProvider.tealPrimary.withValues(alpha: 0.3),
                      blurRadius: 0,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              '${step + 1}',
              style: TextStyle(
                color: isActive
                    ? Colors.white
                    : (isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isActive
                ? ThemeProvider.tealPrimary
                : (isDark ? Colors.grey.shade500 : Colors.grey.shade600),
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  InputDecoration _phigitalInputDecoration({
    required String labelText,
    String? hintText,
    String? helperText,
    required bool isDark,
  }) {
    final borderColor = PhigitalStyle.subtleBorder(isDark);
    final fillColor = PhigitalStyle.subtleTint(isDark);

    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      filled: true,
      fillColor: fillColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: ThemeProvider.tealPrimary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.red.shade400),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  Widget _buildBasicInfoStep(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.registerAppBottomSheetBasicInfoTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _appNameController,
          enabled: !_isEditMode,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetAppNameLabel,
            hintText: context.l10n.registerAppBottomSheetAppNameHint,
            helperText: _isEditMode
                ? context.l10n.registerAppBottomSheetAppNameHelperEdit
                : context.l10n.registerAppBottomSheetAppNameHelperCreate,
            isDark: isDark,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9\-_]')),
          ],
          validator: (value) {
            if (value == null || value.isEmpty) {
              return context.l10n.registerAppBottomSheetAppNameRequired;
            }
            if (value.length < 3) {
              return context.l10n.registerAppBottomSheetAppNameMinLength;
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _displayNameController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetDisplayNameLabel,
            hintText: context.l10n.registerAppBottomSheetDisplayNameHint,
            helperText: context.l10n.registerAppBottomSheetDisplayNameHelper,
            isDark: isDark,
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return context.l10n.registerAppBottomSheetDisplayNameRequired;
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _iconUrlController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetIconUrlLabel,
            hintText: 'https://example.com/icon.png',
            helperText: context.l10n.registerAppBottomSheetIconUrlHelper,
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
      ],
    );
  }

  Widget _buildMetadataStep(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.registerAppBottomSheetAppDetailsTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _descriptionController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetDescriptionLabel,
            hintText: context.l10n.registerAppBottomSheetDescriptionHint,
            isDark: isDark,
          ),
          maxLines: 4,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _warningsController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetWarningsLabel,
            hintText: context.l10n.registerAppBottomSheetWarningsHint,
            helperText: context.l10n.registerAppBottomSheetWarningsHelper,
            isDark: isDark,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _categoryOneController,
                decoration: _phigitalInputDecoration(
                  labelText: context.l10n.registerAppBottomSheetCategoryOneLabel,
                  hintText: context.l10n.registerAppBottomSheetCategoryOneHint,
                  isDark: isDark,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _categoryTwoController,
                decoration: _phigitalInputDecoration(
                  labelText: context.l10n.registerAppBottomSheetCategoryTwoLabel,
                  hintText: context.l10n.registerAppBottomSheetCategoryTwoHint,
                  isDark: isDark,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLinksStep(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.registerAppBottomSheetAppLinksTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.registerAppBottomSheetAppLinksSubtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _urlController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetWebUrlLabel,
            hintText: 'https://myapp.com',
            helperText: context.l10n.registerAppBottomSheetWebUrlHelper,
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _appStoreLinkController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetAppStoreLabel,
            hintText: 'https://apps.apple.com/...',
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _playStoreLinkController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetPlayStoreLabel,
            hintText: 'https://play.google.com/...',
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _apkDownloadController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetApkLabel,
            hintText: context.l10n.registerAppBottomSheetApkHint,
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _ipaDownloadController,
          decoration: _phigitalInputDecoration(
            labelText: context.l10n.registerAppBottomSheetIpaLabel,
            hintText: context.l10n.registerAppBottomSheetIpaHint,
            isDark: isDark,
          ),
          keyboardType: TextInputType.url,
        ),
      ],
    );
  }

  void _handleNext() {
    if (_currentStep == 0) {
      if (_formKey.currentState?.validate() ?? false) {
        setState(() => _currentStep = 1);
      }
    } else if (_currentStep == 1) {
      setState(() => _currentStep = 2);
    } else if (_currentStep == 2) {
      _registerApp();
    }
  }

  Future<void> _registerApp() async {
    final l10n = context.l10n;
    setState(() => _isLoading = true);

    try {
      if (!_isEditMode) {
        // Step 1: Register the app (only in create mode)
        print('RegisterAppBottomSheet: Registering app...');
        final success = await PublicOSAppRegistry.registerApp(
          _appNameController.text.trim(),
          _displayNameController.text.trim(),
        );

        if (!success) {
          throw Exception('Failed to register app');
        }

        // Step 2: Wait for the transaction to be mined
        print(
            'RegisterAppBottomSheet: Waiting 3 seconds for transaction to be mined...');
        await Future.delayed(const Duration(seconds: 3));
      } else {
        // In edit mode, update display name if changed
        if (_displayNameController.text.trim() !=
            widget.existingApp!.displayName) {
          print('RegisterAppBottomSheet: Updating display name...');
          await PublicOSAppRegistry.updateAppDisplayName(
            _appNameController.text.trim(),
            _displayNameController.text.trim(),
          );
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      // Step 3: Update pointers
      final pointers = <Map<String, String>>[];

      if (_iconUrlController.text.isNotEmpty) {
        pointers.add({'type': 'icon', 'value': _iconUrlController.text.trim()});
      }
      if (_descriptionController.text.isNotEmpty) {
        pointers.add(
            {'type': 'description', 'value': _descriptionController.text.trim()});
      }
      if (_warningsController.text.isNotEmpty) {
        pointers.add(
            {'type': 'warnings', 'value': _warningsController.text.trim()});
      }
      if (_categoryOneController.text.isNotEmpty) {
        pointers.add(
            {'type': 'category_one', 'value': _categoryOneController.text.trim()});
      }
      if (_categoryTwoController.text.isNotEmpty) {
        pointers.add(
            {'type': 'category_two', 'value': _categoryTwoController.text.trim()});
      }
      if (_urlController.text.isNotEmpty) {
        pointers.add({'type': 'url', 'value': _urlController.text.trim()});
      }
      if (_appStoreLinkController.text.isNotEmpty) {
        pointers.add(
            {'type': 'appstore_link', 'value': _appStoreLinkController.text.trim()});
      }
      if (_playStoreLinkController.text.isNotEmpty) {
        pointers.add({
          'type': 'playstore_link',
          'value': _playStoreLinkController.text.trim()
        });
      }
      if (_apkDownloadController.text.isNotEmpty) {
        pointers.add(
            {'type': 'apk_download', 'value': _apkDownloadController.text.trim()});
      }
      if (_ipaDownloadController.text.isNotEmpty) {
        pointers.add(
            {'type': 'ipa_download', 'value': _ipaDownloadController.text.trim()});
      }

      // Add pointers one by one
      print('RegisterAppBottomSheet: Adding ${pointers.length} pointers...');
      int successCount = 0;
      for (final pointer in pointers) {
        print('  Setting pointer: ${pointer['type']} = ${pointer['value']}');
        final pointerSuccess = await PublicOSAppRegistry.setAppPointer(
          _appNameController.text.trim(),
          pointer['type']!,
          pointer['value']!,
        );
        if (pointerSuccess) {
          successCount++;
          print('    Success');
        } else {
          print('    Failed');
        }
      }

      print(
          'RegisterAppBottomSheet: Set $successCount/${pointers.length} pointers successfully');

      // Cache the app locally for instant display
      try {
        final accountAddress =
            await PublicOSAccounts.getSelectedAccountAddress();
        if (accountAddress != null) {
          final appPointers = <AppPointer>[];
          for (final pointer in pointers) {
            appPointers
                .add(AppPointer(type: pointer['type']!, value: pointer['value']!));
          }

          final appToCache = AppBookmark(
            appName: _appNameController.text.trim(),
            displayName: _displayNameController.text.trim(),
            ownerAccountAddress: accountAddress,
            pointers: appPointers,
          );

          await PublicOSAppRegistry.bookmarkApp(appToCache);
          print('RegisterAppBottomSheet: Cached app locally for instant display');
        }
      } catch (e) {
        print('RegisterAppBottomSheet: Error caching app locally: $e');
        // Non-fatal, continue
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditMode
                  ? l10n.registerAppBottomSheetSnackUpdated(
                      _displayNameController.text, successCount)
                  : l10n.registerAppBottomSheetSnackRegistered(
                      _displayNameController.text, successCount),
            ),
          ),
        );
        Navigator.pop(context);
        widget.onSuccess?.call();
      }
    } catch (e) {
      print('RegisterAppBottomSheet: Error registering app: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(localizedError(l10n, PublicOS.lastError ?? e,
                  fallback: l10n.registerAppBottomSheetRegisterFailed))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
