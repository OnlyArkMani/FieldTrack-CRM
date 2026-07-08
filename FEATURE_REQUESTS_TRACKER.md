# Feature Requests Tracker

Source: client request list, 2026-07-08. Status column: `Not started` / `In progress` / `Done`.
Each item below has the current codebase state as found, plus what needs to change.

| #  | Item                                                                    | Status                    |
| -- | ----------------------------------------------------------------------- | ------------------------- |
| 2  | Show leave check-in/check-out in biometric tab and dashboard            | Not started               |
| 3  | "My visits for the day" widget on dashboard                             | Not started               |
| 4  | Product interest as pre-selected badge options                          | Not started               |
| 5  | Remove "total cattle" for Retailers                                     | Not started               |
| 6  | Step 3 (order) only for FPO/Retailers                                   | Not started               |
| 7  | Per-entity-type forms (Retailer / FPO / Farmer)                         | Partially done (visit-flow step 2 for Retailer/FPO; farmer form + add-customer screen still open) |
| 8  | Only "follow-up" option after visit-complete screen                     | Not started               |
| 9  | Employee can't start a visit after checkout, but can still add a farmer | Done (narrowed scope)     |
| 10 | Change app launcher icon to Samarth Agri logo                           | Done (launcher icon only) |
| 11 | Add "Sanjeevni" as a cattle feed brand/type                             | Not started               |
| 12 | Edit profile in the app                                                 | Not started               |

---

## 1. Auto check-in/auto clock-out → manual only for executives

**Current state:**

- No auto *check-in* exists anywhere in the backend or mobile app.
- Auto **clock-out** exists: `app/api/v1/attendance.py:83-108` — `POST /attendance/end` treats a request with `work_summary == None` as mobile's "auto-clock-out-on-logout" (checklist #52) and auto-submits the DSR via `generate_and_submit_dsr` (`app/services/dsr_service.py`). A manual End (has `work_summary`) leaves the DSR in DRAFT.
- State machine lives in `app/services/attendance_service.py` (`AttendanceService.transition_state`), roles in `app/models/enums.py::UserRole` (ADMIN/SUPERVISOR/EMPLOYEE — "executive" = EMPLOYEE colloquially, see comments in `app/core/scheduler.py`, `app/repositories/notification_repository.py`).
- Mobile: `mobile/lib/features/attendance/screens/attendance_screen.dart` — START/BREAK/RESUME/END all manual taps today; need to find the logout call site that fires `/attendance/end` with no summary (not yet located — likely in an auth/session-teardown service).

**What needs to change:** Remove/disable the no-summary auto-clock-out path (or gate it off for EMPLOYEE role) so attendance END always requires the manual work-summary flow. Confirm there's truly no auto check-in path before implementing (client wording implies one may be expected elsewhere, e.g. geofence-triggered) — clarify with client if unclear.

## 2. Leave check-in/check-out in biometric tab + dashboard

**Current state:**

- No "biometric" tab/screen exists in mobile (`grep -rli biometric mobile/lib` → no matches). The closest analog is `mobile/lib/features/attendance/screens/attendance_screen.dart`.
- No "Leave" feature/model exists at all — no leave-request table in `app/models`, no leave enum, no leave API. Only reference to "leave" in the whole app is unrelated (`report_provider.dart`).

**What needs to change:** This is a net-new feature — needs a Leave model/table, API, and either a new "Biometric" tab or repurposing the attendance tab to also surface leave-day check-in/out and reflect it on the dashboard. Needs clarification: is "biometric tab" a rename of the existing Attendance tab, or a distinct new tab?

## 3. "My visits for the day" on dashboard

**Current state:**

- `app/api/v1/visit_plans.py` has plan-for-today logic (`VisitPlanRepository`, `app/repositories/visit_plan_repository.py:263` — plans due in a time window for reminders), and a "caller's plan for today" endpoint exists (`visit_plans.py:116` docstring reference).
- Mobile dashboard: `mobile/lib/features/dashboard/screens/dashboard_screen.dart`, shell at `mobile/lib/features/home/screens/home_shell.dart`. Planning feature already exists at `mobile/lib/features/crm/planning/` — need to check if dashboard currently surfaces it (not yet confirmed by name match; dashboard_screen.dart wasn't read in full).

**What needs to change:** Likely a widget/card added to `dashboard_screen.dart` that calls the existing today's-plan endpoint and lists the day's visit stops with status. Backend endpoint appears to already exist — mostly a mobile UI addition.

## 4. Product interest — pre-selected badge options

**Current state:**

- `VisitNote.product_interest` (`app/models/crm.py:223`) is a free-text `Text` column today — no fixed option list.
- Mobile form: `mobile/lib/features/crm/visits/screens/visit_flow_screen.dart` — uses a plain text field (`_interest` controller, see line ~117) for this, not a badge/chip selector.

**What needs to change:** Define a fixed list of product-interest options (needs the actual product list from the client), change the mobile widget to a chip/badge multi-select (or single-select) UI, keep storing as text (comma-joined) or migrate to a proper list column — decide based on whether multi-select is needed.

## 5. Remove "total cattle" for Retailers

**Current state:**

- `total_cattle` exists in three places: `Customer.total_cattle` (`app/models/crm.py:79`, all customer types including RETAILER), `LivestockProfile.total_cattle` (line 270, farmer-only livestock snapshot), `VisitOrgAnswer.total_cattle` (line 492, shared FPO/VLCC org-answer form).
- Mobile: farmer forms (`farmer_edit_sheet.dart`, `farmer_list_screen.dart`, `farmer_detail_screen.dart`, `visit_flow_screen.dart`) all reference `totalCattle`.
- **Important finding:** the add-farmer form (mobile "add customer" flow) is currently identical for all customer types — no per-type field branching exists yet at all, confirmed while exploring item 7 below. So "Retailer" doesn't yet have its own distinct form to remove the field from.

**What needs to change:** Depends entirely on item 7 (per-entity forms) landing first — once Retailer has its own form, simply omit the total-cattle field from it. If Retailer currently reuses the FPO/VLCC org-answers form (per the `CustomerType` docstring: "Retailer visits reuse the same FPO/VLCC org-answers guided form — no dedicated Retailer fields exist"), this item is really a sub-task of item 7.

## 6. Step 3 (order) only for FPO/Retailers

**Current state:**

- Visit flow (`mobile/lib/features/crm/visits/screens/visit_flow_screen.dart`) is a 4-step guided form (steps 1-4) after check-in (step 0): step 1 = livestock (farmer) or org-answers (FPO/VLCC) — branch already exists ("Farmers get the livestock step; FPO/VLCC get the org-answers step", line ~107). Step numbers for vet requirement, product interest, and order/lead capture follow after.
- `VisitOrder` model exists (`app/models/crm.py:294`) — order capture already wired to visits generically, not entity-type-gated yet in the mobile flow (needs closer read of steps 2-3 to confirm exactly which step is "order").

**What needs to change:** Add a customer_type check so the order-capture step is skipped (or shown only) for FPO/RETAILER, matching the existing pattern already used for the step-1 livestock/org-answers branch.

## 7. Per-entity-type forms (Retailer / FPO / Farmer) — PARTIALLY DONE (2026-07-08)

Scoped down to the **visit-flow step 2 form** only (the guided "Details" step during a field visit) — the add-customer/edit-customer screen is still identical for every type (unchanged, not in scope for this pass). Farmer's livestock step was explicitly left untouched per client direction ("keep farmer as it was") — only Retailer and FPO were changed.

**Backend changes:**
- Migration `alembic/versions/0020_entity_form_fields.py` adds `products_sold` (String 300), `price_min`, `price_max` (Numeric 10,2) to `visit_org_answers`, and `uses_cattle_feed`, `interested_in_new_feed` (Boolean) to `livestock_profiles` (the latter two are unused by any UI yet — added in anticipation of the farmer-form gate the client also asked for earlier in the conversation, but not wired up since the farmer form was told to stay as-is for now).
- `app/models/crm.py` — `VisitOrgAnswer` and `LivestockProfile` gain the new columns.
- `app/schemas/crm.py` — `OrgAnswersUpsert`/`OrgAnswerResponse` gain `products_sold`/`price_min`/`price_max`; `LivestockUpsert`/`LivestockProfileResponse` gain `uses_cattle_feed`/`interested_in_new_feed`.
- `app/services/visit_service.py::upsert_org_answers` persists the three new org-answer fields.

**Mobile changes (`mobile/lib/features/crm/visits/screens/visit_flow_screen.dart`):**
- Step 2 now branches three ways by `CustomerType` instead of just farmer-vs-org: `_livestockStep()` (Farmer, **unchanged**), `_fpoAnswersStep()` (new), `_retailerAnswersStep()` (new), `_orgAnswersStep()` (VLCC, unchanged — still the original 5-question form).
- **Retailer** (`_retailerAnswersStep`): only 3 fields — Number of farmers (`member_count`), Product selling (new `products_sold` text field), Price on you sell — Min/Max (new `price_min`/`price_max`, two separate boxes). Total cattle, current brand, monthly bags, interested-in-supply, and notes are all dropped for this type.
- **FPO** (`_fpoAnswersStep`): Farmers (`member_count`, relabeled), Total cattle (kept as-is), Product selling (new `products_sold`, replaces the old "Current feed brand / procurement" field), Monthly feed requirement (kept as-is), Price on you sell (`current_price_per_bag`, relabeled from "Current price / bag"), Interested-in-supply switch + bags (kept as-is), Notes (kept as-is) — per client instruction to "keep the other as it is."
- `_saveOrgAnswers()` now dispatches to `_saveRetailerAnswers()` / `_saveFpoAnswers()` / the original VLCC save logic based on `_customerType`; the single call site in `_next()` (`if (_isOrg) await _saveOrgAnswers()`) didn't need to change.
- `mobile/lib/features/crm/visits/models/visit.dart` (`OrgAnswers`) and `mobile/lib/features/crm/visits/data/visit_repository.dart` (`saveOrgAnswers`) extended with the three new fields. `mobile/lib/features/crm/farmers/models/farmer.dart` (`LivestockProfile`) extended with `usesCattleFeed`/`interestedInNewFeed` for parity with the backend (not yet surfaced in any farmer-facing UI).
- Verified with `dart analyze` — no issues.

**Still open:**
- The Farmer livestock step (cattle numbers + "using cattle feed?" gate for brand/price + "interested in new feed?" gate for willing-to-pay min/max) was requested earlier in this conversation but explicitly deferred — client said to keep the farmer form as it currently is while we got the Retailer/FPO wording right. Revisit when ready.
- The add-customer/edit-customer screen (as opposed to the visit-flow step) is still one-size-fits-all for every `CustomerType` — out of scope for this pass.
- VLCC form untouched — client never mentioned it, so it keeps the original 5-question form.

## 8. Only "follow-up" option after visit-complete screen

**Current state:**

- `visit_flow_screen.dart::_complete()` (line 378) already requires a lead status (Hot/Warm/Cold) and, for Warm/Cold, a follow-up date/time/purpose — follow-up scheduling is already part of the completion flow, not a separate post-completion screen.
- After completion it shows a success dialog (`_showSuccess`) then navigates to `context.go('/farmer/${widget.farmerId}')` — the farmer detail screen, which presumably has multiple action options.
- `follow_ups` API already exists: `app/api/v1/follow_ups.py` (`GET /my`, `GET /team`, `POST /{id}/acknowledge`, `POST /{id}/complete`).

**What needs to change:** Needs clarification on exactly what "after complete visit screen" refers to — likely the farmer-detail screen's action list after landing there post-completion should be trimmed down to show only "Schedule/View Follow-up" and hide other actions (new visit, edit, etc.). Need to read `farmer_detail_screen.dart` action buttons to scope this precisely.

## 9. Employee can't start a visit after checkout, but can still add a farmer — DONE (narrowed scope, 2026-07-08)

Client narrowed the original broad "read-only after checkout" ask to specifically: block **starting a visit** once checked out, while **adding a farmer** stays fully allowed.

**Found already in place (no change needed):**

- Backend already enforced this exactly: `app/services/visit_service.py:132-139` — `check_in()` calls `AttendanceService.is_active_today(user.id)` (`app/services/attendance_service.py:278-285`, which returns `False` when state is `ENDED` or `NULL`) and raises `attendance_required()` (403, `ATTENDANCE_REQUIRED`) for EMPLOYEE role only — supervisors/admins exempt. `create_farmer` (`app/api/v1/farmers.py:180`, `app/services/farmer_service.py:179`) has no attendance gate at all, so adding a farmer was never blocked.

**Changed:**

- `mobile/lib/features/crm/farmers/screens/farmer_detail_screen.dart` — the "Start Visit" button previously was always tappable and only surfaced the server's rejection after navigating into the check-in screen. Added `_canStartVisit(user, state)` (mirrors the backend's exemption + NULL/ENDED check) using `attendanceProvider`'s `MachineState`, and disabled the button pre-emptively (`onPressed: null`) with a small "Start your attendance to begin a visit" caption when blocked. `_ActionButtons.onStart` is now nullable with an optional `startDisabledReason`.
- Not changed: `mobile/lib/features/crm/planning/screens/visit_plan_screen.dart` also has "Start Visit" entry points (main list + carried-over section) that were left as-is — they still rely on the backend's existing 403 + the inline error message already shown on the check-in screen (`visit_flow_screen.dart` surfaces `ApiException.message` as `_error`). Pre-emptive disabling there would need `_CarryOverSection` converted from `StatelessWidget` to consume Riverpod state; skipped as out of the narrowed scope — functionally the block already works there too, just without the pre-emptive UI treatment.

## 10. Change app launcher icon to Samarth Agri logo — DONE (2026-07-08)

Client supplied the logo directly: `https://samarthagri.com/wp-content/uploads/2026/04/SAMARTH-LOGO-300x207.png` (300×207 PNG, tree mark + "SAMARTH Agri" wordmark, white background).

**Changed:**

- `mobile/assets/images/app_icon.png` — replaced with the Samarth logo, letterboxed onto a 1024×1024 white-background square (aspect ratio preserved, no stretching, ~85% fill).
- `mobile/assets/images/app_icon_foreground.png` — Samarth logo with the white background keyed out to transparent, scaled to ~60% fill to sit inside Android's adaptive-icon safe zone (so it isn't clipped by circular/rounded/squircle launcher masks).
- `mobile/pubspec.yaml` — `adaptive_icon_background` changed from the old FieldTrack orange (`#f5a623`) to `#ffffff`, since the new logo already carries its own green/orange color and a white backdrop reads cleanly (the old orange would clash).
- Regenerated all Android density buckets (`mipmap-*/launcher_icon.png`, `drawable-*/ic_launcher_foreground.png`, `mipmap-anydpi-v26/launcher_icon.xml`, `values/colors.xml`'s `ic_launcher_background`) via `dart run flutter_launcher_icons`. `AndroidManifest.xml` already points at `@mipmap/launcher_icon`, so no manifest change was needed. iOS is `false` in the launcher-icons config (Android-first per this repo, per `CLAUDE.md`) — not touched.
- Verified visually: both the plain launcher icon and the adaptive foreground-on-white render correctly.

**Deliberately NOT changed (flagged, not silently altered):** `mobile/lib/features/splash/splash_screen.dart` still shows a generic pin icon in a colored rounded square plus the "FieldTrack" wordmark and "Know where work happens." tagline — this is a separate in-app splash graphic/copy, not the launcher icon asset, and changing it means touching branding text, not just an image file. Ask the client whether they also want the in-app splash screen (and any app-bar branding) restyled to Samarth, since that's a design decision beyond a straight asset swap.

## 11. Add "Sanjeevni" cattle feed type

**Current state:**

- No fixed brand/feed-type enum exists anywhere — `current_brand` / `current_feed_brand` fields are free-text `String(200)` columns (`app/models/crm.py:80,273,494`), entered via a plain `TextEditingController` (`_brand` in `visit_flow_screen.dart:62`), not a dropdown of presets.
- The one dropdown found in `visit_flow_screen.dart` (`DropdownButton<String>` around line 1129) is for something else (not yet confirmed which field — needs a closer read).

**What needs to change:** If the ask is a preset brand picker (dropdown/chips) with "Sanjeevni" as one option, this depends on first turning the free-text brand field into a selectable list — likely bundled with item 4's badge-selector work. If a preset list doesn't exist by design (free text is intentional per current architecture), simplest fix is: no code change needed, "Sanjeevni" can already be typed in. Needs clarification on which interpretation the client wants.

## 12. Edit profile in the app

**Current state:**

- `mobile/lib/features/profile/screens/profile_screen.dart:139-140` has an "Edit Profile" list item that is a **stub**: `onTap: () {/* edit-profile ships with profile phase */}` — does nothing today.
- Backend: `GET /auth/me` exists (`app/api/v1/auth.py:132`) returning `UserOut`, but there is no self-service update endpoint (PATCH/PUT) for a user's own profile. `PUT /employees/{employee_id}` exists (`app/api/v1/employees.py:87`) but that's the admin/supervisor-facing employee-management endpoint, not a self-edit endpoint, and is likely gated to ADMIN/SUPERVISOR roles.

**What needs to change:** Add a `PATCH /auth/me` (or similar) self-update endpoint (name, phone, maybe photo — confirm which fields are editable vs locked), wire the mobile stub to a new edit-profile form screen calling it.

---

## Open questions for the client (blockers before implementation)

1. **Item 1:** Confirm there's no auto *check-in* anywhere to remove (only auto clock-out-on-logout was found) — or point to where auto check-in happens if it exists elsewhere.
2. **Item 2:** Is "biometric tab" a rename/repurpose of the existing Attendance tab, or a new tab? Also confirms this needs a brand-new Leave feature (model + API + UI) built from scratch.
3. **Item 4 & 11:** What is the fixed list of product-interest / feed-brand options (need the actual list, e.g. does it include "Sanjeevni" plus others)?
4. **Item 5 & 7:** Should Retailer get its own dedicated data model, or continue reusing the FPO/VLCC `VisitOrgAnswer` table with a trimmed field set?
5. **Item 8:** What exactly should remain on the screen after visit-complete — just confirm scope (which screen, which actions removed).
6. **Item 9:** Should the read-only lock apply to all API writes for EMPLOYEE role, or specifically CRM writes (visits/orders/leads/follow-ups)?
7. **Item 10:** Need the actual Samarth-style logo asset file.
