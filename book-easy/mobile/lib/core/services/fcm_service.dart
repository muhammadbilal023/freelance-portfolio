import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:logging/logging.dart';

/// Notification contracts — abstracted so the checkout flow can be tested
/// without Firebase.
///
/// Booking reminders are sent by a Cloud Function (out of scope for this
/// sample) to the `booking-{bookingId}` topic that clients subscribe to
/// after creating a booking.
abstract interface class FcmService {
  Future<void> registerDeviceToken(String uid);
  Future<void> subscribeToBookingReminders(String bookingId);
  Future<void> unsubscribeFromBookingReminders(String bookingId);
}

class FirebaseFcmService implements FcmService {
  FirebaseFcmService(this._firestore);

  final FirebaseFirestore _firestore;
  final Logger _log = Logger('FcmService');

  /// Requests notification permission and stores the device token on the
  /// user's Firestore profile so the backend can target this device.
  @override
  Future<void> registerDeviceToken(String uid) async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        _log.info(
            'Notification permission denied; skipping token registration');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        _log.warning('FCM returned no token');
        return;
      }

      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
      _log.info('FCM token registered for user $uid');
    } catch (error) {
      // Notifications are best-effort: never break sign-in because of FCM.
      _log.warning('FCM token registration failed', error);
    }
  }

  @override
  Future<void> subscribeToBookingReminders(String bookingId) async {
    try {
      await FirebaseMessaging.instance.subscribeToTopic('booking-$bookingId');
    } catch (error) {
      _log.warning('Could not subscribe to reminders for $bookingId', error);
    }
  }

  @override
  Future<void> unsubscribeFromBookingReminders(String bookingId) async {
    try {
      await FirebaseMessaging.instance
          .unsubscribeFromTopic('booking-$bookingId');
    } catch (error) {
      _log.warning(
          'Could not unsubscribe from reminders for $bookingId', error);
    }
  }
}
