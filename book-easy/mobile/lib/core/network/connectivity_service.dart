import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Emits connectivity changes. Wrapped so features depend on this provider
/// (easy to fake in tests) instead of the plugin directly.
final connectivityStreamProvider =
    StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
});

/// True when the device appears to have network access.
///
/// Defaults to `true` while the first event is still pending — showing a
/// false "offline" banner on a cold start is worse than a brief unknown.
final isOnlineProvider = Provider<bool>((ref) {
  final async = ref.watch(connectivityStreamProvider);
  final results = async.valueOrNull;
  if (results == null) return true;
  return !results.contains(ConnectivityResult.none);
});
