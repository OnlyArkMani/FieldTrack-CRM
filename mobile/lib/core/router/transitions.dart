import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// "Water, not a door": fade + gentle upward slide, easeInOutCubic, 350ms.
/// Every route in the app uses this page — one definition, zero drift.
class WaterPage<T> extends CustomTransitionPage<T> {
  WaterPage({required super.child, super.key, super.name})
      : super(
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04), // subtle rise — fluid, not jarring
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );
}
