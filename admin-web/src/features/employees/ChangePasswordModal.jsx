import { useEffect, useState } from "react";
import { Eye, EyeOff, KeyRound } from "lucide-react";
import Modal from "@/components/ui/Modal";
import Button from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import Avatar from "@/components/ui/Avatar";
import { apiErrorMessage } from "@/services/api/client";
import { useUpdateEmployeePassword } from "@/hooks/useEmployees";

export default function ChangePasswordModal({ open, onClose, employee }) {
  const updatePassword = useUpdateEmployeePassword(employee?.id);

  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState(null);
  const [successMsg, setSuccessMsg] = useState(null);

  useEffect(() => {
    if (open) {
      setNewPassword("");
      setConfirmPassword("");
      setShowPassword(false);
      setError(null);
      setSuccessMsg(null);
    }
  }, [open, employee]);

  if (!employee) return null;

  const passwordsMatch = newPassword === confirmPassword;
  const isValid = newPassword.length >= 8 && passwordsMatch;

  const handleSubmit = async (e) => {
    if (e) e.preventDefault();
    if (!isValid) return;

    setError(null);
    setSuccessMsg(null);

    try {
      await updatePassword.mutateAsync(newPassword);
      setSuccessMsg("Password updated successfully!");
      setTimeout(() => {
        onClose();
      }, 1200);
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Change Password"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={updatePassword.isPending}>
            Cancel
          </Button>
          <Button
            onClick={handleSubmit}
            loading={updatePassword.isPending}
            disabled={!isValid || updatePassword.isPending}
          >
            Update password
          </Button>
        </>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* User Context Banner */}
        <div className="flex items-center gap-3 p-3 rounded-lg bg-surface border border-border/60">
          <Avatar name={employee.name} src={employee.profile_photo_url} size={40} />
          <div className="min-w-0">
            <h4 className="font-medium text-sm text-text-primary truncate">
              {employee.name}
            </h4>
            <p className="text-xs text-text-secondary truncate">
              {employee.email}
            </p>
          </div>
        </div>

        {error && (
          <div className="p-3 text-xs rounded border border-status-danger/30 bg-status-danger/10 text-status-danger">
            {error}
          </div>
        )}

        {successMsg && (
          <div className="p-3 text-xs rounded border border-status-active/30 bg-status-active/10 text-status-active">
            {successMsg}
          </div>
        )}

        <div className="space-y-3">
          <div className="relative">
            <Input
              label="New Password"
              type={showPassword ? "text" : "password"}
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              placeholder="Minimum 8 characters"
              autoComplete="new-password"
            />
            <button
              type="button"
              onClick={() => setShowPassword(!showPassword)}
              className="absolute right-3 top-[34px] text-text-secondary hover:text-text-primary transition-colors"
              title={showPassword ? "Hide password" : "Show password"}
            >
              {showPassword ? (
                <EyeOff className="h-4 w-4" />
              ) : (
                <Eye className="h-4 w-4" />
              )}
            </button>
          </div>

          <Input
            label="Confirm New Password"
            type={showPassword ? "text" : "password"}
            value={confirmPassword}
            onChange={(e) => setConfirmPassword(e.target.value)}
            placeholder="Re-enter new password"
            autoComplete="new-password"
            error={
              confirmPassword.length > 0 && !passwordsMatch
                ? "Passwords do not match"
                : undefined
            }
          />
        </div>

        <p className="text-xs text-text-secondary flex items-center gap-1.5 pt-1">
          <KeyRound className="h-3.5 w-3.5 text-primary shrink-0" />
          Updating password will log the employee out of all current sessions.
        </p>
      </form>
    </Modal>
  );
}
