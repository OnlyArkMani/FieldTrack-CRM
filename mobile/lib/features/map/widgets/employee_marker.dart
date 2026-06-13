import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_badge.dart';
import '../models/map_models.dart';

/// 40px circular avatar marker with a status-colored ring. Falls back to
/// initials when there's no photo. Pulses (scale) while the member is Active so
/// the eye is drawn to who's moving right now.
class EmployeeMarker extends StatefulWidget {
  const EmployeeMarker({
    super.key,
    required this.member,
    this.diameter = 40,
    this.onTap,
  });

  final TeamLiveMember member;
  final double diameter;
  final VoidCallback? onTap;

  @override
  State<EmployeeMarker> createState() => _EmployeeMarkerState();
}

class _EmployeeMarkerState extends State<EmployeeMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool get _isActive => widget.member.status == LiveStatusValue.active;

  @override
  void initState() {
    super.initState();
    if (_isActive) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant EmployeeMarker old) {
    super.didUpdateWidget(old);
    if (_isActive && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!_isActive && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color _statusColor(BuildContext context) {
    final c = context.appColors;
    return switch (widget.member.status.badge) {
      EmployeeStatus.active => c.statusActive,
      EmployeeStatus.idle => c.statusIdle,
      _ => c.statusOffline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context);
    final d = widget.diameter;
    final photo = widget.member.photoUrl;

    final marker = GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: d,
        height: d,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color, // the ring
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(
          child: Container(
            color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2),
            alignment: Alignment.center,
            child: (photo != null && photo.isNotEmpty)
                ? CachedNetworkImage(
                    imageUrl: photo,
                    width: d,
                    height: d,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _initials(context, d),
                    errorWidget: (_, __, ___) => _initials(context, d),
                  )
                : _initials(context, d),
          ),
        ),
      ),
    );

    if (!_isActive) return marker;
    return ScaleTransition(
      scale: Tween<double>(begin: 1.0, end: 1.12).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
      ),
      child: marker,
    );
  }

  Widget _initials(BuildContext context, double d) => Text(
        widget.member.initials,
        style: AppTextStyles.caption.copyWith(
          color: Theme.of(context).colorScheme.secondary,
          fontWeight: FontWeight.w700,
          fontSize: d * 0.3,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
}
