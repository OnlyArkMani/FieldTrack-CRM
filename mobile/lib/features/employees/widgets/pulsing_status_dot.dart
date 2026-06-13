import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_badge.dart';

/// A colored status dot. When [status] is `active`, an expanding ring pulses
/// outward (water-ripple feel) to draw the eye to who's live right now.
/// Other statuses render a still dot — no wasted animation.
class PulsingStatusDot extends StatefulWidget {
  const PulsingStatusDot({super.key, required this.status, this.size = 10});

  final EmployeeStatus status;
  final double size;

  @override
  State<PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.status == EmployeeStatus.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PulsingStatusDot old) {
    super.didUpdateWidget(old);
    if (widget.status == EmployeeStatus.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.status != EmployeeStatus.active &&
        _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _color(BuildContext context) {
    final c = context.appColors;
    return switch (widget.status) {
      EmployeeStatus.active => c.statusActive,
      EmployeeStatus.idle => c.statusIdle,
      EmployeeStatus.offline => c.statusOffline,
      EmployeeStatus.gpsDisabled => c.statusGpsDisabled,
      EmployeeStatus.lowBattery => c.statusLowBattery,
      EmployeeStatus.noInternet => c.statusOffline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    final isActive = widget.status == EmployeeStatus.active;

    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    if (!isActive) return SizedBox.square(dimension: widget.size, child: dot);

    return SizedBox.square(
      dimension: widget.size * 2.4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_controller.value);
              return Container(
                width: widget.size + (widget.size * 1.4 * t),
                height: widget.size + (widget.size * 1.4 * t),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: (1 - t) * 0.4),
                ),
              );
            },
          ),
          dot,
        ],
      ),
    );
  }
}
