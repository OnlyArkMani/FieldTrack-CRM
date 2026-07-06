/// Order-approval model — mirrors app/schemas/crm.py VisitOrderResponse.
library;

DateTime? _dt(dynamic v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();

double? _d(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

class PendingOrder {
  const PendingOrder({
    required this.id,
    this.farmerId,
    this.farmerName,
    this.employeeId,
    this.employeeName,
    required this.bagsCount,
    this.deliveryDate,
    this.deliveryAddress,
    this.paymentMode,
    this.specialNotes,
    this.pricePerBag,
    this.totalValue,
    this.status = 'SUBMITTED',
    this.rejectionReason,
  });

  final int id;
  final int? farmerId;
  final String? farmerName;
  final int? employeeId;
  final String? employeeName;
  final int bagsCount;
  final DateTime? deliveryDate;
  final String? deliveryAddress;
  final String? paymentMode;
  final String? specialNotes;
  final double? pricePerBag;
  final double? totalValue;
  final String status;
  final String? rejectionReason;

  factory PendingOrder.fromJson(Map<String, dynamic> json) => PendingOrder(
        id: json['id'] as int,
        farmerId: json['farmer_id'] as int?,
        farmerName: json['farmer_name'] as String?,
        employeeId: json['employee_id'] as int?,
        employeeName: json['employee_name'] as String?,
        bagsCount: (json['bags_count'] as int?) ?? 0,
        deliveryDate: _dt(json['delivery_date']),
        deliveryAddress: json['delivery_address'] as String?,
        paymentMode: json['payment_mode'] as String?,
        specialNotes: json['special_notes'] as String?,
        pricePerBag: _d(json['price_per_bag']),
        totalValue: _d(json['total_value']),
        status: (json['status'] as String?) ?? 'SUBMITTED',
        rejectionReason: json['rejection_reason'] as String?,
      );
}
