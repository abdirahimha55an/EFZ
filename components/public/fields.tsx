"use client";

/**
 * Accessible fields for the public Contact and Wholesale forms: every control has a real <label htmlFor>, required fields are announced as
 * required, and a validation message is tied to its control (aria-describedby + aria-invalid) and read out when it appears.
 */
import * as React from "react";
import { AlertCircle, CheckCircle2 } from "lucide-react";

import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type FieldShell = {
  id: string;
  label: string;
  required?: boolean;
  error?: string;
  hint?: string;
};

const CONTROL =
  "flex w-full rounded-md border bg-white px-3 py-2 text-sm text-slate-900 focus:outline-none focus:ring-2 focus:ring-brand-green";

function Shell({ id, label, required, error, hint, children }: FieldShell & { children: React.ReactNode }) {
  return (
    <div className="space-y-2">
      <label htmlFor={id} className="block text-sm font-medium text-slate-900">
        {label}
        {required && (
          <>
            <span aria-hidden="true"> *</span>
            <span className="sr-only"> (required)</span>
          </>
        )}
      </label>
      {children}
      {hint && !error && (
        <p id={`${id}-hint`} className="text-xs text-slate-500">
          {hint}
        </p>
      )}
      {error && (
        <p id={`${id}-error`} role="alert" className="text-xs font-medium text-red-600">
          {error}
        </p>
      )}
    </div>
  );
}

const describedBy = (id: string, error?: string, hint?: string) => (error ? `${id}-error` : hint ? `${id}-hint` : undefined);

export function TextField({ id, label, required, error, hint, className, ...props }: FieldShell & Omit<React.InputHTMLAttributes<HTMLInputElement>, "id" | "required">) {
  return (
    <Shell id={id} label={label} required={required} error={error} hint={hint}>
      <Input
        id={id}
        name={id}
        aria-required={required || undefined}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy(id, error, hint)}
        className={cn(error && "border-red-500 focus-visible:ring-red-500", className)}
        {...props}
      />
    </Shell>
  );
}

export function TextAreaField({ id, label, required, error, hint, className, ...props }: FieldShell & Omit<React.TextareaHTMLAttributes<HTMLTextAreaElement>, "id" | "required">) {
  return (
    <Shell id={id} label={label} required={required} error={error} hint={hint}>
      <textarea
        id={id}
        name={id}
        aria-required={required || undefined}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy(id, error, hint)}
        className={cn(CONTROL, "min-h-[120px] border-slate-300", error && "border-red-500 focus:ring-red-500", className)}
        {...props}
      />
    </Shell>
  );
}

export function SelectField({
  id,
  label,
  required,
  error,
  hint,
  className,
  children,
  ...props
}: FieldShell & Omit<React.SelectHTMLAttributes<HTMLSelectElement>, "id" | "required">) {
  return (
    <Shell id={id} label={label} required={required} error={error} hint={hint}>
      <select
        id={id}
        name={id}
        aria-required={required || undefined}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy(id, error, hint)}
        className={cn(CONTROL, "h-10 border-slate-300", error && "border-red-500 focus:ring-red-500", className)}
        {...props}
      >
        {children}
      </select>
    </Shell>
  );
}

/**
 * A field a real visitor never sees or fills (bots do). Sent as `hp`; the database stores nothing when it is not empty.
 * Hidden from assistive technology and the tab order, not with display:none (some bots skip those).
 */
export function Honeypot({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  return (
    <div aria-hidden="true" style={{ position: "absolute", left: "-10000px", top: "auto", width: 1, height: 1, overflow: "hidden" }}>
      <label htmlFor="inquiry-website">Leave this field empty</label>
      <input
        id="inquiry-website"
        name="website"
        type="text"
        tabIndex={-1}
        autoComplete="off"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

/** A failed submit: announced to screen readers and kept next to the button. */
export function FormError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div role="alert" className="flex items-start gap-3 rounded-lg border border-red-100 bg-red-50 p-3" data-testid="inquiry-error">
      <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-600" aria-hidden="true" />
      <p className="text-sm font-medium text-red-700">{message}</p>
    </div>
  );
}

/** Shown in place of the form once the inquiry is stored. Takes focus so keyboard and screen-reader users land on it. */
export function SubmitSuccess({
  title,
  children,
  actionLabel,
  onAgain,
}: {
  title: string;
  children: React.ReactNode;
  actionLabel: string;
  onAgain: () => void;
}) {
  const headingRef = React.useRef<HTMLHeadingElement>(null);
  React.useEffect(() => {
    headingRef.current?.focus();
  }, []);
  return (
    <div className="py-6 text-center" role="status" data-testid="inquiry-success">
      <div className="mb-4 flex justify-center">
        <CheckCircle2 className="h-16 w-16 text-brand-green" aria-hidden="true" />
      </div>
      <h3 ref={headingRef} tabIndex={-1} className="font-heading text-2xl font-semibold text-slate-900 focus:outline-none">
        {title}
      </h3>
      <div className="mx-auto mt-3 max-w-md text-slate-600">{children}</div>
      <Button onClick={onAgain} variant="outline" className="mt-6">
        {actionLabel}
      </Button>
    </div>
  );
}
