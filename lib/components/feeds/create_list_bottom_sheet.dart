import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/utils/emoji_utils.dart';
import 'package:publicos_client/components/feeds/emoji_picker_dialog.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class CreateListBottomSheet extends StatefulWidget {
  final Function(String listName)? onListCreated;
  final FeedList? existingList; // For editing

  const CreateListBottomSheet({
    super.key,
    this.onListCreated,
    this.existingList,
  });

  @override
  State<CreateListBottomSheet> createState() => _CreateListBottomSheetState();
}

class _CreateListBottomSheetState extends State<CreateListBottomSheet> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isCreating = false;
  late String _selectedEmoji;

  bool get _isEditing => widget.existingList != null;

  @override
  void initState() {
    super.initState();

    // Initialize with existing list data or defaults
    if (_isEditing) {
      _nameController.text = widget.existingList!.name;
      _selectedEmoji = widget.existingList!.icon ?? EmojiUtils.getRandomEmoji();
    } else {
      _selectedEmoji = EmojiUtils.getRandomEmoji();
    }

    // Auto-focus the text field when the sheet opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _saveList() async {
    final l10n = context.l10n;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.createListBottomSheetNameRequired)),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      FeedList? list;

      if (_isEditing) {
        // Update existing list
        list = await PublicOSFeedLists.updateList(
          widget.existingList!.id,
          name: name,
          icon: _selectedEmoji,
        );
      } else {
        // Create new list
        list = await PublicOSFeedLists.createList(name, icon: _selectedEmoji);
      }

      if (list != null) {
        if (mounted) {
          widget.onListCreated?.call(name);
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isEditing
                  ? l10n.createListBottomSheetUpdatedList(name)
                  : l10n.createListBottomSheetCreatedList(name)),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isEditing
                  ? l10n.createListBottomSheetUpdateFailed
                  : l10n.createListBottomSheetCreateFailed),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizedError(
              l10n,
              e,
              fallback: _isEditing
                  ? l10n.createListBottomSheetUpdateFailed
                  : l10n.createListBottomSheetCreateFailed,
            )),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  Future<void> _showEmojiPicker() async {
    final emoji = await showEmojiPickerDialog(
      context,
      currentEmoji: _selectedEmoji,
    );
    if (emoji != null && mounted) setState(() => _selectedEmoji = emoji);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            _isEditing
                ? context.l10n.createListBottomSheetEditTitle
                : context.l10n.createListBottomSheetCreateTitle,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            _isEditing
                ? context.l10n.createListBottomSheetEditSubtitle
                : context.l10n.createListBottomSheetCreateSubtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha:0.7),
            ),
          ),
          const SizedBox(height: 24),

          // Name input with emoji selector
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Emoji selector button
              GestureDetector(
                onTap: _isCreating ? null : _showEmojiPicker,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha:0.3),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      _selectedEmoji,
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Name text field
              Expanded(
                child: TextField(
                  controller: _nameController,
                  focusNode: _focusNode,
                  enabled: !_isCreating,
                  decoration: InputDecoration(
                    labelText: context.l10n.createListBottomSheetNameLabel,
                    hintText: context.l10n.createListBottomSheetNameHint,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveList(),
                  maxLength: 50,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _isCreating ? null : () => Navigator.pop(context),
                child: Text(context.l10n.dlgCancel),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _isCreating ? null : _saveList,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isCreating
                    ? const PhigitalLoadingWidget(size: 20, showShadows: false)
                    : Text(_isEditing
                        ? context.l10n.createListBottomSheetUpdateButton
                        : context.l10n.createListBottomSheetCreateButton),
              ),
            ],
          ),
        ],
      ),
    );
  }
}