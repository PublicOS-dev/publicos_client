import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/components/messages/sheets/denied_conversations_sheet.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/components/phigital_bottom_sheet.dart';
class XMTPSettingsSheet extends StatefulWidget {
  const XMTPSettingsSheet({super.key});

  @override
  State<XMTPSettingsSheet> createState() => _XMTPSettingsSheetState();
}

class _XMTPSettingsSheetState extends State<XMTPSettingsSheet> {
  bool _sendReadReceipts = false; // Default: do not send
  bool _displayReadReceipts = true; // Default: do display
  bool _loadingSettings = true;

  @override
  void initState() {
    super.initState();
    _loadReadReceiptSettings();
  }

  Future<void> _loadReadReceiptSettings() async {
    try {
      final sendSetting = await PublicOSSettings.getSetting('read_receipt_send');
      final displaySetting = await PublicOSSettings.getSetting('read_receipt_display');

      if (mounted) {
        setState(() {
          // Default false for send, true for display
          _sendReadReceipts = sendSetting?.value == 'true';
          _displayReadReceipts = displaySetting?.value != 'false'; // Default true
          _loadingSettings = false;
        });
      }
    } catch (e) {
      print('Error loading read receipt settings: $e');
      if (mounted) {
        setState(() => _loadingSettings = false);
      }
    }
  }

  Future<void> _setSendReadReceipts(bool value) async {
    setState(() => _sendReadReceipts = value);
    final record = Record.asSettings(
      key: 'read_receipt_send',
      value: value.toString(),
      expiration: DateTime.now().add(const Duration(days: 365)),
      isExpired: false,
      isSystem: true,
    );
    await PublicOSSettings.setSetting('read_receipt_send', record);
  }

  Future<void> _setDisplayReadReceipts(bool value) async {
    setState(() => _displayReadReceipts = value);
    final record = Record.asSettings(
      key: 'read_receipt_display',
      value: value.toString(),
      expiration: DateTime.now().add(const Duration(days: 365)),
      isExpired: false,
      isSystem: true,
    );
    await PublicOSSettings.setSetting('read_receipt_display', record);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                context.l10n.xmtpSettingsSheetTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
                color: ThemeProvider.tealPrimary,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Read Receipts Section
          Text(
            context.l10n.xmtpSettingsSheetReadReceiptsHeader,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.xmtpSettingsSheetReadReceiptsDescription,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.xmtpSettingsSheetSendReadReceiptsTitle),
            subtitle: Text(context.l10n.xmtpSettingsSheetSendReadReceiptsSubtitle),
            value: _sendReadReceipts,
            onChanged: _loadingSettings ? null : (value) => _setSendReadReceipts(value),
            activeColor: ThemeProvider.tealPrimary,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.xmtpSettingsSheetDisplayReadReceiptsTitle),
            subtitle: Text(context.l10n.xmtpSettingsSheetDisplayReadReceiptsSubtitle),
            value: _displayReadReceipts,
            onChanged: _loadingSettings ? null : (value) => _setDisplayReadReceipts(value),
            activeColor: ThemeProvider.tealPrimary,
          ),
          const Divider(height: 32),

          // Denied Convos Button
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ThemeProvider.tealPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
            ),
            onPressed: () {
              Navigator.pop(context);
              showPhigitalBottomSheet(
                context: context,
                builder: (context, isDark) => const DeniedConversationsSheet(),
              );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.block, color: Theme.of(context).colorScheme.onSurface),
                const SizedBox(width: 8),
                Text(context.l10n.xmtpSettingsSheetDeniedConvosButton, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
