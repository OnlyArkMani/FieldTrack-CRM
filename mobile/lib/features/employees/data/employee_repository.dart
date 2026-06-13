import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/employee.dart';

final employeeRepositoryProvider = Provider<EmployeeRepository>((ref) {
  return EmployeeRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the employees API. Returns typed models; throws
/// ApiException (the api_client already maps Dio errors) which the providers
/// surface to the UI.
class EmployeeRepository {
  EmployeeRepository(this._api);
  final ApiClient _api;

  Future<EmployeePage> list({
    String? cursor,
    int limit = 20,
    int? teamId,
    String? status,
    String? search,
  }) async {
    final query = <String, dynamic>{'limit': limit};
    if (cursor != null) query['cursor'] = cursor;
    if (teamId != null) query['team_id'] = teamId;
    if (status != null) query['status'] = status;
    if (search != null && search.trim().isNotEmpty) {
      query['search'] = search.trim();
    }
    final data = await _api.get('/employees', query: query);
    return EmployeePage.fromJson(data);
  }

  Future<Employee> detail(int id) async {
    final data = await _api.get('/employees/$id');
    return Employee.fromJson(data);
  }

  Future<Employee> create({
    required String name,
    required String email,
    required String password,
    String? phone,
    String role = 'EMPLOYEE',
    int? teamId,
  }) async {
    final data = await _api.post('/employees', body: {
      'name': name,
      'email': email,
      'password': password,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'role': role,
      if (teamId != null) 'team_id': teamId,
    });
    return Employee.fromJson(data);
  }

  Future<Employee> update(int id, Map<String, dynamic> changes) async {
    final data = await _api.put('/employees/$id', body: changes);
    return Employee.fromJson(data);
  }

  Future<Employee> setStatus(int id, {required bool isActive}) async {
    final data = await _api.patch(
      '/employees/$id/status',
      body: {'is_active': isActive},
    );
    return Employee.fromJson(data);
  }

  Future<AttendanceSummary> attendanceSummary(
    int id, {
    required int year,
    required int month,
  }) async {
    final data = await _api.get(
      '/employees/$id/attendance-summary',
      query: {'year': year, 'month': month},
    );
    return AttendanceSummary.fromJson(data);
  }

  Future<List<LocationPoint>> locationHistory(
    int id, {
    required DateTime from,
    required DateTime to,
    int limit = 1000,
  }) async {
    final data = await _api.get('/employees/$id/location-history', query: {
      'date_from': _ymd(from),
      'date_to': _ymd(to),
      'limit': limit,
    });
    return ((data['points'] as List<dynamic>?) ?? [])
        .map((e) => LocationPoint.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
