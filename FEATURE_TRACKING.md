# Feature tracking — CRM enhancements

Tracks 4 requested changes, implemented one at a time. Update the checkbox and
"Status" line as each lands.

## 1. Add DISTRIBUTOR customer type
Add `DISTRIBUTOR` as a 5th value of the `customer_type` discriminator
(alongside FARMER/FPO/VLCC/RETAILER), everywhere that enum is used.

- [x] Backend: `app/models/enums.py` `CustomerType` enum
- [x] Backend: `app/models/crm.py` `Customer.customer_type` SAEnum column
- [x] Backend: alembic migration `0021_customer_type_distributor.py` — `ALTER TYPE customertype ADD VALUE 'DISTRIBUTOR'`
- [x] Backend: `app/schemas/crm.py` `CustomerType` Literal
- [x] Backend: `app/services/farmer_service.py` valid_types / by_type dict
- [x] Backend: `app/api/v1/farmers.py` filter validation + docstrings/messages
- [x] Admin-web: `FarmerDetailPanel.jsx` `CUSTOMER_TYPE_META`
- [x] Admin-web: `FarmersPage.jsx` type filter tabs + import-modal copy
- [x] Admin-web: `LeadPipelinePage.jsx` type filter dropdown
- [x] Mobile: `farmer.dart` `CustomerType` enum (wire value, label, isOrg) — treated as org-type (`isOrg = true`)
- [x] Mobile: `visit_flow_screen.dart` step-2 switch — Distributor routed to the shared org-answers form (same as VLCC)
- [x] Mobile: `customer_type_chip.dart` color switch
- (Admin-web/mobile add/edit-customer dropdowns already iterate all enum values dynamically — no separate change needed)

Status: **done** — run `alembic upgrade head` to apply the migration.

## 2. Order placement restricted to FPO/VLCC/Retailer/Distributor/Farmer
Decision: no restriction exists today in `create_order()` (any customer type
can place an order) — with Distributor added, the 5 allowed types are exactly
all existing types, so this requirement is satisfied implicitly once #1 lands.
No explicit allow-list guard requested.

Status: **satisfied by #1** — no separate code change

## 3. "Target order" field when planning a visit
Executive sets a target order (bags they intend to try to get) on each
planned stop, i.e. on `VisitPlanItem`, not on visit check-in.

- [x] Backend: migration `0022_visit_plan_item_target_order.py` adding `target_order_bags` (nullable int) to `visit_plan_items`
- [x] Backend: `app/models/crm.py` `VisitPlanItem.target_order_bags`
- [x] Backend: `app/schemas/crm.py` `VisitPlanItemCreate` / `PlanItemView` add field
- [x] Backend: `app/services/visit_plan_service.py` pass field through upsert, item views, and `carry_over_item` (rescheduled stops keep their target)
- [x] Admin-web: `VisitPlansPage.jsx` team-plan view shows target if present (read-only, planning happens on mobile)
- [x] Mobile: `add_visit_sheet.dart` — target-bags input when adding a stop; `plan_item_card.dart` / `visit_plan.dart` — display + wire model

Status: **done** — run `alembic upgrade head` to apply the migration.

## 4. Leave for a future date (with reschedule gate)
Extend leave beyond "only today" to any date (today or future). If the
target date already has PLANNED visit-plan items, the leave request is
rejected until the employee reschedules/skips them (reusing the existing
`carry_over_item` mechanism, which already supports rescheduling to any
target date — no new bulk-reschedule logic needed per user decision).

- [x] Backend: `app/schemas/attendance.py` `LeaveRequest` body with optional `date` (default: today)
- [x] Backend: `app/services/attendance_service.py` `mark_leave(leave_date=...)` — rejects a past date; rejects a date with PLANNED `visit_plan_items` remaining (409 listing farmer names, via new `VisitPlanRepository.planned_farmer_names_for_date`); otherwise same UNIQUE(user_id,date) check as before
- [x] Backend: `app/api/v1/attendance.py` `/leave` route accepts the new optional body
- [x] Backend: confirmed `carry_over_item` needs no change — already accepts an arbitrary future `target_date`
- [x] Mobile: `attendance_status_tile.dart` — date picker (today..+90d) before the confirm dialog; `attendance_provider.dart` / `attendance_repository.dart` — `markLeave(date: ...)` plumbed through, only updates the optimistic "today" state when the picked date IS today. A rejected future-dated request surfaces the backend's pending-visit-list message via the existing error banner.

Status: **done** — no migration needed (no new columns, `date` reuses the existing `attendance.date` column).

## 5. Rename customer_type FARMER → FARMER_MEET
Renamed the `FARMER` value of the `customer_type` enum to `FARMER_MEET`
(wire value and UI label) everywhere it's used — no new type, just a rename.

- [x] Backend: alembic migration `0023_customer_type_farmer_meet.py` — `ALTER TYPE customertype RENAME VALUE 'FARMER' TO 'FARMER_MEET'` (existing rows repoint automatically); drops/re-adds the `customers.customer_type` column default against the new label
- [x] Backend: `app/models/enums.py` `CustomerType.FARMER_MEET`
- [x] Backend: `app/models/crm.py` SAEnum column + default
- [x] Backend: `app/schemas/crm.py` `CustomerType` Literal + all 7 `"FARMER"` field defaults
- [x] Backend: `farmer_service.py`, `farmers.py`, `lead_service.py`, `vet_service.py`, `visit_service.py`, `visit_plan_service.py`, `dsr_service.py`, `daily_reports.py`, `employees.py` comments — every literal/default/validation updated
- [x] Admin-web: `FarmerDetailPanel.jsx` `CUSTOMER_TYPE_META` (label "Farmer Meet"), `FarmersPage.jsx` tabs + import copy, `LeadPipelinePage.jsx` filter dropdown + fallback + badge check, `DailyReportsPage.jsx` chip-suppression check
- [x] Mobile: `farmer.dart` — `CustomerType.farmer`'s wire value → `FARMER_MEET`, label → "Farmer Meet" (the Dart enum member name `farmer` itself is unchanged, so every other call site needed no edit)

Status: **done** — run `alembic upgrade head` to apply the migration. Existing `customer_type = 'FARMER'` rows become `'FARMER_MEET'` automatically; no data backfill needed.
