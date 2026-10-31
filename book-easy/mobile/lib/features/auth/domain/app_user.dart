/// Application user profile, stored in Firestore `users/{uid}`.
class AppUser {
  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    this.photoUrl,
  });

  final String uid;
  final String email;
  final String displayName;
  final UserRole role;
  final String? photoUrl;

  bool get isAdmin => role == UserRole.admin;

  factory AppUser.fromFirestore(String uid, Map<String, dynamic> data) {
    return AppUser(
      uid: uid,
      email: data['email'] as String? ?? '',
      displayName: data['displayName'] as String? ?? '',
      role: UserRole.fromString(data['role'] as String?),
      photoUrl: data['photoUrl'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'email': email,
        'displayName': displayName,
        'role': role.name,
        if (photoUrl != null) 'photoUrl': photoUrl,
      };

  AppUser copyWith({String? displayName, String? photoUrl}) => AppUser(
        uid: uid,
        email: email,
        displayName: displayName ?? this.displayName,
        role: role,
        photoUrl: photoUrl ?? this.photoUrl,
      );
}

enum UserRole {
  client,
  admin;

  static UserRole fromString(String? value) => UserRole.values
      .firstWhere((r) => r.name == value, orElse: () => UserRole.client);
}
