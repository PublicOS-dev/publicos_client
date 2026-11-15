import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'inbox_id_dropdown.dart';
import 'draggable_contact_icon.dart';

class XmtpContactTile extends StatefulWidget {
  final Contact contact;
  final double size;
  final double textSize;
  final Function(Contact) onContactSelected;
  final bool isSelected;

  const XmtpContactTile({
    super.key,
    required this.contact,
    this.size = 64,
    this.textSize = 14,
    required this.onContactSelected,
    this.isSelected = false,
  });

  @override
  State<XmtpContactTile> createState() => _XmtpContactTileState();
}

class _XmtpContactTileState extends State<XmtpContactTile> {

  void _handleContactTap() {
    // Simplified: always directly select the contact
    widget.onContactSelected(widget.contact);
  }

  // Unused helper retained in case a future UI revision wants a popover
  // dropdown of the contact's registered inbox IDs. Currently `_handleContactTap`
  // is the only wiring; keep here so the import graph stays the same.
  // ignore: unused_element
  void _showInboxIdModal() {
    final entries = widget.contact.registeredInboxIDs ?? const <InboxEntry>[];
    final mapped = entries
        .map((e) => <String, dynamic>{
              'inboxId': e.inboxId,
              'label': e.label,
            })
        .toList();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
          backgroundColor: Colors.transparent,
          child: InboxIdDropdown(
            contact: widget.contact,
            inboxIds: mapped,
            onInboxIdSelected: (contact, inboxId, label) {
              Navigator.of(context).pop();
              _handleInboxIdSelected(contact, inboxId, label);
            },
            showAbove: false,
          ),
        );
      },
    );
  }

  void _handleInboxIdSelected(Contact contact, String inboxId, String label) {
    // Contact in Core 1.0 is pure identity — the chosen inbox ID is not
    // stored on it. Just bump the display name so the caller's selection
    // list visibly reflects which device was picked. Callers that need to
    // track the inbox ID must keep it in a parallel structure.
    final selectedContact = contact.copyWith(
      displayName: '${contact.displayName} ($label)',
    );

    widget.onContactSelected(selectedContact);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableContactIcon(
      contact: widget.contact,
      size: widget.size,
      textSize: widget.textSize,
      onTap: _handleContactTap,
      isSelected: widget.isSelected,
    );
  }
}
