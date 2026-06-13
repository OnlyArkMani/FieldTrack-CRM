import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'app_button.dart';

/// Lightweight "illustration": concentric ripple rings behind the state
/// icon — a nod to the app's watery transition language, drawn with
/// CustomPainter so no image assets are needed.
class _RippleBackdrop extends StatelessWidget {
  const _RippleBackdrop({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(140, 140),
      painter: _RipplePainter(color: color),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radii = [size.width / 2, size.width / 2.6, size.width / 3.4];
    final alphas = [0.05, 0.08, 0.12];
    for (var i = 0; i < radii.length; i++) {
      canvas.drawCircle(
        center,
        radii[i],
        Paint()..color = color.withValues(alpha: alphas[i]),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Centered empty state: a soft illustration placeholder, a message, and an
/// optional action. Used wherever a list comes back empty.
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_rounded,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppDimens.grid * 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _RippleBackdrop(color: scheme.secondary),
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.secondary.withValues(alpha: 0.12),
                    ),
                    child: Icon(icon, size: 44, color: scheme.secondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (message != null) ...[
              const SizedBox(height: AppDimens.grid),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppDimens.grid * 3),
              AppButton(
                label: actionLabel!,
                onPressed: onAction,
                expanded: false,
                icon: Icons.add_rounded,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state with a specific message and a retry button.
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    required this.message,
    required this.onRetry,
    this.title = 'Something went wrong',
  });

  final String message;
  final String title;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppDimens.grid * 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _RippleBackdrop(color: scheme.error),
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.error.withValues(alpha: 0.12),
                    ),
                    child: Icon(Icons.cloud_off_rounded,
                        size: 44, color: scheme.error),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 3),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppDimens.grid),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppDimens.grid * 3),
            AppButton(
              label: 'Retry',
              onPressed: onRetry,
              expanded: false,
              variant: AppButtonVariant.secondary,
              icon: Icons.refresh_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

/// Fades + rises a child in once, after a per-index delay — the list's
/// staggered entrance (50ms steps). Cheap: one short controller per row,
/// disposed when scrolled away.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.stepMs = 50,
  });

  final int index;
  final Widget child;
  final int stepMs;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    // Cap the cumulative delay so far-down rows don't lag forever.
    final delay = (widget.index.clamp(0, 12)) * widget.stepMs;
    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
