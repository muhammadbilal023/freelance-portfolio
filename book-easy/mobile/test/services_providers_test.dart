import 'dart:async';

import 'package:book_easy/features/services/data/services_repository.dart';
import 'package:book_easy/features/services/domain/service_item.dart';
import 'package:book_easy/features/services/presentation/services_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeServicesRepository implements ServicesRepository {
  final activeController = StreamController<List<ServiceItem>>.broadcast();
  final allController = StreamController<List<ServiceItem>>.broadcast();
  final saved = <ServiceItem>[];
  ServiceItem? getByIdResult;
  Failure? getByIdError;

  @override
  Stream<List<ServiceItem>> watchActiveServices() => activeController.stream;

  @override
  Stream<List<ServiceItem>> watchAllServices() => allController.stream;

  @override
  Future<ServiceItem> getService(String id) async {
    if (getByIdError != null) throw getByIdError!;
    return getByIdResult!;
  }

  @override
  Future<String> saveService(ServiceItem service) async {
    saved.add(service);
    return service.id.isEmpty ? 'new-id' : service.id;
  }

  Future<void> dispose() async {
    await activeController.close();
    await allController.close();
  }
}

// Re-declared locally to avoid importing core just for the type check below.
typedef Failure = Object;

const haircut = ServiceItem(
  id: 's1',
  name: 'Haircut',
  description: 'Classic cut',
  category: 'Salon',
  durationMinutes: 30,
  priceCents: 4500,
);

void main() {
  late FakeServicesRepository fakeRepository;
  late ProviderContainer container;

  setUp(() {
    fakeRepository = FakeServicesRepository();
    container = ProviderContainer(
      overrides: [servicesRepositoryProvider.overrideWithValue(fakeRepository)],
    );
  });

  tearDown(() async {
    container.dispose();
    await fakeRepository.dispose();
  });

  test('activeServicesProvider emits services pushed by the repository',
      () async {
    final future = container.read(activeServicesProvider.future);
    fakeRepository.activeController.add(const [haircut]);

    expect(await future, [haircut]);
  });

  test('activeServicesProvider surfaces repository errors', () async {
    final future = container.read(activeServicesProvider.future);
    fakeRepository.activeController.addError(StateError('network down'));

    await expectLater(future, throwsA(isA<StateError>()));
  });

  test('serviceProvider family resolves a single service by id', () async {
    fakeRepository.getByIdResult = haircut;

    final result = await container.read(serviceProvider('s1').future);

    expect(result.name, 'Haircut');
    expect(result.priceCents, 4500);
  });

  test('allServicesProvider includes inactive services for admins', () async {
    const inactive = ServiceItem(
      id: 's2',
      name: 'Old perm',
      description: 'Retired',
      category: 'Salon',
      durationMinutes: 60,
      priceCents: 8000,
      isActive: false,
    );
    final future = container.read(allServicesProvider.future);
    fakeRepository.allController.add(const [haircut, inactive]);

    final services = await future;
    expect(services, hasLength(2));
    expect(services.last.isActive, isFalse);
  });
}
