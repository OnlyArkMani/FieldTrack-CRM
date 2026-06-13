import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Shown while AuthNotifier restores the session; router redirects away
/// the moment auth state resolves. The logo "drops" in with a playful
/// overshoot (elastic) while auth restoration happens in the background —
/// by the time the animation settles, redirect is usually ready, so the
/// hand-off to login/home feels continuous rather than a jump-cut.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward();

  late final Animation<double> _logoScale = CurvedAnimation(
    parent: _controller,
    curve: Curves.elasticOut,
  ).drive(Tween(begin: 0.5, end: 1.0));

  late final Animation<double> _logoFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
  );

  late final Animation<double> _taglineFade = CurvedAnimation(
    parent: _controller,
    // Tagline starts ~300ms into the 600ms run.
    curve: const Interval(0.5, 1.0, curve: Curves.easeIn),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // Matches scaffoldBackgroundColor (cream/dark) — no white flash.
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeTransition(
                opacity: _logoFade,
                child: ScaleTransition(
                  scale: _logoScale,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius:
                          BorderRadius.circular(AppDimens.cardRadius * 2),
                      boxShadow: AppDimens.shadow(Theme.of(context).brightness),
                    ),
                    child: Icon(Icons.location_on_rounded,
                        size: 44, color: scheme.onPrimary),
                  ),
                ),
              ),
              const SizedBox(height: AppDimens.grid * 3),
              Text(
                'FieldTrack',
                style: Theme.of(context).textTheme.displaySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppDimens.grid),
              FadeTransition(
                opacity: _taglineFade,
                child: Text(
                  'Know where work happens.',
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
