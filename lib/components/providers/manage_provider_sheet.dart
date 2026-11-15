import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/phigital_bottom_sheet.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/providers/provider_config.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class ManageProviderSheet extends StatefulWidget {
  final ProviderConfig config;
  final String slug;
  final VoidCallback? onChanged;

  const ManageProviderSheet({
    super.key,
    required this.config,
    required this.slug,
    this.onChanged,
  });

  static Future<void> show(
    BuildContext context,
    ProviderConfig config,
    String slug, {
    VoidCallback? onChanged,
  }) {
    return showPhigitalBottomSheet(
      context: context,
      useDraggable: true,
      initialChildSize: 0.7,
      builder: (context, isDark) => ManageProviderSheet(
        config: config,
        slug: slug,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<ManageProviderSheet> createState() => _ManageProviderSheetState();
}

class _ManageProviderSheetState extends State<ManageProviderSheet> {
  bool _isLoading = true;
  String _title = '';
  List<String> _pointerTypes = [];
  List<String> _pointerValues = [];
  BigInt _subscriberCount = BigInt.zero;

  // Title editing
  bool _isEditingTitle = false;
  bool _isSavingTitle = false;
  final _titleController = TextEditingController();

  // Pointer editing — tracks which pointer index is being edited
  int? _editingPointerIndex;
  bool _isSavingPointer = false;
  final _editPointerController = TextEditingController();

  // Pointer deletion
  bool _isDeletingPointer = false;

  // Add pointer
  final _newPointerTypeController = TextEditingController();
  final _newPointerValueController = TextEditingController();
  bool _isAddingPointer = false;

  // Delete provider
  bool _isDeletingProvider = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _editPointerController.dispose();
    _newPointerTypeController.dispose();
    _newPointerValueController.dispose();
    super.dispose();
  }

  bool get _isBSP => widget.config.typeName == 'BSP';

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final results = await Future.wait([
        _isBSP
            ? PublicOSBsp.bspRegistryMemoryContract
                .getBSPBySlug((slug: widget.slug))
            : PublicOSBsp.socialServerRegistryMemoryContract
                .getSocialServerBySlug((slug: widget.slug)),
        _isBSP
            ? PublicOSBsp.bspRegistryMemoryContract
                .getAllBSPPointers((slug: widget.slug))
            : PublicOSBsp.socialServerRegistryMemoryContract
                .getAllSocialServerPointers((slug: widget.slug)),
        // TODO(glass-port): Core API changed — providerSubscriptionMemoryContract removed
        // PublicOSBsp.providerSubscriptionMemoryContract.getSubscriberCount((
        //   providerType: widget.config.providerType,
        //   slug: widget.slug,
        // )),
        Future.value(BigInt.zero),
      ]);

      if (!mounted) return;

      // results[0] is a List: [0]=exists, [1]=slug, [2]=title, [3]=owner
      final providerData = results[0] as List<dynamic>;
      final title = providerData[2] as String;

      // results[1] is GetAllBSPPointers or GetAllSocialServerPointers
      final pointers = results[1];
      final List<String> pointerTypes;
      final List<String> pointerValues;
      if (_isBSP) {
        final bspPointers = pointers as GetAllBSPPointers;
        pointerTypes = bspPointers.pointerTypes;
        pointerValues = bspPointers.values;
      } else {
        final sspPointers = pointers as GetAllSocialServerPointers;
        pointerTypes = sspPointers.pointerTypes;
        pointerValues = sspPointers.values;
      }

      final subscriberCount = results[2] as BigInt;

      setState(() {
        _title = title;
        _pointerTypes = List.from(pointerTypes);
        _pointerValues = List.from(pointerValues);
        _subscriberCount = subscriberCount;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  Future<void> _refreshPointers() async {
    try {
      final pointers = _isBSP
          ? await PublicOSBsp.bspRegistryMemoryContract
              .getAllBSPPointers((slug: widget.slug))
          : await PublicOSBsp.socialServerRegistryMemoryContract
              .getAllSocialServerPointers((slug: widget.slug));

      if (!mounted) return;

      if (_isBSP) {
        final bspPointers = pointers as GetAllBSPPointers;
        setState(() {
          _pointerTypes = List.from(bspPointers.pointerTypes);
          _pointerValues = List.from(bspPointers.values);
        });
      } else {
        final sspPointers = pointers as GetAllSocialServerPointers;
        setState(() {
          _pointerTypes = List.from(sspPointers.pointerTypes);
          _pointerValues = List.from(sspPointers.values);
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Title editing ──

  void _startEditingTitle() {
    setState(() {
      _isEditingTitle = true;
      _titleController.text = _title;
    });
  }

  void _cancelEditingTitle() {
    setState(() => _isEditingTitle = false);
  }

  Future<void> _saveTitle() async {
    final newTitle = _titleController.text.trim();
    if (newTitle.isEmpty || newTitle == _title) {
      setState(() => _isEditingTitle = false);
      return;
    }

    setState(() => _isSavingTitle = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;
      if (_isBSP) {
        await PublicOSBsp.bspRegistryManagerContract.updateBSPTitle(
          (slug: widget.slug, newTitle: newTitle),
          credentials: credentials,
        );
      } else {
        await PublicOSBsp.socialServerRegistryManagerContract
            .updateSocialServerTitle(
          (slug: widget.slug, newTitle: newTitle),
          credentials: credentials,
        );
      }

      if (!mounted) return;
      setState(() {
        _title = newTitle;
        _isEditingTitle = false;
        _isSavingTitle = false;
      });
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingTitle = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Pointer editing ──

  void _startEditingPointer(int index) {
    setState(() {
      _editingPointerIndex = index;
      _editPointerController.text = _pointerValues[index];
    });
  }

  void _cancelEditingPointer() {
    setState(() => _editingPointerIndex = null);
  }

  Future<void> _savePointer(int index) async {
    final newValue = _editPointerController.text.trim();
    if (newValue.isEmpty) return;

    setState(() => _isSavingPointer = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;
      final pointerType = _pointerTypes[index];

      if (_isBSP) {
        await PublicOSBsp.bspRegistryManagerContract.setBSPPointer(
          (slug: widget.slug, pointerType: pointerType, value: newValue),
          credentials: credentials,
        );
      } else {
        await PublicOSBsp.socialServerRegistryManagerContract
            .setSocialServerPointer(
          (slug: widget.slug, pointerType: pointerType, value: newValue),
          credentials: credentials,
        );
      }

      if (!mounted) return;
      setState(() {
        _editingPointerIndex = null;
        _isSavingPointer = false;
      });
      await _refreshPointers();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingPointer = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Pointer deletion ──

  void _showDeletePointerConfirmation(int index) {
    final pointerType = _pointerTypes[index];
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        title: Text(l10n.manageProviderSheetRemovePointerTitle),
        content: Text(l10n.manageProviderSheetRemovePointerConfirm(pointerType)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deletePointer(index);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.manageProviderSheetRemove),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePointer(int index) async {
    setState(() => _isDeletingPointer = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;
      final pointerType = _pointerTypes[index];

      if (_isBSP) {
        await PublicOSBsp.bspRegistryManagerContract.removeBSPPointer(
          (slug: widget.slug, pointerType: pointerType),
          credentials: credentials,
        );
      } else {
        await PublicOSBsp.socialServerRegistryManagerContract
            .removeSocialServerPointer(
          (slug: widget.slug, pointerType: pointerType),
          credentials: credentials,
        );
      }

      if (!mounted) return;
      setState(() => _isDeletingPointer = false);
      await _refreshPointers();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDeletingPointer = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Add pointer ──

  Future<void> _addPointer() async {
    final type = _newPointerTypeController.text.trim();
    final value = _newPointerValueController.text.trim();
    if (type.isEmpty || value.isEmpty) return;

    setState(() => _isAddingPointer = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;

      if (_isBSP) {
        await PublicOSBsp.bspRegistryManagerContract.setBSPPointer(
          (slug: widget.slug, pointerType: type, value: value),
          credentials: credentials,
        );
      } else {
        await PublicOSBsp.socialServerRegistryManagerContract
            .setSocialServerPointer(
          (slug: widget.slug, pointerType: type, value: value),
          credentials: credentials,
        );
      }

      if (!mounted) return;
      setState(() => _isAddingPointer = false);
      _newPointerTypeController.clear();
      _newPointerValueController.clear();
      await _refreshPointers();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAddingPointer = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Delete provider ──

  void _showDeleteProviderConfirmation() {
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        title: Text(l10n.manageProviderSheetDeleteTitle(widget.config.typeName)),
        content: Text(l10n.manageProviderSheetDeleteConfirm(widget.slug)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteProvider();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.manageProviderSheetDeleteButton),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteProvider() async {
    setState(() => _isDeletingProvider = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;

      if (_isBSP) {
        await PublicOSBsp.bspRegistryManagerContract.removeBSP(
          (slug: widget.slug),
          credentials: credentials,
        );
      } else {
        await PublicOSBsp.socialServerRegistryManagerContract
            .removeSocialServer(
          (slug: widget.slug),
          credentials: credentials,
        );
      }

      if (!mounted) return;
      final l10n = context.l10n;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.manageProviderSheetDeleted(
              widget.config.typeName,
              widget.slug,
            ),
          ),
        ),
      );
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDeletingProvider = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(64),
        child: Center(child: PhigitalLoadingWidget(size: 32)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.manageProviderSheetManageTitle(
                    widget.config.typeName,
                  ),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Icon(
                Icons.settings,
                color: ThemeProvider.tealPrimary,
                size: 32,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.slug,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 24),

          // Title section
          _buildTitleSection(theme),
          const SizedBox(height: 16),

          // Subscriber count
          _buildSubscriberRow(theme),
          const SizedBox(height: 24),

          // Pointers section
          _buildPointersSection(theme),
          const SizedBox(height: 16),

          // Add pointer section
          _buildAddPointerSection(theme),
          const SizedBox(height: 32),

          // Delete provider
          _buildDeleteSection(theme),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildTitleSection(ThemeData theme) {
    if (_isEditingTitle) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: _titleController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.l10n.manageProviderSheetTitleLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _saveTitle(),
            ),
          ),
          const SizedBox(width: 8),
          if (_isSavingTitle)
            const SizedBox(
              width: 24,
              height: 24,
              child: PhigitalLoadingWidget(size: 16, showShadows: false),
            )
          else ...[
            IconButton(
              onPressed: _saveTitle,
              icon: Icon(Icons.check, color: ThemeProvider.tealPrimary),
              tooltip: context.l10n.manageProviderSheetSaveTooltip,
            ),
            IconButton(
              onPressed: _cancelEditingTitle,
              icon: Icon(
                Icons.close,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              tooltip: context.l10n.dlgCancel,
            ),
          ],
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.manageProviderSheetTitleLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: _startEditingTitle,
          icon: Icon(
            Icons.edit_outlined,
            color: ThemeProvider.tealPrimary,
          ),
          tooltip: context.l10n.manageProviderSheetEditTitleTooltip,
        ),
      ],
    );
  }

  Widget _buildSubscriberRow(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.people_outline,
            size: 20,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 12),
          Text(
            context.l10n.manageProviderSheetSubscribers(_subscriberCount),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPointersSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.manageProviderSheetPointers,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        if (_pointerTypes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              context.l10n.manageProviderSheetNoPointers,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ...List.generate(_pointerTypes.length, (i) {
            return _buildPointerRow(i, theme);
          }),
      ],
    );
  }

  Widget _buildPointerRow(int index, ThemeData theme) {
    final isEditing = _editingPointerIndex == index;
    final type = _pointerTypes[index];
    final value = _pointerValues[index];

    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              child: Text(
                type,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _editPointerController,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _savePointer(index),
              ),
            ),
            const SizedBox(width: 4),
            if (_isSavingPointer)
              const SizedBox(
                width: 24,
                height: 24,
                child: PhigitalLoadingWidget(size: 14, showShadows: false),
              )
            else ...[
              IconButton(
                onPressed: () => _savePointer(index),
                icon: Icon(Icons.check, size: 20, color: ThemeProvider.tealPrimary),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
                tooltip: context.l10n.manageProviderSheetSaveTooltip,
              ),
              IconButton(
                onPressed: _cancelEditingPointer,
                icon: Icon(
                  Icons.close,
                  size: 20,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
                tooltip: context.l10n.dlgCancel,
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              type,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: (_isDeletingPointer || _isSavingPointer)
                ? null
                : () => _startEditingPointer(index),
            icon: Icon(
              Icons.edit_outlined,
              size: 18,
              color: ThemeProvider.tealPrimary,
            ),
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
            tooltip: context.l10n.manageProviderSheetEditPointerTooltip,
          ),
          IconButton(
            onPressed: (_isDeletingPointer || _isSavingPointer)
                ? null
                : () => _showDeletePointerConfirmation(index),
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: Colors.red.withValues(alpha: _isDeletingPointer ? 0.5 : 1.0),
            ),
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
            tooltip: context.l10n.manageProviderSheetRemovePointerTooltip,
          ),
        ],
      ),
    );
  }

  Widget _buildAddPointerSection(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: TextField(
            controller: _newPointerTypeController,
            decoration: InputDecoration(
              labelText: context.l10n.manageProviderSheetPointerTypeLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _newPointerValueController,
            decoration: InputDecoration(
              labelText: context.l10n.manageProviderSheetValueLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 4),
        if (_isAddingPointer)
          const SizedBox(
            width: 24,
            height: 24,
            child: PhigitalLoadingWidget(size: 14, showShadows: false),
          )
        else
          IconButton(
            onPressed: _addPointer,
            icon: Icon(Icons.add_circle_outline, color: ThemeProvider.tealPrimary),
            tooltip: context.l10n.manageProviderSheetAddPointerTooltip,
          ),
      ],
    );
  }

  Widget _buildDeleteSection(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      child: _isDeletingProvider
          ? const Center(
              child: PhigitalLoadingWidget(size: 24),
            )
          : OutlinedButton.icon(
              onPressed: _showDeleteProviderConfirmation,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
              ),
              icon: const Icon(Icons.delete_forever),
              label: Text(
                context.l10n.manageProviderSheetDeleteTitle(
                  widget.config.typeName,
                ),
              ),
            ),
    );
  }
}
