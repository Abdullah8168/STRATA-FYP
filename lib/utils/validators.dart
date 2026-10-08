class Validators {
  static String? requiredMin(String? value, int min, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    if (value.trim().length < min) {
      return '$fieldName must be at least $min characters';
    }
    return null;
  }

  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required';
    }
    final emailReg = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailReg.hasMatch(value.trim())) {
      return 'Enter a valid email address';
    }
    return null;
  }

  static String? phone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Phone number is required';
    }
    final digitsOnly = RegExp(r'^[0-9]+$');
    final trimmed = value.trim();
    if (!digitsOnly.hasMatch(trimmed)) {
      return 'Phone number must contain digits only';
    }
    if (trimmed.length < 10) {
      return 'Phone number is too short';
    }
    return null;
  }

  static String? date(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Date of birth is required';
    }
    try {
      DateTime.parse(value.trim());
    } catch (_) {
      return 'Enter date as YYYY-MM-DD';
    }
    return null;
  }
}

