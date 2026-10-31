import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../../../core/utils/validators.dart';
import 'auth_providers.dart';

/// Email/password sign-in with Google sign-in fallback and a register toggle.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isRegistering = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final controller = ref.read(signInControllerProvider.notifier);
    final success = _isRegistering
        ? await controller.registerWithEmail(
            name: _nameController.text,
            email: _emailController.text,
            password: _passwordController.text,
          )
        : await controller.signInWithEmail(
            _emailController.text,
            _passwordController.text,
          );
    // On success the router redirect navigates automatically.
    if (success && mounted) _formKey.currentState?.reset();
  }

  Future<void> _signInWithGoogle() async {
    final success =
        await ref.read(signInControllerProvider.notifier).signInWithGoogle();
    if (!success && mounted) {
      final error = ref.read(signInControllerProvider).error;
      // User-cancelled Google flows are not worth a banner.
      if (error is! CancelledFailure) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(error is Failure ? error.message : 'Sign-in failed')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final signInState = ref.watch(signInControllerProvider);
    final isBusy = signInState.isLoading;
    final formError = signInState.error;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.event_available,
                      size: 72,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'BookEasy',
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                    Text(
                      'Book services in seconds',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 32),
                    if (_isRegistering) ...[
                      TextFormField(
                        controller: _nameController,
                        decoration:
                            const InputDecoration(labelText: 'Full name'),
                        textInputAction: TextInputAction.next,
                        validator: Validators.displayName,
                        enabled: !isBusy,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: Validators.email,
                      enabled: !isBusy,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      validator: Validators.password,
                      enabled: !isBusy,
                      onFieldSubmitted: (_) => isBusy ? null : _submit(),
                    ),
                    if (formError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        formError is Failure
                            ? formError.message
                            : 'Sign-in failed',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: isBusy ? null : _submit,
                      child: isBusy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isRegistering ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : _signInWithGoogle,
                      icon: const Icon(Icons.g_mobiledata),
                      label: const Text('Continue with Google'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: isBusy
                          ? null
                          : () =>
                              setState(() => _isRegistering = !_isRegistering),
                      child: Text(
                        _isRegistering
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
