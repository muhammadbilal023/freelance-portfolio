import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:logging/logging.dart';

import '../../../core/errors/failures.dart';
import '../domain/app_user.dart';

/// Contract consumed by providers — allows faking in tests without Firebase.
abstract interface class AuthRepository {
  /// Emits the signed-in profile, or null when signed out.
  Stream<AppUser?> authStateChanges();

  Future<AppUser> signInWithEmail(String email, String password);
  Future<AppUser> registerWithEmail({
    required String name,
    required String email,
    required String password,
  });
  Future<AppUser> signInWithGoogle();
  Future<void> signOut();
  Future<void> updateDisplayName(String uid, String displayName);
}

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
    required GoogleSignIn googleSignIn,
  })  : _auth = auth,
        _firestore = firestore,
        _googleSignIn = googleSignIn;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final GoogleSignIn _googleSignIn;
  final Logger _log = Logger('AuthRepository');

  @override
  Stream<AppUser?> authStateChanges() {
    return _auth.authStateChanges().asyncMap((firebaseUser) async {
      if (firebaseUser == null) return null;
      return _loadOrCreateProfile(firebaseUser);
    });
  }

  @override
  Future<AppUser> signInWithEmail(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return _loadOrCreateProfile(credential.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyAuthMessage(e));
    }
  }

  @override
  Future<AppUser> registerWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user!;
      await user.updateDisplayName(name.trim());

      final appUser = AppUser(
        uid: user.uid,
        email: user.email ?? email.trim(),
        displayName: name.trim(),
        role: UserRole.client,
      );
      await _firestore
          .collection('users')
          .doc(user.uid)
          .set(appUser.toFirestore());
      _log.info('Registered new user ${user.uid}');
      return appUser;
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyAuthMessage(e));
    }
  }

  @override
  Future<AppUser> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        throw const CancelledFailure('Google sign-in was cancelled');
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential = await _auth.signInWithCredential(credential);
      return _loadOrCreateProfile(userCredential.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyAuthMessage(e));
    }
  }

  @override
  Future<void> signOut() async {
    await Future.wait([_auth.signOut(), _googleSignIn.signOut()]);
  }

  @override
  Future<void> updateDisplayName(String uid, String displayName) async {
    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .update({'displayName': displayName.trim()});
      await _auth.currentUser?.updateDisplayName(displayName.trim());
    } on FirebaseException catch (e) {
      _log.warning('Failed to update display name', e);
      throw const UnexpectedFailure(
          'Could not save your name. Please try again.');
    }
  }

  /// Ensures a Firestore profile exists for the Firebase user and maps it.
  Future<AppUser> _loadOrCreateProfile(User firebaseUser) async {
    final docRef = _firestore.collection('users').doc(firebaseUser.uid);
    final doc = await docRef.get();

    if (!doc.exists) {
      final appUser = AppUser(
        uid: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        displayName: firebaseUser.displayName ?? 'Guest',
        role: UserRole.client,
        photoUrl: firebaseUser.photoURL,
      );
      await docRef.set(appUser.toFirestore());
      return appUser;
    }
    return AppUser.fromFirestore(firebaseUser.uid, doc.data() ?? const {});
  }

  String _friendlyAuthMessage(FirebaseAuthException e) {
    _log.warning('Firebase auth error: ${e.code}');
    return switch (e.code) {
      'invalid-email' => 'That email address looks wrong.',
      'user-disabled' => 'This account has been disabled.',
      'user-not-found' ||
      'wrong-password' ||
      'invalid-credential' =>
        'Incorrect email or password.',
      'email-already-in-use' => 'An account with this email already exists.',
      'weak-password' => 'Please choose a stronger password (8+ characters).',
      'too-many-requests' => 'Too many attempts. Please try again later.',
      'network-request-failed' => 'Network error. Check your connection.',
      _ => 'Authentication failed. Please try again.',
    };
  }
}
