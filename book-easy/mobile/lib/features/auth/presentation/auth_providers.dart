import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/errors/failures.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';

// ---- Infrastructure -------------------------------------------------------

final firebaseAuthProvider =
    Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);
final firestoreProvider =
    Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);
final googleSignInProvider = Provider<GoogleSignIn>((ref) => GoogleSignIn());

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return FirebaseAuthRepository(
    auth: ref.watch(firebaseAuthProvider),
    firestore: ref.watch(firestoreProvider),
    googleSignIn: ref.watch(googleSignInProvider),
  );
});

// ---- Auth state ------------------------------------------------------------

/// The signed-in user profile, or null while signed out.
final authStateProvider = StreamProvider<AppUser?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges();
});

final currentUserProvider = Provider<AppUser?>((ref) {
  return ref.watch(authStateProvider).valueOrNull;
});

final isAdminProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider)?.isAdmin ?? false;
});

// ---- Sign-in controller ----------------------------------------------------

/// Drives the sign-in/register form: exposes an [AsyncValue] so the UI can
/// show progress and inline error messages without try/catch in widgets.
class SignInController extends StateNotifier<AsyncValue<void>> {
  SignInController(this._repository) : super(const AsyncValue.data(null));

  final AuthRepository _repository;

  Future<bool> signInWithEmail(String email, String password) =>
      _run(() => _repository.signInWithEmail(email, password));

  Future<bool> registerWithEmail({
    required String name,
    required String email,
    required String password,
  }) =>
      _run(() => _repository.registerWithEmail(
          name: name, email: email, password: password));

  Future<bool> signInWithGoogle() => _run(_repository.signInWithGoogle);

  /// Runs an auth operation, mapping failures into state.
  /// Returns true on success so the widget can decide what to do next.
  Future<bool> _run(Future<AppUser> Function() action) async {
    state = const AsyncValue.loading();
    try {
      await action();
      state = const AsyncValue.data(null);
      return true;
    } on Failure catch (failure) {
      state = AsyncValue.error(failure, StackTrace.current);
      return false;
    } catch (_, stack) {
      state = AsyncValue.error(const UnexpectedFailure(), stack);
      return false;
    }
  }
}

final signInControllerProvider =
    StateNotifierProvider.autoDispose<SignInController, AsyncValue<void>>(
        (ref) {
  return SignInController(ref.watch(authRepositoryProvider));
});
