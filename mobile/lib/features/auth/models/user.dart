import '../../../core/config/env.dart';

enum UserRole {
  admin('ADMIN'),
  supervisor('SUPERVISOR'),
  employee('EMPLOYEE');

  const UserRole(this.wire);
  final String wire;

  static UserRole fromWire(String value) => UserRole.values.firstWhere(
        (r) => r.wire == value,
        orElse: () => UserRole.employee,
      );

  String get label => switch (this) {
        UserRole.admin => 'Admin',
        UserRole.supervisor => 'Supervisor',
        UserRole.employee => 'Employee',
      };
}

class User {
  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.phone,
    this.teamId,
    this.profilePhotoUrl,
    this.village,
    this.district,
    this.state,
  });

  final int id;
  final String name;
  final String email;
  final UserRole role;
  final String? phone;
  final int? teamId;
  final String? profilePhotoUrl;
  final String? village;
  final String? district;
  final String? state;

  bool get isSupervisor => role == UserRole.supervisor;

  factory User.fromJson(Map<String, dynamic> json) {
    final photoUrl = json['profile_photo_url'] as String?;
    return User(
      id: json['id'] as int,
      name: json['name'] as String,
      email: json['email'] as String,
      role: UserRole.fromWire(json['role'] as String),
      phone: json['phone'] as String?,
      teamId: json['team_id'] as int?,
      profilePhotoUrl: (photoUrl != null && photoUrl.startsWith('/'))
          ? '${Env.apiOrigin}$photoUrl'
          : photoUrl,
      village: json['village'] as String?,
      district: json['district'] as String?,
      state: json['state'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role.wire,
        'phone': phone,
        'team_id': teamId,
        'profile_photo_url': profilePhotoUrl,
        'village': village,
        'district': district,
        'state': state,
      };
}
