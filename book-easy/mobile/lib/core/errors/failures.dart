/// Domain failure types shared across features.
///
/// Repositories translate platform exceptions (Firebase, Stripe, HTTP) into
/// these failures so the UI never has to know about third-party SDKs.
sealed class Failure {
  const Failure(this.message);

  /// Human-readable, user-safe message (never contains stack traces).
  final String message;
}

/// No/failed network connectivity.
class NetworkFailure extends Failure {
  const NetworkFailure(
      [super.message = 'No internet connection. Please try again.']);
}

/// Sign-in/sign-up related problems (wrong password, existing account, ...).
class AuthFailure extends Failure {
  const AuthFailure(super.message);
}

/// A requested resource was not found.
class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message = 'Not found.']);
}

/// The operation was rejected by business rules (slot taken, late cancel...).
class ValidationFailure extends Failure {
  const ValidationFailure(super.message);
}

/// Payment declined, cancelled or provider error.
class PaymentFailure extends Failure {
  const PaymentFailure(super.message);
}

/// The user cancelled the operation themselves — usually not shown as an error.
class CancelledFailure extends Failure {
  const CancelledFailure([super.message = 'Cancelled.']);
}

/// Catch-all for unexpected backend/SDK errors.
class UnexpectedFailure extends Failure {
  const UnexpectedFailure(
      [super.message = 'Something went wrong. Please try again.']);
}
