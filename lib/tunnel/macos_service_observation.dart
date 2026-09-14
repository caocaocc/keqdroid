import 'dart:async';
import 'package:flutter/services.dart';

import '../core/exceptions.dart';

class MacOSServiceObservation {
  final Map<String, dynamic> service;
  final Map<String, dynamic> session;
  const MacOSServiceObservation(this.service, this.session);
}

String macOSFailureCode(Object error) {
  if (error is TimeoutException) return 'requestOutcomeUnknown';
  if (error is PlatformException) {
    final details = error.details;
    return details is Map && details['serviceCode'] is String
        ? details['serviceCode'] as String
        : error.code;
  }
  if (error is AppException && error.cause != null) {
    return macOSFailureCode(error.cause!);
  }
  if (error is VpnPermissionDeniedException) return 'authorizationRequired';
  return 'startFailed';
}
