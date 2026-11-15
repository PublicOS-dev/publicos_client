import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';

class DesktopSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TabController? tabController;
  final List<String> movingHintWords;
  final ValueChanged<String>? onSubmitted;

  const DesktopSearchBar({
    super.key,
    required this.controller,
    this.focusNode,
    this.tabController,
    this.movingHintWords = const [],
    this.onSubmitted,
  });

  @override
  State<DesktopSearchBar> createState() => _DesktopSearchBarState();
}

class _DesktopSearchBarState extends State<DesktopSearchBar> {
  bool _isComposing = false;
  bool _isFocused = false;
  double _currentTabOffset = 0.0;
  FocusNode? _internalFocusNode;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateIsComposing);
    _isComposing = widget.controller.text.isNotEmpty;

    widget.tabController?.animation?.addListener(_handleTabScroll);

    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode();
    }

    final focusNode = widget.focusNode ?? _internalFocusNode;
    focusNode?.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateIsComposing);
    widget.tabController?.animation?.removeListener(_handleTabScroll);
    final focusNode = widget.focusNode ?? _internalFocusNode;
    focusNode?.removeListener(_onFocusChange);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final focusNode = widget.focusNode ?? _internalFocusNode;
    if (mounted) {
      setState(() {
        _isFocused = focusNode?.hasFocus ?? false;
      });
    }
  }

  void _updateIsComposing() {
    if (mounted && (widget.controller.text.isNotEmpty != _isComposing)) {
      setState(() {
        _isComposing = widget.controller.text.isNotEmpty;
      });
    }
  }

  void _handleTabScroll() {
    if (widget.tabController?.animation != null) {
      setState(() {
        _currentTabOffset = widget.tabController!.animation!.value;
      });
    }
  }

  void _clearSearch() {
    widget.controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final int currentTabIndex = _currentTabOffset.floor();
    final double scrollFraction = _currentTabOffset - currentTabIndex;

    final String currentWord = currentTabIndex < widget.movingHintWords.length
        ? widget.movingHintWords[currentTabIndex]
        : '';
    final String nextWord =
        (currentTabIndex + 1) < widget.movingHintWords.length
            ? widget.movingHintWords[currentTabIndex + 1]
            : '';
    final currentFocusNode = widget.focusNode ?? _internalFocusNode;

    // Phigital colors
    final bgColor = PhigitalStyle.cardBackground(isDark);
    final borderColor = _isFocused
        ? ThemeProvider.tealPrimary.withValues(alpha: 0.5)
        : PhigitalStyle.subtleBorder(isDark);

    return GestureDetector(
      onTap: () {
        if (currentFocusNode != null && !currentFocusNode.hasFocus) {
          currentFocusNode.requestFocus();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 44.0,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: bgColor,
          border: Border.all(
            color: borderColor,
            width: 1,
          ),
          boxShadow: PhigitalStyle.smallShadow(isDark),
        ),
        child: Stack(
          children: [
            TextField(
              controller: widget.controller,
              focusNode: currentFocusNode,
              autofocus: false,
              onSubmitted: widget.onSubmitted,
              onChanged: (text) {
                _updateIsComposing();
              },
              decoration: InputDecoration(
                hintText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                hintStyle: textStyle,
                fillColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 0.0,
                ),
                suffixIcon: _isComposing
                    ? Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: _clearSearch,
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            // decoration: BoxDecoration(
                            //   // color: PhigitalStyle.subtleBorder(isDark),
                            //   borderRadius: BorderRadius.circular(7),
                            // ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant
                              .withOpacity(0.5),
                        ),
                      ),
                suffixIconConstraints: const BoxConstraints(
                  minHeight: 44,
                  minWidth: 44,
                ),
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 1,
              minLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.search,
            ),
            if (!_isComposing)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Search ',
                            style: textStyle?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.5),
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: ClipRect(
                              child: Stack(
                                children: [
                                  Transform.translate(
                                    offset: Offset(-scrollFraction * 80, 0),
                                    child: Opacity(
                                      opacity: 1 - scrollFraction,
                                      child: Text(
                                        currentWord,
                                        style: textStyle?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant
                                              .withOpacity(0.5),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Transform.translate(
                                    offset:
                                        Offset((1 - scrollFraction) * 80, 0),
                                    child: Opacity(
                                      opacity: scrollFraction,
                                      child: Text(
                                        nextWord,
                                        style: textStyle?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant
                                              .withOpacity(0.5),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
