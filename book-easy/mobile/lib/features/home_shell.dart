import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth/presentation/auth_providers.dart';
import 'bookings/presentation/booking_providers.dart';

/// Authenticated area: bottom navigation across the main tabs.
/// The Admin tab only appears for users with the admin role.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _fcmRegistered = false;

  static const _clientTabs = ['/services', '/bookings', '/profile'];
  static const _adminTabs = ['/services', '/bookings', '/admin', '/profile'];

  @override
  void initState() {
    super.initState();
    // Register the FCM token once per app launch (best-effort, see FcmService).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(currentUserProvider);
      if (user != null && !_fcmRegistered) {
        _fcmRegistered = true;
        ref.read(fcmServiceProvider).registerDeviceToken(user.uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final tabs = isAdmin ? _adminTabs : _clientTabs;
    final selectedIndex = tabs.indexOf(widget.location);

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onDestinationSelected: (index) => context.go(tabs[index]),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.spa_outlined), label: 'Services'),
          const NavigationDestination(
              icon: Icon(Icons.event_note_outlined), label: 'Bookings'),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              label: 'Admin',
            ),
          const NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}
