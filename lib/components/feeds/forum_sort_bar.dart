import 'package:flutter/material.dart';
import 'package:publicos_client/components/explorer/chip_bar.dart';

enum ChannelSort { newest, top, hot, controversial }

extension ChannelSortLabel on ChannelSort {
  String get label {
    switch (this) {
      case ChannelSort.newest: return 'New';
      case ChannelSort.top: return 'Top';
      case ChannelSort.hot: return 'Hot';
      case ChannelSort.controversial: return 'Controversial';
    }
  }

  String get queryParam {
    switch (this) {
      case ChannelSort.newest: return 'new';
      case ChannelSort.top: return 'top';
      case ChannelSort.hot: return 'hot';
      case ChannelSort.controversial: return 'controversial';
    }
  }
}

/// New / Top / Hot / Controversial, drawn with the explorer chips every
/// other view uses (Messages, Wallet…): `ExplorerChip` in an
/// `ExplorerChipBar`, so the forum keeps the app's look.
class ChannelSortBar extends StatelessWidget {
  final ChannelSort current;
  final ValueChanged<ChannelSort> onChanged;

  const ChannelSortBar({
    super.key,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ExplorerChipBar(
      children: [
        for (final sort in ChannelSort.values) ...[
          ExplorerChip(
            label: sort.label,
            active: sort == current,
            onTap: () => onChanged(sort),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}
