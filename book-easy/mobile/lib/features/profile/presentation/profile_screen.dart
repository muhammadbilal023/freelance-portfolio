import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/validators.dart';
import '../../auth/presentation/auth_providers.dart';

/// User profile: display name editing, theme selection and sign-out.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final theme = Theme.of(context);

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: CircleAvatar(
              radius: 44,
              backgroundColor: theme.colorScheme.primaryContainer,
              backgroundImage:
                  user.photoUrl != null ? NetworkImage(user.photoUrl!) : null,
              child: user.photoUrl == null
                  ? Text(
                      user.displayName.isNotEmpty
                          ? user.displayName[0].toUpperCase()
                          : '?',
                      style: theme.textTheme.headlineMedium,
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Center(child: Text(user.email, style: theme.textTheme.bodyMedium)),
          const SizedBox(height: 24),
          TextFormField(
            key: const Key('profile_name_field'),
            initialValue: user.displayName,
            decoration: const InputDecoration(labelText: 'Display name'),
            validator: Validators.displayName,
            onFieldSubmitted: (value) async {
              if (Validators.displayName(value) != null) return;
              // Capture the messenger before the await to keep this callback
              // safe against context-across-async-gaps issues.
              final messenger = ScaffoldMessenger.of(context);
              setState(() => _isSaving = true);
              try {
                await ref
                    .read(authRepositoryProvider)
                    .updateDisplayName(user.uid, value);
                messenger.showSnackBar(
                    const SnackBar(content: Text('Name updated')));
              } finally {
                if (mounted) setState(() => _isSaving = false);
              }
            },
          ),
          const SizedBox(height: 8),
          Text(
            _isSaving ? 'Saving...' : 'Edit your name and tap Enter to save.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 32),
          Text('Appearance', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto)),
              ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode)),
              ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode)),
            ],
            selected: {ref.watch(themeModeProvider)},
            onSelectionChanged: (selection) =>
                ref.read(themeModeProvider.notifier).state = selection.first,
          ),
        ],
      ),
    );
  }
}
