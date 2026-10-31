import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/services_repository.dart';
import '../domain/service_item.dart';

final servicesRepositoryProvider = Provider<ServicesRepository>((ref) {
  return FirestoreServicesRepository(ref.watch(firestoreProvider));
});

/// Active services shown to clients on the browse screen.
final activeServicesProvider = StreamProvider<List<ServiceItem>>((ref) {
  return ref.watch(servicesRepositoryProvider).watchActiveServices();
});

/// All services (including inactive) — admin management screen.
final allServicesProvider = StreamProvider<List<ServiceItem>>((ref) {
  return ref.watch(servicesRepositoryProvider).watchAllServices();
});

/// Single service lookup used by the detail/booking screens.
final serviceProvider = FutureProvider.family<ServiceItem, String>((ref, id) {
  return ref.watch(servicesRepositoryProvider).getService(id);
});
