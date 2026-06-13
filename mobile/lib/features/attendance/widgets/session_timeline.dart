import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../models/attendance.dart';

/// Vertical timeline of the day's START/BREAK/RESUME/END taps. Each item
/// fades + slides in once on mount, so a freshly added session animates while
/// existing ones stay put (keyed by session id).
class SessionTimeline extends StatelessWidget {
  const SessionTimeline({super.key, required this.sessions});

  final List<AttendanceSession> sessions;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    if (sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
        child: Text(
          'No activity yet today.',
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
        ),
      );
    }

    // Newest first reads more naturally in a feed.
    final ordered = [...sessions]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < ordered.length; i++)
          _AppearOnce(
            key: ValueKey('session-${ordered[i].id}-${ordered[i].timestamp.millisecondsSinceEpoch}'),
            child: _TimelineItem(
              session: ordered[i],
              isFirst: i == 0,
              isLast: i == ordered.length - 1,
            ),
          ),
      ],
    );
  }
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.session,
    required this.isFirst,
    required this.isLast,
  });

  final AttendanceSession session;
  final bool isFirst;
  final bool isLast;

  Color _color(BuildContext context) {
    final c = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return switch (session.type) {
      SessionType.start => scheme.primary,
      SessionType.resume => scheme.primary,
      SessionType.breakk => c.statusIdle,
      SessionType.end => scheme.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final color = _color(context);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.16),
                ),
                child: Icon(session.type.icon, size: 18, color: color),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: colors.textSecondary.withValues(alpha: 0.18),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppDimens.grid * 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          session.type.label,
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: scheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _hhmmss(session.timestamp),
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                  if (session.lat != null && session.lng != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.place_rounded,
                            size: 12, color: colors.textSecondary),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            '${session.lat!.toStringAsFixed(5)}, '
                            '${session.lng!.toStringAsFixed(5)}',
                            style: AppTextStyles.caption
                                .copyWith(color: colors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (session.notes != null && session.notes!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      session.notes!,
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _hhmmss(DateTime dt) {
  final l = dt.toLocal();
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Fades + rises its child in once on first mount.
class _AppearOnce extends StatefulWidget {
  const _AppearOnce({super.key, required this.child});
  final Widget child;

  @override
  State<_AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<_AppearOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.12),
          end: Offset.zero,
        ).animate(_fade),
        child: widget.child,
      ),
    );
  }
}
