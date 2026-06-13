import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../providers/auth_provider.dart';

/// Login. Entrance: logo scales in from center, form slides up with fade,
/// 600ms total. Router handles navigation on success (auth redirect).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  late final AnimationController _entrance;
  late final Animation<double> _logoScale;
  late final Animation<double> _formFade;
  late final Animation<Offset> _formSlide;

  bool _obscurePassword = true;
  String? _emailError;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // Logo first (0 -> 0.6), form follows (0.3 -> 1.0) — overlapping, fluid.
    _logoScale = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
    );
    final formCurve = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.3, 1.0, curve: Curves.easeInOutCubic),
    );
    _formFade = formCurve;
    _formSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(formCurve);

    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _validate() {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    setState(() {
      _emailError = email.isEmpty || !email.contains('@')
          ? 'Enter a valid email address'
          : null;
      _passwordError =
          password.length < 8 ? 'Password must be at least 8 characters' : null;
    });
    return _emailError == null && _passwordError == null;
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    ref
        .read(authProvider.notifier)
        .login(_emailController.text, _passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        // Tap anywhere outside fields to dismiss the keyboard.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: ListView(
            // ListView (not Column-in-SingleChildScrollView): keyboard insets
            // handled for free, lazy build, no overflow ever.
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.grid * 3,
            ),
            children: [
              SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.10),

              // ── Logo: scales in from center ──────────────────────────
              ScaleTransition(
                scale: _logoScale,
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius:
                            BorderRadius.circular(AppDimens.cardRadius * 2),
                        boxShadow:
                            AppDimens.shadow(Theme.of(context).brightness),
                      ),
                      child: Icon(Icons.location_on_rounded,
                          size: 44, color: scheme.onPrimary),
                    ),
                    const SizedBox(height: AppDimens.grid * 2),
                    Text(
                      'FieldTrack',
                      style: Theme.of(context).textTheme.displaySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppDimens.grid * 0.5),
                    Text(
                      'Track work. Not paperwork.',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              SizedBox(height: MediaQuery.sizeOf(context).height * 0.06),

              // ── Form: slides up + fades in ───────────────────────────
              FadeTransition(
                opacity: _formFade,
                child: SlideTransition(
                  position: _formSlide,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppTextField(
                        label: 'Email',
                        controller: _emailController,
                        hint: 'you@company.com',
                        errorText: _emailError,
                        prefixIcon: Icons.mail_outline_rounded,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        enabled: !auth.isLoading,
                      ),
                      const SizedBox(height: AppDimens.grid * 2),
                      AppTextField(
                        label: 'Password',
                        controller: _passwordController,
                        hint: 'Your password',
                        errorText: _passwordError,
                        obscureText: _obscurePassword,
                        prefixIcon: Icons.lock_outline_rounded,
                        suffixIcon: _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        onSuffixTap: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        autofillHints: const [AutofillHints.password],
                        enabled: !auth.isLoading,
                      ),

                      // ── Server error (AnimatedContainer per UI rules) ──
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOutCubic,
                        height: auth.error != null ? null : 0,
                        margin: EdgeInsets.only(
                            top: auth.error != null ? AppDimens.grid * 2 : 0),
                        padding: auth.error != null
                            ? const EdgeInsets.all(AppDimens.grid * 1.5)
                            : EdgeInsets.zero,
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: 0.12),
                          borderRadius:
                              BorderRadius.circular(AppDimens.buttonRadius),
                        ),
                        child: auth.error != null
                            ? Row(
                                children: [
                                  Icon(Icons.error_outline_rounded,
                                      size: 18, color: scheme.error),
                                  const SizedBox(width: AppDimens.grid),
                                  Expanded(
                                    child: Text(
                                      auth.error!,
                                      style: AppTextStyles.caption
                                          .copyWith(color: scheme.error),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),

                      const SizedBox(height: AppDimens.grid * 3),
                      AppButton(
                        label: 'Log In',
                        isLoading: auth.isLoading,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: AppDimens.grid * 2),
                      Center(
                        child: TextButton(
                          onPressed: auth.isLoading
                              ? null
                              : () {
                                  // Forgot-password sheet ships with the
                                  // full auth flow phase.
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Ask your admin to reset your password.',
                                            maxLines: 2,
                                            overflow:
                                                TextOverflow.ellipsis)),
                                  );
                                },
                          child: Text(
                            'Forgot password?',
                            style: AppTextStyles.bodyMedium
                                .copyWith(color: scheme.secondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppDimens.grid * 4),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
