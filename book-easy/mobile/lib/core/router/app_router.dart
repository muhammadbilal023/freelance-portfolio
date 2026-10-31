import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/admin_screen.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/bookings/presentation/booking_detail_screen.dart';
import '../../features/bookings/presentation/booking_flow_screen.dart';
import '../../features/bookings/presentation/bookings_history_screen.dart';
import '../../features/home_shell.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/services/presentation/service_detail_screen.dart';
import '../../features/services/presentation/services_screen.dart';

/// Bridges a Riverpod stream to GoRouter's [Listenable]-based refresh.
class _AuthRefreshNotifier extends ValueNotifier<bool> {
  _AuthRefreshNotifier() : super(false);
  void notify() => value = !value;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefreshNotifier();
  ref.onDispose(refresh.dispose);

  // Snapshot of the latest auth state, read inside `redirect`.
  AsyncValue<AppUser?> authState = ref.read(authStateProvider);
  ref.listen(authStateProvider, (_, next) {
    authState = next;
    refresh.notify();
  });

  return GoRouter(
    initialLocation: '/services',
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,
    redirect: (context, state) {
      // Stay on the splash screen until Firebase answers.
      if (authState.isLoading) {
        return state.matchedLocation == '/splash' ? null : '/splash';
      }

      final user = authState.valueOrNull;
      final onLogin = state.matchedLocation == '/login';

      if (user == null) return onLogin ? null : '/login';
      if (onLogin || state.matchedLocation == '/splash') return '/services';

      // Role guard: only admins may enter the admin area.
      if (!user.isAdmin && state.matchedLocation.startsWith('/admin')) {
        return '/services';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            HomeShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/services',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ServicesScreen(),
            ),
          ),
          GoRoute(
            path: '/bookings',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: BookingsHistoryScreen(),
            ),
          ),
          GoRoute(
            path: '/admin',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: AdminScreen(),
            ),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ProfileScreen(),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/service/:id',
        builder: (context, state) =>
            ServiceDetailScreen(serviceId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/book/:serviceId',
        builder: (context, state) =>
            BookingFlowScreen(serviceId: state.pathParameters['serviceId']!),
      ),
      GoRoute(
        path: '/booking/:id',
        builder: (context, state) =>
            BookingDetailScreen(bookingId: state.pathParameters['id']!),
      ),
    ],
  );
});

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
