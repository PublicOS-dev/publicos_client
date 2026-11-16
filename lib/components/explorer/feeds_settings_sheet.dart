import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
class RssFeedsSettingsSheet extends StatefulWidget {
  final Function(double) onTitleTextSizeChanged;
  final Function(double) onDescriptionTextSizeChanged;
  final double currentTitleTextSize;
  final double currentDescriptionTextSize;

  const RssFeedsSettingsSheet({
    super.key,
    required this.onTitleTextSizeChanged,
    required this.onDescriptionTextSizeChanged,
    required this.currentTitleTextSize,
    required this.currentDescriptionTextSize,
  });

  @override
  State<RssFeedsSettingsSheet> createState() => _RssFeedsSettingsSheetState();
}

class _RssFeedsSettingsSheetState extends State<RssFeedsSettingsSheet> {
  // Text size values
  late double _titleTextSize;
  late double _descriptionTextSize;

  @override
  void initState() {
    super.initState();
    _titleTextSize = widget.currentTitleTextSize;
    _descriptionTextSize = widget.currentDescriptionTextSize;
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final titleSizeRecord = await PublicOSSettings.getSetting('rss_feeds_title_text_size');
      final descSizeRecord = await PublicOSSettings.getSetting('rss_feeds_description_text_size');

      if (mounted) {
        setState(() {
          if (titleSizeRecord != null) {
            _titleTextSize = double.parse(titleSizeRecord.value);
          }
          if (descSizeRecord != null) {
            _descriptionTextSize = double.parse(descSizeRecord.value);
          }
        });
      }
    } catch (e) {
      print('Error loading RSS feed settings: $e');
    }
  }

  Future<void> _saveTitleTextSize(double size) async {
    try {
      final record = Record.asSettings(
        key: 'rss_feeds_title_text_size',
        value: size.toString(),
        isSystem: true,
      );

      await PublicOSSettings.setSetting('rss_feeds_title_text_size', record);
      widget.onTitleTextSizeChanged(size);
    } catch (e) {
      print('Error saving title text size: $e');
    }
  }

  Future<void> _saveDescriptionTextSize(double size) async {
    try {
      final record = Record.asSettings(
        key: 'rss_feeds_description_text_size',
        value: size.toString(),
        isSystem: true,
      );

      await PublicOSSettings.setSetting('rss_feeds_description_text_size', record);
      widget.onDescriptionTextSizeChanged(size);
    } catch (e) {
      print('Error saving description text size: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.feedsSettingsSheetTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.feedsSettingsSheetSubtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.tune,
                color: ThemeProvider.tealPrimary,
                size: 32,
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Title Text Size
          _buildTextSizeControl(
            theme: theme,
            isDark: isDark,
            label: context.l10n.feedsSettingsSheetTitleTextSize,
            icon: Icons.title,
            value: _titleTextSize,
            min: 12.0,
            max: 24.0,
            onChanged: (value) {
              setState(() => _titleTextSize = value);
              _saveTitleTextSize(value);
            },
          ),

          const SizedBox(height: 24),

          // Description Text Size
          _buildTextSizeControl(
            theme: theme,
            isDark: isDark,
            label: context.l10n.feedsSettingsSheetDescriptionTextSize,
            icon: Icons.description,
            value: _descriptionTextSize,
            min: 10.0,
            max: 20.0,
            onChanged: (value) {
              setState(() => _descriptionTextSize = value);
              _saveDescriptionTextSize(value);
            },
          ),

          const SizedBox(height: 32),

          // Preview Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: PhigitalStyle.subtleTint(isDark),
              borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
              border: Border.all(color: PhigitalStyle.cardBorder(isDark)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.preview,
                      size: 16,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.feedsSettingsSheetPreview,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.feedsSettingsSheetSamplePostTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: _titleTextSize,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.feedsSettingsSheetSampleDescription,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                    fontSize: _descriptionTextSize,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Reset button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _titleTextSize = 16.0;
                  _descriptionTextSize = 14.0;
                });
                _saveTitleTextSize(16.0);
                _saveDescriptionTextSize(14.0);
              },
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.feedsSettingsSheetResetToDefaults),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextSizeControl({
    required ThemeData theme,
    required bool isDark,
    required String label,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: ThemeProvider.tealPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(PhigitalStyle.radiusButton),
              ),
              child: Text(
                context.l10n.feedsSettingsSheetPointSize(value.toInt()),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ThemeProvider.tealPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: ThemeProvider.tealPrimary,
            inactiveTrackColor: ThemeProvider.tealPrimary.withValues(alpha: 0.2),
            thumbColor: ThemeProvider.tealPrimary,
            overlayColor: ThemeProvider.tealPrimary.withValues(alpha: 0.2),
            trackHeight: 4.0,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) / 1).toInt(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
