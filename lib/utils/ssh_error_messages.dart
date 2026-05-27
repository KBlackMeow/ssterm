/// Converts a raw SSH exception message into a short, user-readable string.
String friendlyConnectError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('userauth') ||
      s.contains('authentication') ||
      s.contains('permission')) {
    return 'Authentication failed, check password or key';
  }
  if (s.contains('refused')) return 'Connection refused, check IP and port';
  if (s.contains('timeout') || s.contains('timedout')) {
    return 'Connection timed out';
  }
  if (s.contains('hostkey') || s.contains('host key')) {
    return 'Host key verification failed';
  }
  if (s.contains('nodename') || s.contains('socketexception')) {
    return 'Cannot resolve host';
  }
  return e.toString()
      .replaceAll('Exception: ', '')
      .replaceAll('Error: ', '');
}
