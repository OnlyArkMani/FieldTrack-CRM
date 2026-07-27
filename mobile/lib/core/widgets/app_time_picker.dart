import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// Shows a smooth scrolling wheel time picker with 100% infinite looping for
/// Hours (1-12) and Minutes (00-59) in a bottom sheet modal.
Future<TimeOfDay?> showScrollTimePicker(
  BuildContext context, {
  required TimeOfDay initialTime,
}) async {
  int hour12 = initialTime.hourOfPeriod == 0 ? 12 : initialTime.hourOfPeriod;
  int selectedHour12 = hour12; // 1..12
  int selectedMinute = initialTime.minute; // 0..59
  bool isPm = initialTime.period == DayPeriod.pm;

  final hourController =
      FixedExtentScrollController(initialItem: selectedHour12 - 1);
  final minuteController =
      FixedExtentScrollController(initialItem: selectedMinute);
  final periodController = FixedExtentScrollController(initialItem: isPm ? 1 : 0);

  final result = await showModalBottomSheet<TimeOfDay>(
    context: context,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final colors = ctx.appColors;
      final textStyle = AppTextStyles.heading.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
      );

      return SafeArea(
        child: SizedBox(
          height: 280,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text('Cancel',
                          style: AppTextStyles.body
                              .copyWith(color: colors.textSecondary)),
                    ),
                    Text('Select Time',
                        style: AppTextStyles.bodyMedium
                            .copyWith(fontWeight: FontWeight.bold)),
                    TextButton(
                      onPressed: () {
                        int finalHour = selectedHour12 % 12;
                        if (isPm) finalHour += 12;
                        Navigator.of(ctx).pop(
                          TimeOfDay(hour: finalHour, minute: selectedMinute),
                        );
                      },
                      child: Text('Done',
                          style: AppTextStyles.body.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    // Infinite Looping Hours (1..12)
                    Expanded(
                      child: CupertinoPicker(
                        scrollController: hourController,
                        itemExtent: 40,
                        looping: true, // Infinite scroll!
                        onSelectedItemChanged: (index) {
                          selectedHour12 = (index % 12) + 1;
                        },
                        children: List.generate(
                          12,
                          (i) => Center(
                            child: Text(
                              '${i + 1}'.padLeft(2, '0'),
                              style: textStyle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Text(':', style: textStyle),
                    // Infinite Looping Minutes (00..59)
                    Expanded(
                      child: CupertinoPicker(
                        scrollController: minuteController,
                        itemExtent: 40,
                        looping: true, // Infinite scroll!
                        onSelectedItemChanged: (index) {
                          selectedMinute = index % 60;
                        },
                        children: List.generate(
                          60,
                          (i) => Center(
                            child: Text(
                              '$i'.padLeft(2, '0'),
                              style: textStyle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // AM / PM Selector
                    Expanded(
                      child: CupertinoPicker(
                        scrollController: periodController,
                        itemExtent: 40,
                        looping: false,
                        onSelectedItemChanged: (index) {
                          isPm = index == 1;
                        },
                        children: [
                          Center(child: Text('AM', style: textStyle)),
                          Center(child: Text('PM', style: textStyle)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  hourController.dispose();
  minuteController.dispose();
  periodController.dispose();
  return result;
}
