import 'package:material_ui/material_ui.dart';

import '../aer_keys.dart';

/// Responsive modal dialog shell with a clean, tint-free neutral surface,
/// compact height (~72% of usable screen height when keyboard is closed),
/// pinned header/footer, and smooth scrollable body.
class AdaptiveDialogShell extends StatefulWidget {
  const AdaptiveDialogShell({
    super.key,
    required this.title,
    this.titleTrailing,
    required this.child,
    required this.actions,
    this.maxWidth = 500,
    this.heightFactor = 0.70,
    this.maxHeightCap = 860,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  final Widget title;
  final Widget? titleTrailing;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  final double heightFactor;
  final double maxHeightCap;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<AdaptiveDialogShell> createState() => _AdaptiveDialogShellState();
}

class _AdaptiveDialogShellState extends State<AdaptiveDialogShell> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, viewportConstraints) {
        final double screenW = viewportConstraints.hasBoundedWidth &&
                viewportConstraints.maxWidth > 0
            ? viewportConstraints.maxWidth
            : media.size.width;
        final double screenH = viewportConstraints.hasBoundedHeight &&
                viewportConstraints.maxHeight > 0
            ? viewportConstraints.maxHeight
            : media.size.height;

        final double keyboardBottom = media.viewInsets.bottom;
        final double safeVertical = media.padding.top + media.padding.bottom;
        final double usableH =
            (screenH - safeVertical - keyboardBottom).clamp(180.0, 4000.0);

        final double horizontalInset = screenW < 360 ? 12.0 : 18.0;
        final double verticalInset = keyboardBottom > 0
            ? 12.0
            : (usableH * ((1.0 - widget.heightFactor) / 2.0))
                .clamp(20.0, 140.0);

        final double resolvedMaxHeight = keyboardBottom > 0
            ? (usableH - 24.0).clamp(160.0, widget.maxHeightCap)
            : (usableH < 400.0
                ? (usableH * 0.86).clamp(180.0, widget.maxHeightCap)
                : (usableH * widget.heightFactor)
                    .clamp(260.0, widget.maxHeightCap));

        final double resolvedMaxWidth =
            (screenW - horizontalInset * 2).clamp(220.0, widget.maxWidth);

        return Dialog(
          backgroundColor: cs.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 6,
          insetPadding: EdgeInsets.symmetric(
            horizontal: horizontalInset,
            vertical: verticalInset,
          ),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: ConstrainedBox(
            key: AerKeys.adaptiveDialogCard,
            constraints: BoxConstraints(
              maxWidth: resolvedMaxWidth,
              maxHeight: resolvedMaxHeight,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle(
                          style: (theme.textTheme.titleMedium ??
                                  const TextStyle(fontSize: 17))
                              .copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: widget.title,
                        ),
                      ),
                      if (widget.titleTrailing != null) ...[
                        const SizedBox(width: 8),
                        widget.titleTrailing!,
                      ],
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
                Flexible(
                  fit: FlexFit.loose,
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    radius: const Radius.circular(4),
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: widget.contentPadding,
                      child: widget.child,
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 6,
                    children: widget.actions,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
