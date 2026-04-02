import 'package:flutter/material.dart';

/// Custom page route with smooth slide + fade transition.
class SmoothPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SmoothPageRoute({required this.page})
      : super(
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.15, 0),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation),
                child: child,
              ),
            );
          },
        );
}

/// Scale + fade transition for dialogs and overlays.
class ScaleFadeRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  ScaleFadeRoute({required this.page})
      : super(
          opaque: false,
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeIn,
            );
            return ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1.0).animate(curvedAnimation),
              child: FadeTransition(
                opacity: curvedAnimation,
                child: child,
              ),
            );
          },
        );
}

/// Slide-up transition (for bottom sheets / full-screen overlays).
class SlideUpRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SlideUpRoute({required this.page})
      : super(
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: FadeTransition(
                opacity: curvedAnimation,
                child: child,
              ),
            );
          },
        );
}

/// Staggered list item animation wrapper.
/// Wraps a child widget with slide + fade animation, delayed by index.
class StaggeredListItem extends StatelessWidget {
  final int index;
  final Widget child;
  final Duration duration;
  final Duration maxDelay;

  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 350),
    this.maxDelay = const Duration(milliseconds: 400),
  });

  @override
  Widget build(BuildContext context) {
    final delay = Duration(
      milliseconds: (index * 60).clamp(0, maxDelay.inMilliseconds),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (_, value, child) {
        final delayFrac = delay.inMilliseconds / (duration.inMilliseconds + maxDelay.inMilliseconds);
        final adjusted = ((value - delayFrac) / (1.0 - delayFrac)).clamp(0.0, 1.0);
        return Transform.translate(
          offset: Offset(0, 20 * (1.0 - adjusted)),
          child: Opacity(opacity: adjusted, child: child),
        );
      },
      child: child,
    );
  }
}

/// Animated scale-in wrapper (used for buttons, icons, etc.)
class ScaleIn extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;

  const ScaleIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 300),
    this.delay = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration + delay,
      curve: Curves.elasticOut,
      builder: (_, value, child) {
        final delayFrac = delay.inMilliseconds / (duration + delay).inMilliseconds;
        final adjusted = ((value - delayFrac) / (1.0 - delayFrac)).clamp(0.0, 1.0);
        return Transform.scale(
          scale: adjusted,
          child: Opacity(opacity: adjusted.clamp(0.0, 1.0), child: child),
        );
      },
      child: child,
    );
  }
}
