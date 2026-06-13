import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../../map/screens/trail_replay_screen.dart';
import '../models/employee.dart';
import '../providers/employee_provider.dart';
import '../widgets/employee_avatar.dart';
import '../widgets/employee_edit_sheet.dart';

/// Supervisor/admin-facing employee detail. Hero avatar from the list, live
/// status, today's attendance phase timeline, and a mini map of the last
/// known location.
class EmployeeDetailScreen extends ConsumerWidget {
  const EmployeeDetailScreen({super.key, required this.employeeId});

  final int employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(employeeDetailProvider(employeeId));
    final role = ref.watch(authProvider).user?.role;
    final canEdit = role == UserRole.admin || role == UserRole.supervisor;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: detail.maybeWhen(
        data: (employee) => canEdit
            ? FloatingActionButton.extended(
                onPressed: () => showEmployeeEditSheet(context, employee),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Edit'),
              )
            : null,
        orElse: () => null,
      ),
      body: SafeArea(
        child: detail.when(
          loading: () => ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.all(AppDimens.grid * 2),
            children: const [
              ShimmerCard(height: 132, lines: 3),
              SizedBox(height: AppDimens.grid * 1.5),
              ShimmerCard(),
              SizedBox(height: AppDimens.grid * 1.5),
              ShimmerCard(height: 200, lines: 1),
            ],
          ),
          error: (e, _) => ErrorStateView(
            message: e.toString(),
            onRetry: () => ref.invalidate(employeeDetailProvider(employeeId)),
          ),
          data: (employee) => RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(employeeDetailProvider(employeeId));
              ref.invalidate(attendanceSummaryProvider(employeeId));
              ref.invalidate(lastLocationProvider(employeeId));
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppDimens.grid * 2,
                AppDimens.grid * 2,
                AppDimens.grid * 2,
                AppDimens.grid * 10, // clear the FAB
              ),
              children: [
                _HeaderCard(employee: employee),
                const SizedBox(height: AppDimens.grid * 1.5),
                AppButton(
                  label: 'View Trail',
                  icon: Icons.timeline_rounded,
                  variant: AppButtonVariant.secondary,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TrailReplayScreen(
                        employeeId: employee.id,
                        employeeName: employee.name,
                        photoUrl: employee.profilePhotoUrl,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppDimens.grid * 1.5),
                _StatusCard(employee: employee),
                const SizedBox(height: AppDimens.grid * 1.5),
                _ContactCard(employee: employee),
                const SizedBox(height: AppDimens.grid * 1.5),
                _TodayAttendanceCard(employeeId: employeeId, live: employee.live),
                const SizedBox(height: AppDimens.grid * 1.5),
                _LocationCard(employeeId: employeeId),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Row(
        children: [
          EmployeeAvatar(
            initials: employee.initials,
            photoUrl: employee.profilePhotoUrl,
            radius: 34,
            heroTag: 'emp-avatar-${employee.id}',
          ),
          const SizedBox(width: AppDimens.grid * 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  employee.name,
                  style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppDimens.grid * 0.5),
                Row(
                  children: [
                    RoleBadge(label: employee.role.label),
                    const SizedBox(width: AppDimens.grid),
                    if (employee.team != null)
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.groups_rounded,
                                size: 14, color: colors.textSecondary),
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                employee.team!.name,
                                style: AppTextStyles.caption
                                    .copyWith(color: colors.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (!employee.isActive) ...[
                  const SizedBox(height: AppDimens.grid),
                  Text(
                    'Account deactivated',
                    style: AppTextStyles.caption.copyWith(color: scheme.error),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final live = employee.live;
    final status = employee.status;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardLabel(icon: Icons.sensors_rounded, label: 'Live status'),
          const SizedBox(height: AppDimens.grid * 1.5),
          Row(
            children: [
              StatusBadge(status: status),
              const Spacer(),
              if (live?.lastSeen != null)
                Flexible(
                  child: Text(
                    'Seen ${_relativeTime(live!.lastSeen!)}',
                    style: AppTextStyles.caption
                        .copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppDimens.grid * 1.5),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.fingerprint_rounded,
                  label: 'Attendance',
                  value: live?.currentState.label ?? 'Unknown',
                ),
              ),
              if (live?.batteryLevel != null)
                Expanded(
                  child: _MiniStat(
                    icon: live!.batteryLevel! <= 15
                        ? Icons.battery_alert_rounded
                        : Icons.battery_full_rounded,
                    label: 'Battery',
                    value: '${live.batteryLevel}%',
                  ),
                ),
            ],
          ),
          if (live?.isMockGps ?? false) ...[
            const SizedBox(height: AppDimens.grid * 1.5),
            Container(
              padding: const EdgeInsets.all(AppDimens.grid * 1.5),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .error
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: AppDimens.grid),
                  Expanded(
                    child: Text(
                      'Mock GPS detected on this device',
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).colorScheme.error),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardLabel(icon: Icons.contact_page_rounded, label: 'Contact'),
          const SizedBox(height: AppDimens.grid * 1.5),
          _InfoRow(icon: Icons.email_rounded, value: employee.email),
          if (employee.phone != null && employee.phone!.isNotEmpty) ...[
            const SizedBox(height: AppDimens.grid),
            _InfoRow(icon: Icons.phone_rounded, value: employee.phone!),
          ],
        ],
      ),
    );
  }
}

/// Today's attendance. Per-event START/BREAK/RESUME/END sessions arrive with
/// the attendance phase's endpoint; until then this renders today's rollup
/// from the monthly summary plus the current live phase as the timeline head.
class _TodayAttendanceCard extends ConsumerWidget {
  const _TodayAttendanceCard({required this.employeeId, required this.live});
  final int employeeId;
  final LiveStatus? live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final summary = ref.watch(attendanceSummaryProvider(employeeId));
    final now = DateTime.now();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardLabel(
              icon: Icons.today_rounded, label: "Today's attendance"),
          const SizedBox(height: AppDimens.grid * 1.5),
          summary.when(
            loading: () => const _InlineLoader(),
            error: (e, _) => Text(
              'Could not load attendance',
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary),
            ),
            data: (s) {
              AttendanceDay? today;
              for (final d in s.days) {
                if (d.date.year == now.year &&
                    d.date.month == now.month &&
                    d.date.day == now.day) {
                  today = d;
                  break;
                }
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PhaseTimeline(
                    phase: live?.currentState ?? AttendancePhase.none,
                    since: live?.lastSeen,
                  ),
                  const SizedBox(height: AppDimens.grid * 1.5),
                  Row(
                    children: [
                      Expanded(
                        child: _MiniStat(
                          icon: Icons.timelapse_rounded,
                          label: 'Worked',
                          value: _fmtMinutes(today?.durationMinutes ?? 0),
                        ),
                      ),
                      Expanded(
                        child: _MiniStat(
                          icon: Icons.directions_walk_rounded,
                          label: 'Distance',
                          value: _fmtDistance(today?.distanceMeters ?? 0),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Vertical phase timeline of the attendance state machine. The reached phase
/// is highlighted; later phases are dimmed.
class _PhaseTimeline extends StatelessWidget {
  const _PhaseTimeline({required this.phase, this.since});
  final AttendancePhase phase;
  final DateTime? since;

  static const _order = [
    (AttendancePhase.started, 'Started', Icons.play_circle_fill_rounded),
    (AttendancePhase.onBreak, 'On break', Icons.pause_circle_filled_rounded),
    (AttendancePhase.ended, 'Ended', Icons.stop_circle_rounded),
  ];

  int get _reachedIndex => switch (phase) {
        AttendancePhase.none => -1,
        AttendancePhase.started => 0,
        AttendancePhase.onBreak => 1,
        AttendancePhase.ended => 2,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    if (phase == AttendancePhase.none) {
      return Row(
        children: [
          Icon(Icons.radio_button_unchecked_rounded,
              size: 18, color: colors.textSecondary),
          const SizedBox(width: AppDimens.grid),
          Text('Not started today',
              style: AppTextStyles.body.copyWith(color: colors.textSecondary)),
        ],
      );
    }

    return Column(
      children: [
        for (var i = 0; i < _order.length; i++)
          _PhaseRow(
            label: _order[i].$2,
            icon: _order[i].$3,
            reached: i <= _reachedIndex,
            current: i == _reachedIndex,
            isLast: i == _order.length - 1,
            time: i == _reachedIndex && since != null ? _hhmm(since!) : null,
            activeColor: scheme.primary,
            dimColor: colors.textSecondary,
          ),
      ],
    );
  }
}

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({
    required this.label,
    required this.icon,
    required this.reached,
    required this.current,
    required this.isLast,
    required this.activeColor,
    required this.dimColor,
    this.time,
  });

  final String label;
  final IconData icon;
  final bool reached;
  final bool current;
  final bool isLast;
  final Color activeColor;
  final Color dimColor;
  final String? time;

  @override
  Widget build(BuildContext context) {
    final color = reached ? activeColor : dimColor.withValues(alpha: 0.5);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Icon(icon, size: 18, color: color),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: reached
                        ? activeColor.withValues(alpha: 0.4)
                        : dimColor.withValues(alpha: 0.2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Padding(
              padding:
                  EdgeInsets.only(bottom: isLast ? 0 : AppDimens.grid * 1.5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: reached
                            ? Theme.of(context).colorScheme.onSurface
                            : dimColor,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (time != null)
                    Text(
                      time!,
                      style: AppTextStyles.caption.copyWith(color: dimColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationCard extends ConsumerWidget {
  const _LocationCard({required this.employeeId});
  final int employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final loc = ref.watch(lastLocationProvider(employeeId));

    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        child: SizedBox(
          height: 200,
          width: double.infinity,
          child: loc.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
            error: (_, __) =>
                _mapPlaceholder(context, colors, 'Location unavailable'),
            data: (point) {
              if (point == null) {
                return _mapPlaceholder(context, colors, 'No recent location');
              }
              final center = LatLng(point.lat, point.lng);
              return Stack(
                children: [
                  FlutterMap(
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: 15,
                      interactionOptions: const InteractionOptions(
                        flags:
                            InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.fieldtrack.mobile',
                        maxZoom: 19,
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: center,
                            width: 40,
                            height: 40,
                            child: Icon(
                              Icons.location_on_rounded,
                              size: 40,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    left: AppDimens.grid,
                    bottom: AppDimens.grid,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.grid,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.card.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Last known • ${_hhmm(point.timestamp)}',
                        style: AppTextStyles.caption
                            .copyWith(color: colors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _mapPlaceholder(BuildContext context, dynamic colors, String label) {
    return Container(
      color: colors.textSecondary.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.map_rounded, size: 36, color: colors.textSecondary),
          const SizedBox(height: AppDimens.grid),
          Text(label,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

// ── Small shared bits ────────────────────────────────────────────────────
class _CardLabel extends StatelessWidget {
  const _CardLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Row(
      children: [
        Icon(icon, size: 16, color: colors.textSecondary),
        const SizedBox(width: AppDimens.grid),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.value});
  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.textSecondary),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
          child: Text(
            value,
            style: AppTextStyles.body
                .copyWith(color: Theme.of(context).colorScheme.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.textSecondary),
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

class _InlineLoader extends StatelessWidget {
  const _InlineLoader();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
}

// ── Formatting helpers ───────────────────────────────────────────────────
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

String _hhmm(DateTime dt) {
  final l = dt.toLocal();
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
