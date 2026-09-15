import 'models/types.dart';

/// Appends platform-specific guidance to a failure message, where a failure has
/// a common cause the message alone would not reveal.
///
/// Pure and platform-parameterised so it can be unit tested for every platform
/// from a single host.
String describeConnectionFailure({
  required String os,
  required MssqlErrorType type,
  required String message,
}) {
  // iOS 14+ gates connections to local-network addresses behind user consent.
  // An app whose Info.plist lacks NSLocalNetworkUsageDescription, or whose user
  // declined, sees the attempt fail looking like an ordinary timeout. The hint
  // is confined to iOS and to connection failures so it never misleads
  // elsewhere.
  if (os == 'ios' && type == MssqlErrorType.connection) {
    return '$message\n'
        'On iOS, reaching a server on the local network also requires the '
        'NSLocalNetworkUsageDescription key in the app Info.plist and the '
        "user's consent; without either, the attempt fails like a timeout.";
  }
  return message;
}
