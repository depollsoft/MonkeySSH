/// Validates the trimmed SSH key name.
String? validateSshKeyName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) {
    return 'Please enter a name';
  }
  if (name.length > 255) {
    return 'Name must be 255 characters or fewer';
  }
  return null;
}

/// Validates the private key PEM envelope.
String? validateSshPrivateKeyPem(String? value) {
  if (value == null || value.isEmpty) {
    return 'Please enter the private key';
  }
  if (!value.contains('-----BEGIN') || !value.contains('-----END')) {
    return 'Invalid PEM format';
  }
  return null;
}
