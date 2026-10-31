import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logging/logging.dart';

import '../../../core/errors/failures.dart';
import '../domain/service_item.dart';

abstract interface class ServicesRepository {
  /// Services visible to clients (active only), ordered by category then name.
  Stream<List<ServiceItem>> watchActiveServices();

  /// All services including inactive — used by the admin screen.
  Stream<List<ServiceItem>> watchAllServices();

  Future<ServiceItem> getService(String id);

  /// Creates (when [ServiceItem.id] is empty) or updates a service.
  /// Returns the id of the affected document.
  Future<String> saveService(ServiceItem service);
}

class FirestoreServicesRepository implements ServicesRepository {
  FirestoreServicesRepository(this._firestore);

  final FirebaseFirestore _firestore;
  final Logger _log = Logger('ServicesRepository');

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection('services');

  @override
  Stream<List<ServiceItem>> watchActiveServices() {
    return _collection
        .where('isActive', isEqualTo: true)
        .orderBy('category')
        .orderBy('name')
        .snapshots()
        .map(_mapSnapshot);
  }

  @override
  Stream<List<ServiceItem>> watchAllServices() {
    return _collection
        .orderBy('category')
        .orderBy('name')
        .snapshots()
        .map(_mapSnapshot);
  }

  @override
  Future<ServiceItem> getService(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        throw NotFoundFailure('Service "$id" no longer exists.');
      }
      return ServiceItem.fromFirestore(doc.id, doc.data()!);
    } on FirebaseException catch (e) {
      _log.severe('getService failed', e);
      throw const UnexpectedFailure(
          'Could not load the service. Please try again.');
    }
  }

  @override
  Future<String> saveService(ServiceItem service) async {
    try {
      if (service.id.isEmpty) {
        final ref = await _collection.add(service.toFirestore());
        _log.info('Created service ${ref.id}');
        return ref.id;
      }
      await _collection.doc(service.id).update(service.toFirestore());
      _log.info('Updated service ${service.id}');
      return service.id;
    } on FirebaseException catch (e) {
      _log.severe('saveService failed', e);
      throw const UnexpectedFailure(
          'Could not save the service. Please try again.');
    }
  }

  List<ServiceItem> _mapSnapshot(QuerySnapshot<Map<String, dynamic>> snapshot) {
    return snapshot.docs
        .map((doc) => ServiceItem.fromFirestore(doc.id, doc.data()))
        .toList(growable: false);
  }
}
