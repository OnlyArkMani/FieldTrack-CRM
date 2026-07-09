import { useEffect, useState } from "react";
import Modal from "@/components/ui/Modal";
import Button from "@/components/ui/Button";
import { Input, Select } from "@/components/ui/Input";
import { apiErrorMessage } from "@/services/api/client";
import { useCreateEmployee, useUpdateEmployee } from "@/hooks/useEmployees";
import { useTeams } from "@/hooks/useTeams";
import { INDIAN_STATES, INDIAN_UNION_TERRITORIES } from "@/lib/indianStates";

const EMPTY = {
  name: "",
  email: "",
  phone: "",
  role: "EMPLOYEE",
  team_id: "",
  village: "",
  district: "",
  state: "",
};

/** Create or edit an employee. Pass `employee` to edit, omit to create.
 * Assigning a manager to a team happens on the Teams page, not here. */
export default function EmployeeFormModal({ open, onClose, employee }) {
  const isEdit = !!employee;
  const { data: teams = [] } = useTeams();
  const create = useCreateEmployee();
  const update = useUpdateEmployee(employee?.id);

  const [form, setForm] = useState(EMPTY);
  const [password, setPassword] = useState("");
  const [error, setError] = useState(null);

  useEffect(() => {
    if (open) {
      setError(null);
      setPassword("");
      setForm(
        employee
          ? {
              name: employee.name || "",
              email: employee.email || "",
              phone: employee.phone || "",
              role: employee.role || "EMPLOYEE",
              team_id: employee.team_id ?? "",
              village: employee.village || "",
              district: employee.district || "",
              state: employee.state || "",
            }
          : EMPTY,
      );
    }
  }, [open, employee]);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  // Phone is digits-only, capped at 10 — strip anything else as it's typed
  // (also blocks paste of formatted numbers) rather than validating after.
  const setPhone = (e) =>
    setForm((f) => ({ ...f, phone: e.target.value.replace(/\D/g, "").slice(0, 10) }));
  const pending = create.isPending || update.isPending;

  const submit = async () => {
    setError(null);
    try {
      const payload = {
        name: form.name.trim(),
        phone: form.phone.trim() || null,
        role: form.role,
        team_id: form.team_id === "" ? null : Number(form.team_id),
        village: form.village.trim() || null,
        district: form.district.trim() || null,
        state: form.state.trim() || null,
      };
      if (isEdit) {
        await update.mutateAsync(payload);
      } else {
        await create.mutateAsync({
          ...payload,
          email: form.email.trim().toLowerCase(),
          password,
        });
      }
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  // Edit allows leaving phone as-is (already saved); create always requires
  // a full 10 digits, matching the backend's E.164-less 10-digit convention.
  const phoneValid = isEdit ? form.phone.length === 0 || form.phone.length === 10 : form.phone.length === 10;

  const valid =
    form.name.trim().length >= 2 &&
    phoneValid &&
    (isEdit ||
      (form.email.includes("@") &&
        password.length >= 8 &&
        form.village.trim().length > 0 &&
        form.district.trim().length > 0 &&
        form.state.trim().length > 0));

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isEdit ? `Edit ${employee.name}` : "New employee"}
      footer={
        <>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} loading={pending} disabled={!valid}>
            {isEdit ? "Save changes" : "Create"}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Input
          label="Full name"
          value={form.name}
          onChange={set("name")}
          placeholder="Full name"
        />
        {!isEdit && (
          <Input
            label="Email"
            type="email"
            value={form.email}
            onChange={set("email")}
            placeholder="name@example.com"
          />
        )}
        <Input
          label="Phone"
          type="tel"
          inputMode="numeric"
          maxLength={10}
          value={form.phone}
          onChange={setPhone}
          placeholder="10-digit phone number"
          error={
            form.phone.length > 0 && form.phone.length < 10
              ? "Enter a 10-digit phone number"
              : undefined
          }
        />
        {!isEdit && (
          <Input
            label="Temporary password"
            type="text"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Min 8 characters"
          />
        )}
        <div className="grid grid-cols-2 gap-4">
          <Select label="Role" value={form.role} onChange={set("role")}>
            <option value="EMPLOYEE">Employee</option>
            <option value="MANAGER">Manager</option>
            <option value="ADMIN">Admin</option>
          </Select>
          <Select label="Team" value={form.team_id} onChange={set("team_id")}>
            <option value="">No team</option>
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="grid grid-cols-3 gap-4">
          <Input
            label="Village / City"
            value={form.village}
            onChange={set("village")}
            placeholder={"Village / City"}
          />
          <Input
            label="District"
            value={form.district}
            onChange={set("district")}
            placeholder={"District"}
          />
          <Select label="State" value={form.state} onChange={set("state")}>
            <option value="">Select state / UT</option>
            <optgroup label="States">
              {INDIAN_STATES.map((s) => (
                <option key={s} value={s}>{s}</option>
              ))}
            </optgroup>
            <optgroup label="Union Territories">
              {INDIAN_UNION_TERRITORIES.map((s) => (
                <option key={s} value={s}>{s}</option>
              ))}
            </optgroup>
          </Select>
        </div>
        {error && <p className="text-sm text-danger">{error}</p>}
      </div>
    </Modal>
  );
}
