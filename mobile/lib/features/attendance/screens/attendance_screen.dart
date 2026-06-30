import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../widgets/sync_status_indicator.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/attendance.dart';
import '../providers/attendance_provider.dart';
import '../widgets/attendance_timer.dart';
import '../widgets/session_timeline.dart';
import '../widgets/work_summary_sheet.dart';

/// The employee's daily home: the attendance state machine. One prominent
/// status card drives START → BREAK ⇄ RESUME → END, with a live timer, a
/// session timeline, and shake-on-error feedback.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  int _lastErrorNonce = 0;

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _onEndTap() async {
    final summary = await showWorkSummarySheet(context);
    if (summary == null || !mounted) return;
    await ref.read(attendanceProvider.notifier).end(summary);
    if (!mounted) return;
    // After END, poll the state once to get the attendance id, then go to DSR.
    final attendanceState = ref.read(attendanceProvider);
    final attendanceId = attendanceState.attendance?.id;
    if (attendanceId != null && attendanceState.state.name == 'ended') {
      final today = DateTime.now();
      final reportDate = DateTime(today.year, today.month, today.day);
      // Give the background DSR generation a moment to complete before loading.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      context.push('/dsr/review', extra: {'report_date': reportDate});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(attendanceProvider);
    final user = ref.watch(authProvider).user;

    // Fire shake + snackbar whenever a new error arrives.
    ref.listen(attendanceProvider, (prev, next) {
      if (next.errorNonce != _lastErrorNonce && next.error != null) {
        _lastErrorNonce = next.errorNonce;
        _shake
          ..reset()
          ..forward();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: AppDimens.grid * 2),
            child: Center(child: SyncStatusIndicator()),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(attendanceProvider.notifier).load(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            children: [
              _Greeting(name: user?.name),
              const SizedBox(height: AppDimens.grid * 2),
              if (state.isLoading)
                const AttendanceCardShimmer()
              else
                _ShakeWrapper(
                  controller: _shake,
                  child: _StatusCard(state: state, onEndTap: _onEndTap),
                ),
              const SizedBox(height: AppDimens.grid * 3),
              if (!state.isLoading) ...[
                Text(
                  'Today',
                  style: AppTextStyles.caption.copyWith(
                    color: context.appColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: AppDimens.grid),
                SessionTimeline(
                    sessions: state.attendance?.sessions ?? const []),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({this.name});
  final String? name;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final hour = DateTime.now().hour;
    final part = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    final first = (name ?? '').trim().split(RegExp(r'\s+')).first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEEE, d MMMM').format(DateTime.now()),
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          first.isEmpty ? part : '$part, $first',
          style: AppTextStyles.display
              .copyWith(color: scheme.onSurface, fontSize: 24),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// The prominent card. AnimatedSwitcher cross-fades between the four visual
/// states (not started / working / on break / ended).
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.onEndTap});

  final AttendanceUiState state;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppDimens.grid * 3),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeInOutCubic,
        switchOutCurve: Curves.easeInOutCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SizeTransition(
            sizeFactor: anim,
            axisAlignment: -1,
            child: child,
          ),
        ),
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final s = state.state;
    if (state.attendance == null || s.notStarted) {
      return _NotStarted(key: const ValueKey('not_started'), state: state);
    }
    if (s.isWorking) {
      return _Working(
          key: const ValueKey('working'), state: state, onEndTap: onEndTap);
    }
    if (s.isOnBreak) {
      return _OnBreak(
          key: const ValueKey('on_break'), state: state, onEndTap: onEndTap);
    }
    return _Ended(key: const ValueKey('ended'), state: state);
  }
}

// ── Visual states ──────────────────────────────────────────────────────────

class _NotStarted extends ConsumerWidget {
  const _NotStarted({super.key, required this.state});
  final AttendanceUiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final starting =
        state.isSubmitting && state.pendingAction == SessionType.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _PulseRing(),
        const SizedBox(height: AppDimens.grid * 2.5),
        Text(
          'Ready to start your day?',
          style: AppTextStyles.heading
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid * 0.5),
        Text(
          'Tap start to clock in. We’ll capture your location.',
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Start',
          icon: Icons.play_arrow_rounded,
          isLoading: starting,
          onPressed: starting
              ? null
              : () => ref.read(attendanceProvider.notifier).start(),
        ),
      ],
    );
  }
}

class _Working extends ConsumerWidget {
  const _Working({super.key, required this.state, required this.onEndTap});
  final AttendanceUiState state;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final notifier = ref.read(attendanceProvider.notifier);
    final startedAt = state.attendance?.startedAt ?? DateTime.now();
    final breaking =
        state.isSubmitting && state.pendingAction == SessionType.breakk;
    final ending =
        state.isSubmitting && state.pendingAction == SessionType.end;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Working since ${_hhmm(startedAt)}',
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid * 1.5),
        AttendanceTimer(start: startedAt),
        const SizedBox(height: AppDimens.grid * 2.5),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Break',
                icon: Icons.pause_rounded,
                variant: AppButtonVariant.secondary,
                isLoading: breaking,
                onPressed: state.isSubmitting ? null : notifier.takeBreak,
              ),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: AppButton(
                label: 'End',
                icon: Icons.stop_rounded,
                variant: AppButtonVariant.danger,
                isLoading: ending,
                onPressed: state.isSubmitting ? null : onEndTap,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OnBreak extends ConsumerWidget {
  const _OnBreak({super.key, required this.state, required this.onEndTap});
  final AttendanceUiState state;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final notifier = ref.read(attendanceProvider.notifier);
    final breakStart = state.attendance?.breakStartedAt ?? DateTime.now();
    final resuming =
        state.isSubmitting && state.pendingAction == SessionType.resume;
    final ending =
        state.isSubmitting && state.pendingAction == SessionType.end;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.statusIdle.withValues(alpha: 0.16),
          ),
          child: Icon(Icons.local_cafe_rounded,
              size: 36, color: colors.statusIdle),
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text(
          'On break',
          style: AppTextStyles.heading
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        DefaultTextStyle(
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Paused for '),
              ElapsedLabel(
                start: breakStart,
                style: AppTextStyles.caption.copyWith(
                  color: colors.statusIdle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.grid * 2.5),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Resume',
                icon: Icons.play_arrow_rounded,
                isLoading: resuming,
                onPressed: state.isSubmitting ? null : notifier.resume,
              ),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: AppButton(
                label: 'End',
                icon: Icons.stop_rounded,
                variant: AppButtonVariant.danger,
                isLoading: ending,
                onPressed: state.isSubmitting ? null : onEndTap,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Ended extends StatelessWidget {
  const _Ended({super.key, required this.state});
  final AttendanceUiState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final a = state.attendance!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppDimens.grid),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.statusActive.withValues(alpha: 0.16),
              ),
              child: Icon(Icons.check_rounded,
                  size: 22, color: colors.statusActive),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: Text(
                'Day complete',
                style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.timelapse_rounded,
                label: 'Total time',
                value: _fmtMinutes(a.totalDurationMinutes),
              ),
            ),
            Expanded(
              child: _Stat(
                icon: Icons.directions_walk_rounded,
                label: 'Distance',
                value: _fmtDistance(a.totalDistanceMeters),
              ),
            ),
          ],
        ),
        if (a.workSummary != null && a.workSummary!.isNotEmpty) ...[
          const SizedBox(height: AppDimens.grid * 2),
          Text(
            'Work summary',
            style: AppTextStyles.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppDimens.grid * 0.5),
          Text(
            a.workSummary!,
            style: AppTextStyles.body.copyWith(color: scheme.onSurface),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

// ── Small bits ─────────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Row(
      children: [
        Icon(icon, size: 20, color: colors.textSecondary),
        const SizedBox(width: AppDimens.grid),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: Theme.of(context).colorScheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                label,
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Amber pulsing ring behind the START state — invites the tap.
class _PulseRing extends StatefulWidget {
  const _PulseRing();

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      height: 96,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 56 + 40 * t,
                height: 56 + 40 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: (1 - t) * 0.35),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
                child: Icon(Icons.fingerprint_rounded,
                    size: 34, color: scheme.primary),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Horizontal shake driven by an external controller (fired on error).
class _ShakeWrapper extends StatelessWidget {
  const _ShakeWrapper({required this.controller, required this.child});
  final AnimationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Damped oscillation: a few quick shakes that settle to zero.
        final t = controller.value;
        final dx = (t == 0) ? 0.0 : (1 - t) * 12 * math.sin(t * 6 * math.pi);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: child,
    );
  }
}

String _hhmm(DateTime dt) {
  final l = dt.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

String _fmtMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String _fmtDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}
