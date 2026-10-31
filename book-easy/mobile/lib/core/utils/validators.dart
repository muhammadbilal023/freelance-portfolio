/// Pure input validators — no Flutter dependency, fully unit-testable.
class Validators {
  const Validators._();

  static final RegExp _emailPattern = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');

  /// Returns an error message or null when valid.
  /// Signatures match `FormFieldValidator<String>` so they can be used as
  /// direct tear-offs in [TextFormField.validator].
  static String? email(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return 'Email is required';
    if (!_emailPattern.hasMatch(trimmed)) return 'Enter a valid email address';
    return null;
  }

  static String? password(String? value) {
    final input = value ?? '';
    if (input.isEmpty) return 'Password is required';
    if (input.length < 8) return 'Password must be at least 8 characters';
    return null;
  }

  static String? displayName(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return 'Name is required';
    if (trimmed.length < 2) return 'Name must be at least 2 characters';
    if (trimmed.length > 60) return 'Name must be at most 60 characters';
    return null;
  }

  /// Price as a decimal string (e.g. "45.00") — used in the admin service form.
  static String? price(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return 'Price is required';
    final parsed = double.tryParse(trimmed);
    if (parsed == null) return 'Enter a valid number';
    if (parsed <= 0) return 'Price must be greater than zero';
    if (parsed > 100000) return 'Price is unrealistically high';
    return null;
  }

  /// Duration in minutes as an integer string.
  static String? durationMinutes(String? value) {
    final parsed = int.tryParse((value ?? '').trim());
    if (parsed == null) return 'Enter a whole number';
    if (parsed < 5 || parsed > 480) {
      return 'Duration must be between 5 and 480 minutes';
    }
    if (parsed % 5 != 0) return 'Duration must be a multiple of 5';
    return null;
  }
}
