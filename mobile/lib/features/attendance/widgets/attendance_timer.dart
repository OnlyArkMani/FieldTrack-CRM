import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Live HH:MM:SS counter ticking up from [start]. The color drifts amber →
/// coral across the working day (0 → [fullDayHours]) as a gentle "you've been
/// at this a while" cue. Timer is cancelled on dispose; rebuilding with a new
/// [start] resets cleanly.
class AttendanceTimer extends StatefulWidget {
  const AttendanceTimer({
    super.key,
    required this.start,
    this.fullDayHours = 9,
    this.fontSize = 44,
  });

  final DateTime start;
  final double fullDayHours;
  final double fontSize;

  @override
  State<AttendanceTimer> createState() => _AttendanceTimerState();
}

class _AttendanceTimerState extends State<AttendanceTimer> {
  Timer? _timer;
  late Duration _elapsed;

  @override
  void initState() {
    super.initState();
    _elapsed = _compute();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed = _compute());
    });
  }

  @override
  void didUpdateWidget(covariant AttendanceTimer old) {
    super.didUpdateWidget(old);
    if (old.start != widget.start) _elapsed = _compute();
  }

  Duration _compute() {
    final d = DateTime.now().difference(widget.start);
    return d.isNegative ? Duration.zero : d;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Color get _color {
    final hours = _elapsed.inSeconds / 3600;
    final t = (hours / widget.fullDayHours).clamp(0.0, 1.0);
    return Color.lerp(AppPalette.amber, AppPalette.coral, t)!;
  }

  String get _formatted {
    final h = _elapsed.inHours.toString().padLeft(2, '0');
    final m = (_elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _color),
      duration: const Duration(milliseconds: 600),
      builder: (context, color, _) => Text(
        _formatted,
        style: AppTextStyles.display.copyWith(
          color: color,
          fontSize: widget.fontSize,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 1,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Static elapsed display (used for the on-break duration, which counts from
/// the break's start the same way).
class ElapsedLabel extends StatefulWidget {
  const ElapsedLabel({super.key, required this.start, this.style});
  final DateTime start;
  final TextStyle? style;

  @override
  State<ElapsedLabel> createState() => _ElapsedLabelState();
}

class _ElapsedLabelState extends State<ElapsedLabel> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final d = DateTime.now().difference(widget.start);
    if (mounted) setState(() => _elapsed = d.isNegative ? Duration.zero : d);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = (_elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final text = _elapsed.inHours > 0
        ? '${_elapsed.inHours}h ${m}m'
        : '${m}:${s}';
    return Text(text,
        style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
