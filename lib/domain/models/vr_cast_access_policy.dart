import 'package:flutter/foundation.dart';

import '../../utils/constants/vr_cast_constants.dart';

/// Optional 4-digit PIN protection and max concurrent viewer limit for a cast session.
@immutable
class VrCastAccessPolicy {
  VrCastAccessPolicy({
    this.pinCode,
    this.maxViewers = VrCastConstants.defaultMaxViewers,
  }) {
    if (maxViewers < VrCastConstants.minViewers ||
        maxViewers > VrCastConstants.maxViewersLimit) {
      throw ArgumentError.value(
        maxViewers,
        'maxViewers',
        VrCastConstants.errInvalidMaxViewers,
      );
    }
    if (pinCode != null &&
        !RegExp(VrCastConstants.pinCodePattern).hasMatch(pinCode!)) {
      throw ArgumentError.value(
        pinCode,
        'pinCode',
        VrCastConstants.errInvalidPinCode,
      );
    }
  }

  const VrCastAccessPolicy.open({
    this.maxViewers = VrCastConstants.defaultMaxViewers,
  }) : assert(
         maxViewers >= VrCastConstants.minViewers &&
             maxViewers <= VrCastConstants.maxViewersLimit,
       ),
       pinCode = null;

  final String? pinCode;
  final int maxViewers;

  bool get requiresPin => pinCode != null;

  /// Constant-time comparison for the 4-digit PIN when [requiresPin] is true.
  bool verifyPin(String? candidate) {
    if (pinCode == null) return candidate == null;
    if (candidate == null || candidate.length != pinCode!.length) return false;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate.codeUnitAt(i) ^ pinCode!.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// Returns `true` when [currentActiveViewers] is below [maxViewers].
  bool canAcceptViewer(int currentActiveViewers) =>
      currentActiveViewers >= 0 && currentActiveViewers < maxViewers;

  @override
  bool operator ==(Object other) =>
      other is VrCastAccessPolicy &&
      other.pinCode == pinCode &&
      other.maxViewers == maxViewers;

  @override
  int get hashCode => Object.hash(pinCode, maxViewers);
}
