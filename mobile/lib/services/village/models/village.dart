/// One row from GET /villages (village lookup / autocomplete).
class Village {
  const Village({
    required this.villageCode,
    required this.villageName,
    this.villageNameLocal,
    this.subdistrictName,
    this.districtName,
    this.stateName,
  });

  final int villageCode;
  final String villageName;
  final String? villageNameLocal;
  final String? subdistrictName;
  final String? districtName;
  final String? stateName;

  factory Village.fromJson(Map<String, dynamic> json) => Village(
        villageCode: (json['village_code'] as num?)?.toInt() ?? 0,
        villageName: json['village_name'] as String? ?? '',
        villageNameLocal: json['village_name_local'] as String?,
        subdistrictName: json['subdistrict_name'] as String?,
        districtName: json['district_name'] as String?,
        stateName: json['state_name'] as String?,
      );

  /// "village, subdistrict, district, state" — parts that are null/blank are
  /// dropped rather than leaving stray/doubled commas.
  String get formattedAddress => [
        villageName,
        subdistrictName,
        districtName,
        stateName,
      ].where((s) => s != null && s.trim().isNotEmpty).join(', ');
}
