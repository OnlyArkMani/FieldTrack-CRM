import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../services/permission/permission_service.dart';
import '../../../widgets/sync_status_indicator.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/attendance.dart';
import '../providers/attendance_provider.dart';
import '../providers/attendance_history_provider.dart';
import '../providers/upcoming_leaves_provider.dart';
import '../widgets/attendance_timer.dart';
import '../widgets/leave_action.dart';
import '../widgets/session_timeline.dart';
import '../widgets/work_summary_sheet.dart';
import '../widgets/re_checkin_remark_sheet.dart';

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
  bool _bgLimited = false; // foreground-only location → background tracking limited

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  /// Gate attendance START behind the location-permission flow. Only calls the
  /// START API once permission is (at least) foreground-granted.
  Future<void> _startWithPermission() async {
    final result =
        await PermissionService.instance.requestLocationPermissions(context);
    if (!mounted) return;
    if (result == PermissionResult.denied ||
        result == PermissionResult.deniedForever) {
      return; // PermissionService already showed the messaging.
    }
    setState(() =>
        _bgLimited = result == PermissionResult.grantedForegroundOnly);
    await ref.read(attendanceProvider.notifier).start();
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
          onRefresh: () async {
            await Future.wait([
              ref.read(attendanceProvider.notifier).load(),
              ref.read(attendanceHistoryProvider.notifier).load(),
              ref.read(upcomingLeavesProvider.notifier).load(),
            ]);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            children: [
              _Greeting(name: user?.name),
              const SizedBox(height: AppDimens.grid * 2),
              if (state.isLoading)
                const AttendanceCardShimmer()
              else ...[
                _ShakeWrapper(
                  controller: _shake,
                  child: _StatusCard(
                    state: state,
                    onEndTap: _onEndTap,
                    onStart: _startWithPermission,
                  ),
                ),
                if (!state.state.isOnLeave) ...[
                  const SizedBox(height: AppDimens.grid * 1.5),
                  _ApplyLeaveLink(
                    restrictToFuture: !state.state.notStarted,
                    isBusy: state.isMarkingLeave,
                  ),
                ],
              ],
              if (_bgLimited && !state.isLoading) ...[
                const SizedBox(height: AppDimens.grid * 1.5),
                const _BackgroundWarningCard(),
              ],
              const SizedBox(height: AppDimens.grid * 3),
              if (!state.isLoading) ...[
                const _UpcomingLeavesSection(),
                const SizedBox(height: AppDimens.grid * 3),
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
                const SizedBox(height: AppDimens.grid * 4),
                const _AttendanceHistorySection(),
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
  const _StatusCard({
    required this.state,
    required this.onEndTap,
    required this.onStart,
  });

  final AttendanceUiState state;
  final VoidCallback onEndTap;
  final VoidCallback onStart;

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
      return _NotStarted(
        key: const ValueKey('not_started'),
        state: state,
        onStart: onStart,
      );
    }
    if (s.isWorking) {
      return _Working(
          key: const ValueKey('working'), state: state, onEndTap: onEndTap);
    }
    if (s.isOnBreak) {
      return _OnBreak(
          key: const ValueKey('on_break'), state: state, onEndTap: onEndTap);
    }
    if (s.isOnLeave) {
      return _OnLeave(key: const ValueKey('on_leave'), state: state);
    }
    return _Ended(key: const ValueKey('ended'), state: state);
  }
}

// ── Visual states ──────────────────────────────────────────────────────────

class _NotStarted extends ConsumerWidget {
  const _NotStarted({super.key, required this.state, required this.onStart});
  final AttendanceUiState state;
  final VoidCallback onStart;

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
          onPressed: starting ? null : onStart,
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
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(attendanceProvider.notifier);
    final startedAt = state.attendance?.activeSessionStart ?? DateTime.now();
    final breaking =
        state.isSubmitting && state.pendingAction == SessionType.breakk;
    final ending =
        state.isSubmitting && state.pendingAction == SessionType.end;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.statusActive,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'ACTIVE WORK SESSION',
              style: AppTextStyles.caption.copyWith(
                color: colors.statusActive,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 0.5),
        Text(
          'Working since ${_hhmm(startedAt)}',
          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 3,
            vertical: AppDimens.grid * 1.5,
          ),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppDimens.cardRadius),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.15),
              width: 1.5,
            ),
          ),
          child: AttendanceTimer(start: startedAt),
        ),
        const SizedBox(height: AppDimens.grid * 3),
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.statusIdle,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'ON BREAK',
              style: AppTextStyles.caption.copyWith(
                color: colors.statusIdle,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 3,
            vertical: AppDimens.grid * 1.5,
          ),
          decoration: BoxDecoration(
            color: colors.statusIdle.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppDimens.cardRadius),
            border: Border.all(
              color: colors.statusIdle.withValues(alpha: 0.15),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.local_cafe_rounded, size: 24, color: colors.statusIdle),
              const SizedBox(width: 12),
              DefaultTextStyle(
                style: AppTextStyles.display.copyWith(
                  color: colors.statusIdle,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Paused: '),
                    ElapsedLabel(
                      start: breakStart,
                      style: AppTextStyles.display.copyWith(
                        color: colors.statusIdle,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.grid * 3),
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

class _OnLeave extends StatelessWidget {
  const _OnLeave({super.key, required this.state});
  final AttendanceUiState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
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
                color: colors.statusIdle.withValues(alpha: 0.16),
              ),
              child: Icon(Icons.beach_access_rounded,
                  size: 22, color: colors.statusIdle),
            ),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: Text(
                'On leave',
                style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 2),
        Text(
          'You marked today as a leave day.',
          style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _Ended extends ConsumerWidget {
  const _Ended({super.key, required this.state});
  final AttendanceUiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        const SizedBox(height: AppDimens.grid * 2.5),
        AppButton(
          label: 'Re-Check In',
          icon: Icons.replay_rounded,
          variant: AppButtonVariant.secondary,
          isLoading:
              state.isSubmitting && state.pendingAction == SessionType.reCheckIn,
          onPressed: state.isSubmitting
              ? null
              : () async {
                  final remark = await showReCheckInRemarkSheet(context);
                  if (remark != null && context.mounted) {
                    await ref
                        .read(attendanceProvider.notifier)
                        .reCheckIn(remark);
                  }
                },
        ),
      ],
    );
  }
}

/// Text-button link to the shared leave-application flow. `restrictToFuture`
/// must be true whenever today already has an attendance row — today is not
/// a selectable leave date once claimed by check-in/checkout/leave.
class _ApplyLeaveLink extends ConsumerWidget {
  const _ApplyLeaveLink({required this.restrictToFuture, required this.isBusy});
  final bool restrictToFuture;
  final bool isBusy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: isBusy
            ? null
            : () => applyForLeave(context, ref, restrictToFuture: restrictToFuture),
        icon: const Icon(Icons.beach_access_rounded, size: 18),
        label: Text(restrictToFuture ? 'Apply leave for a future day' : 'Apply for leave'),
      ),
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

/// Persistent nudge shown while location is foreground-only — background
/// tracking may pause when the screen is off.
class _BackgroundWarningCard extends StatelessWidget {
  const _BackgroundWarningCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      color: scheme.error.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.error, size: 20),
          const SizedBox(width: AppDimens.grid),
          Expanded(
            child: Text(
              "Background tracking limited — grant 'Always' location for full accuracy",
              style: AppTextStyles.caption.copyWith(color: scheme.onSurface),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppDimens.grid),
          TextButton(
            onPressed: () => Geolocator.openLocationSettings(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Fix', maxLines: 1),
          ),
        ],
      ),
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

class _AttendanceHistorySection extends ConsumerWidget {
  const _AttendanceHistorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyState = ref.watch(attendanceHistoryProvider);
    final notifier = ref.read(attendanceHistoryProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Attendance History',
                style: AppTextStyles.heading.copyWith(fontSize: 18),
              ),
            ),
            if (historyState.isLoading) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppDimens.grid * 1.5),
            ],
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.grid * 1.5,
                vertical: AppDimens.grid * 0.5,
              ),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.15),
                  width: 1.2,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<HistoryFilterType>(
                  value: historyState.filterType,
                  isDense: true,
                  icon: Icon(
                    Icons.arrow_drop_down_rounded,
                    color: scheme.primary,
                    size: 20,
                  ),
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  dropdownColor: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  onChanged: (type) {
                    if (type != null) {
                      if (type == HistoryFilterType.custom) {
                        _showCustomRangePicker(context, ref);
                      } else {
                        notifier.setFilter(type);
                      }
                    }
                  },
                  items: HistoryFilterType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.label),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: AppDimens.grid * 1.5),

        // Custom Date Range Display
        if (historyState.filterType == HistoryFilterType.custom &&
            historyState.startDate != null &&
            historyState.endDate != null) ...[
          InkWell(
            onTap: () => _showCustomRangePicker(context, ref),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.grid * 2,
                vertical: AppDimens.grid * 1.5,
              ),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Text(
                    '${DateFormat('d MMM yyyy').format(historyState.startDate!)}  —  ${DateFormat('d MMM yyyy').format(historyState.endDate!)}',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.edit_calendar_rounded, size: 16, color: scheme.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppDimens.grid * 2),
        ],

        // Error message
        if (historyState.error != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
            child: Text(
              historyState.error!,
              style: AppTextStyles.bodyMedium.copyWith(color: scheme.error),
            ),
          ),
        ],

        // History logs
        if (historyState.entries.isEmpty && !historyState.isLoading)
          const _EmptyHistory()
        else ...[
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: historyState.entries.length,
            separatorBuilder: (context, index) => const SizedBox(height: AppDimens.grid * 1.5),
            itemBuilder: (context, index) {
              final entry = historyState.entries[index];
              return _HistoryCard(entry: entry);
            },
          ),
          if (historyState.hasMore) ...[
            const SizedBox(height: AppDimens.grid * 2),
            Center(
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: historyState.isLoadingMore
                      ? null
                      : () => ref.read(attendanceHistoryProvider.notifier).loadMore(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 1.5),
                    side: BorderSide(color: scheme.primary.withValues(alpha: 0.3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                    ),
                  ),
                  child: historyState.isLoadingMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Load More',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ] else if (historyState.entries.length >= 30) ...[
            const SizedBox(height: AppDimens.grid * 3),
            Center(
              child: Text(
                'End of history logs',
                style: AppTextStyles.caption.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Future<void> _showCustomRangePicker(BuildContext context, WidgetRef ref) async {
    final historyState = ref.read(attendanceHistoryProvider);
    final initialRange = (historyState.startDate != null && historyState.endDate != null)
        ? DateTimeRange(start: historyState.startDate!, end: historyState.endDate!)
        : DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 7)),
            end: DateTime.now(),
          );

    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      lastDate: DateTime.now(),
      initialDateRange: initialRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Theme.of(context).colorScheme.primary,
                  onPrimary: Theme.of(context).colorScheme.onPrimary,
                  surface: Theme.of(context).colorScheme.surface,
                  onSurface: Theme.of(context).colorScheme.onSurface,
                ),
          ),
          child: child!,
        );
      },
    );

    if (range != null) {
      ref.read(attendanceHistoryProvider.notifier).setCustomRange(range.start, range.end);
    }
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppDimens.grid * 3),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 40,
              color: context.appColors.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppDimens.grid),
            Text(
              'No logs found in this range',
              style: AppTextStyles.bodyMedium.copyWith(
                color: context.appColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({required this.entry});
  final Attendance entry;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final entry = widget.entry;

    // Status colors
    final (Color badgeBg, Color badgeFg) = switch (entry.status) {
      AttendanceStatusValue.present => (Colors.green.shade50, Colors.green.shade700),
      AttendanceStatusValue.onLeave => (Colors.blue.shade50, Colors.blue.shade700),
      AttendanceStatusValue.halfDay => (Colors.orange.shade50, Colors.orange.shade700),
      AttendanceStatusValue.absent || _ => (Colors.red.shade50, Colors.red.shade700),
    };

    final statusLabel = switch (entry.status) {
      AttendanceStatusValue.present => 'Present',
      AttendanceStatusValue.onLeave => 'On Leave',
      AttendanceStatusValue.halfDay => 'Half Day',
      AttendanceStatusValue.absent || _ => 'Absent',
    };

    // Calculate hours / minutes
    final hours = entry.totalDurationMinutes ~/ 60;
    final mins = entry.totalDurationMinutes % 60;
    final durationStr = hours > 0 ? '${hours}h ${mins}m' : '${mins}m';
    final distanceKm = (entry.totalDistanceMeters / 1000).toStringAsFixed(1);

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppDimens.grid * 2,
              vertical: AppDimens.grid * 0.5,
            ),
            title: Text(
              DateFormat('EEE, d MMM yyyy').format(entry.date),
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppDimens.grid * 0.75),
              child: Row(
                children: [
                  Icon(Icons.timer_outlined, size: 14, color: colors.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    durationStr,
                    style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(width: AppDimens.grid * 2),
                  Icon(Icons.directions_walk_rounded, size: 14, color: colors.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    '${distanceKm} km',
                    style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    statusLabel,
                    style: AppTextStyles.caption.copyWith(
                      color: badgeFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entry.sessions.isNotEmpty) ...[
                  const SizedBox(width: AppDimens.grid),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: colors.textSecondary,
                  ),
                ],
              ],
            ),
            onTap: entry.sessions.isEmpty
                ? null
                : () {
                    setState(() {
                      _expanded = !_expanded;
                    });
                  },
          ),
          if (_expanded && entry.sessions.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppDimens.grid * 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Timeline Logs',
                    style: AppTextStyles.caption.copyWith(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppDimens.grid * 1.5),
                  SessionTimeline(sessions: entry.sessions),
                  if (entry.workSummary != null && entry.workSummary!.isNotEmpty) ...[
                    const SizedBox(height: AppDimens.grid * 1.5),
                    const Divider(),
                    const SizedBox(height: AppDimens.grid),
                    Text(
                      'Work Summary',
                      style: AppTextStyles.caption.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      entry.workSummary!,
                      style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UpcomingLeavesSection extends ConsumerWidget {
  const _UpcomingLeavesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(upcomingLeavesProvider);
    final scheme = Theme.of(context).colorScheme;

    if (state.leaves.isEmpty && !state.isLoading) {
      return const SizedBox.shrink();
    }

    final displayedLeaves = state.leaves.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Upcoming Leaves',
              style: AppTextStyles.heading.copyWith(fontSize: 18),
            ),
            if (state.isLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppDimens.grid * 1.5),
        if (state.error != null) ...[
          Text(
            state.error!,
            style: AppTextStyles.bodyMedium.copyWith(color: scheme.error),
          ),
          const SizedBox(height: AppDimens.grid),
        ],
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: displayedLeaves.length,
          separatorBuilder: (context, index) =>
              const SizedBox(height: AppDimens.grid),
          itemBuilder: (context, index) {
            final leave = displayedLeaves[index];
            final isThisRevoking = state.revokingId == leave.id;

            return AppCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.grid * 2,
                vertical: AppDimens.grid * 1.5,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('EEE, d MMM yyyy').format(leave.date),
                          style: AppTextStyles.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'On Leave',
                            style: AppTextStyles.caption.copyWith(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppDimens.grid * 2),
                  if (isThisRevoking)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton.icon(
                      onPressed: () => _confirmRevoke(context, ref, leave),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.grid * 1.5,
                          vertical: AppDimens.grid,
                        ),
                      ),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Cancel'),
                    ),
                ],
              ),
            );
          },
        ),
        if (state.leaves.length > 3) ...[
          const SizedBox(height: AppDimens.grid),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const UpcomingLeavesScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: const Text('View All'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmRevoke(
      BuildContext context, WidgetRef ref, Attendance leave) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Leave'),
        content: Text(
          'Are you sure you want to cancel your leave for '
          '${DateFormat('EEEE, d MMMM').format(leave.date)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await ref.read(upcomingLeavesProvider.notifier).revokeLeave(leave.id);
    }
  }
}

class UpcomingLeavesScreen extends ConsumerWidget {
  const UpcomingLeavesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(upcomingLeavesProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Upcoming Leaves'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(upcomingLeavesProvider.notifier).load(),
          child: state.leaves.isEmpty && !state.isLoading
              ? const Center(child: Text('No upcoming leaves'))
              : ListView(
                  padding: const EdgeInsets.all(AppDimens.grid * 2),
                  children: [
                    if (state.error != null) ...[
                      Text(
                        state.error!,
                        style: AppTextStyles.bodyMedium.copyWith(color: scheme.error),
                      ),
                      const SizedBox(height: AppDimens.grid),
                    ],
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: state.leaves.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: AppDimens.grid),
                      itemBuilder: (context, index) {
                        final leave = state.leaves[index];
                        final isThisRevoking = state.revokingId == leave.id;

                        return AppCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.grid * 2,
                            vertical: AppDimens.grid * 1.5,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      DateFormat('EEE, d MMM yyyy').format(leave.date),
                                      style: AppTextStyles.body.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        'On Leave',
                                        style: AppTextStyles.caption.copyWith(
                                          color: Colors.blue.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppDimens.grid * 2),
                              if (isThisRevoking)
                                const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              else
                                TextButton.icon(
                                  onPressed: () => _confirmRevoke(context, ref, leave),
                                  style: TextButton.styleFrom(
                                    foregroundColor: scheme.error,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppDimens.grid * 1.5,
                                      vertical: AppDimens.grid,
                                    ),
                                  ),
                                  icon: const Icon(Icons.cancel_outlined, size: 16),
                                  label: const Text('Cancel'),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _confirmRevoke(
      BuildContext context, WidgetRef ref, Attendance leave) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Leave'),
        content: Text(
          'Are you sure you want to cancel your leave for '
          '${DateFormat('EEEE, d MMMM').format(leave.date)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await ref.read(upcomingLeavesProvider.notifier).revokeLeave(leave.id);
    }
  }
}
