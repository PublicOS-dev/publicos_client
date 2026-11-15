import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
class ContactProfileSettings extends StatefulWidget {
  final Contact contact;

  const ContactProfileSettings({
    super.key,
    required this.contact,
  });

  @override
  State<ContactProfileSettings> createState() => _ContactProfileSettingsState();
}

class _ContactProfileSettingsState extends State<ContactProfileSettings> {
  bool _isLoading = true;
  late Contact _contactData;
  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    _contactData = widget.contact;
    _isBlocked = widget.contact.isBlocked;
    _loadContactData();
  }

  Future<void> _loadContactData() async {
    setState(() => _isLoading = true);

    try {
      if (widget.contact.publicosAddress != null) {
        final updatedContact = await PublicOSContacts.fetchContact(widget.contact.publicosAddress!);
        if (mounted) {
          setState(() {
            _contactData = updatedContact;
            _isLoading = false;
          });
        }
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print('Error loading contact data: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _copyToClipboard(String text, String label) {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    Clipboard.setData(ClipboardData(text: text)).then((_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.contactProfileSettingsCopiedToClipboard(label))),
      );
    });
  }

  String _formatAddress(String? address) {
    if (address == null || address.isEmpty || address.length < 10) {
      return context.l10n.contactProfileSettingsInvalidAddress;
    }
    return "${address.substring(0, 6)}...${address.substring(address.length - 4)}";
  }

  Future<void> _toggleBlockContact() async {
    final l10n = context.l10n;
    try {
      final updatedContact = _contactData.copyWith(
        isBlocked: !_isBlocked,
      );

      await PublicOSContacts.saveContact(updatedContact);

      if (mounted) {
        setState(() {
          _isBlocked = !_isBlocked;
          _contactData = updatedContact;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isBlocked ? l10n.contactProfileSettingsContactBlocked : l10n.contactProfileSettingsContactUnblocked)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedError(l10n, e))),
        );
      }
    }
  }

  Widget _buildAddress(String label, String? address) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
          if (address != null)
            GestureDetector(
              onTap: () => _copyToClipboard(address, label),
              child: Row(
                children: [
                  Text(
                    _formatAddress(address),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.copy, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRegisteredIdEntry(String label, String inboxId) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () => _copyToClipboard(inboxId, context.l10n.contactProfileSettingsInboxIdLabel(label)),
            child: Row(
              children: [
                Text(
                  _formatAddress(inboxId), // Assuming _formatAddress works well for inbox IDs too
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.copy, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Center(child: PhigitalLoadingWidget(size: 32))
        : RefreshIndicator(
            onRefresh: _loadContactData,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Contact info card
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.contactProfileSettingsManageContact,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      _buildAddress(context.l10n.contactProfileSettingsContactOSAddress, _contactData.publicosAddress?.eip55With0x),
                      _buildAddress(context.l10n.contactProfileSettingsPrimaryInboxId, _contactData.registeredInboxIDs?.firstOrNull?.inboxId),
                      // Display Registered Inbox IDs
                      if (_contactData.registeredInboxIDs != null && _contactData.registeredInboxIDs!.isNotEmpty) ...[
                        const Divider(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Text(
                            context.l10n.contactProfileSettingsRegisteredInboxIds,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18), // Slightly smaller than main title
                          ),
                        ),
                        ..._contactData.registeredInboxIDs!.map((item) {
                          final label = item.label ?? context.l10n.contactProfileSettingsDefaultLabel;
                          final inboxId = item.inboxId;
                          if (inboxId == null) return const SizedBox.shrink(); // Should not happen if data is clean
                          return _buildRegisteredIdEntry(label, inboxId);
                        }).toList(),
                      ] else ...[
                        // Optionally, show a placeholder if there are no registered IDs
                        // const Padding(
                        //   padding: EdgeInsets.symmetric(vertical: 8.0),
                        //   child: Text('No registered inbox IDs.', style: TextStyle(fontStyle: FontStyle.italic)),
                        // ),
                      ],

                      const Divider(height: 24),

                      // Block/Unblock option
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_isBlocked ? context.l10n.contactProfileSettingsUnblockContact : context.l10n.contactProfileSettingsBlockContact),
                        leading: Icon(
                          _isBlocked ? Icons.check_circle : Icons.block,
                          color: _isBlocked ? ThemeProvider.successLight : ThemeProvider.errorLight,
                        ),
                        onTap: _toggleBlockContact,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
  }
}
