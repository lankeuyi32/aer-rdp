import 'package:material_ui/material_ui.dart';

import '../../services/scancode_mapper.dart';
import '../aer_keys.dart';

class SpecialKeyBar extends StatelessWidget {
  const SpecialKeyBar({
    super.key,
    required this.activeModifiers,
    required this.onToggleModifier,
    required this.onPressSpecialKey,
    required this.onCtrlAltDel,
  });

  final Set<StickyModifier> activeModifiers;
  final ValueChanged<StickyModifier> onToggleModifier;
  final ValueChanged<ScancodeSpec> onPressSpecialKey;
  final VoidCallback onCtrlAltDel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: AerKeys.specialKeyBar,
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mod in StickyModifier.values) ...[
              FilterChip(
                label: Text(mod.label),
                selected: activeModifiers.contains(mod),
                onSelected: (_) => onToggleModifier(mod),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
            ],
            ActionChip(
              label: const Text('Ctrl+Alt+Del'),
              onPressed: onCtrlAltDel,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 6),
            for (final entry in ScancodeMapper.specialKeys) ...[
              ActionChip(
                label: Text(entry.label),
                onPressed: () => onPressSpecialKey(entry.spec),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}
