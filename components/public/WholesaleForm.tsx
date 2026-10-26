"use client";

/**
 * The public Wholesale quote form. Stored by submit_public_inquiry() (migration 30) and shown to staff in Admin > Inquiries.
 * Same behavior as the Contact form: client checks for instant feedback, the database is the authority, one submission key per
 * filled-in form, a honeypot, and a per-visitor limit enforced by the database.
 */
import { useRef, useState } from "react";
import { Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { FormError, Honeypot, SelectField, SubmitSuccess, TextAreaField, TextField } from "@/components/public/fields";
import { describeDbError, getDb } from "@/lib/supabase/db";
import {
  BUSINESS_TYPES,
  INQUIRY_LIMITS,
  firstInvalid,
  validateWholesale,
  visitorFriendlyError,
  type FieldErrors,
  type WholesaleValues,
} from "@/lib/inquiryForm";

const EMPTY: WholesaleValues = { organization: "", name: "", phone: "", businessType: "", message: "" };
const FIELD_ORDER = ["organization", "name", "phone", "businessType", "message"] as const;
const FIELD_ID: Record<keyof WholesaleValues, string> = {
  organization: "wholesale-organization",
  name: "wholesale-name",
  phone: "wholesale-phone",
  businessType: "wholesale-business-type",
  message: "wholesale-message",
};

const newKey = () => globalThis.crypto?.randomUUID?.() ?? undefined;

export function WholesaleForm({ whatsappUrl }: { whatsappUrl: string }) {
  const [values, setValues] = useState<WholesaleValues>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors<keyof WholesaleValues>>({});
  const [honeypot, setHoneypot] = useState("");
  const [submissionKey, setSubmissionKey] = useState<string | undefined>(newKey);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const inFlight = useRef(false);

  const change = (field: keyof WholesaleValues) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
    setValues((v) => ({ ...v, [field]: e.target.value }));
    setSubmissionKey(newKey());
    setSubmitError(null);
    if (errors[field]) {
      setErrors((prev) => {
        const next = { ...prev };
        delete next[field];
        return next;
      });
    }
  };

  const blur = (field: keyof WholesaleValues) => () => {
    const found = validateWholesale(values);
    setErrors((prev) => ({ ...prev, [field]: found[field] }));
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (inFlight.current) return;
    setSubmitError(null);

    const found = validateWholesale(values);
    setErrors(found);
    const first = firstInvalid(found, FIELD_ORDER);
    if (first) {
      document.getElementById(FIELD_ID[first])?.focus();
      return;
    }

    inFlight.current = true;
    setSubmitting(true);
    try {
      await getDb().inquiries.submit({
        kind: "wholesale",
        organization: values.organization.trim(),
        name: values.name.trim(),
        phone: values.phone.trim(),
        businessType: values.businessType,
        message: values.message.trim(),
        hp: honeypot,
        submissionKey,
      });
      setValues(EMPTY);
      setErrors({});
      setDone(true);
    } catch (error) {
      setSubmitError(visitorFriendlyError(describeDbError(error)));
    } finally {
      inFlight.current = false;
      setSubmitting(false);
    }
  };

  if (done) {
    return (
      <SubmitSuccess
        title="Inquiry received"
        actionLabel="Send another inquiry"
        onAgain={() => {
          setSubmissionKey(newKey());
          setDone(false);
        }}
      >
        <p>Thank you. Our wholesale team will review your inquiry and contact you on the phone number you gave.</p>
        <p className="mt-2 text-sm">
          In a hurry?{" "}
          <a href={whatsappUrl} target="_blank" rel="noopener noreferrer" className="font-medium text-brand-green hover:underline">
            Chat with us on WhatsApp
          </a>
          .
        </p>
      </SubmitSuccess>
    );
  }

  return (
    <form className="relative space-y-6" onSubmit={submit} noValidate aria-label="Wholesale quote request">
      <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
        <TextField
          id={FIELD_ID.organization}
          label="Organization / Arena Name"
          required
          autoComplete="organization"
          maxLength={INQUIRY_LIMITS.organization}
          placeholder="E.g., Mogadishu Sports Arena"
          value={values.organization}
          onChange={change("organization")}
          onBlur={blur("organization")}
          error={errors.organization}
        />
        <TextField
          id={FIELD_ID.name}
          label="Contact Person"
          required
          autoComplete="name"
          maxLength={INQUIRY_LIMITS.name}
          placeholder="Full Name"
          value={values.name}
          onChange={change("name")}
          onBlur={blur("name")}
          error={errors.name}
        />
      </div>

      <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
        <TextField
          id={FIELD_ID.phone}
          label="Phone Number"
          required
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          maxLength={INQUIRY_LIMITS.phone}
          placeholder="061 234 5678"
          value={values.phone}
          onChange={change("phone")}
          onBlur={blur("phone")}
          error={errors.phone}
        />
        <SelectField
          id={FIELD_ID.businessType}
          label="Business Type"
          required
          value={values.businessType}
          onChange={change("businessType")}
          onBlur={blur("businessType")}
          error={errors.businessType}
        >
          <option value="">Select your business type...</option>
          {BUSINESS_TYPES.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </SelectField>
      </div>

      <TextAreaField
        id={FIELD_ID.message}
        label="What products are you interested in?"
        maxLength={INQUIRY_LIMITS.message}
        placeholder="E.g., We need 50 futsal balls per month..."
        value={values.message}
        onChange={change("message")}
        onBlur={blur("message")}
        error={errors.message}
        className="min-h-[100px]"
      />

      <Honeypot value={honeypot} onChange={setHoneypot} />
      <FormError message={submitError} />

      <Button type="submit" size="lg" className="w-full" disabled={submitting} aria-busy={submitting}>
        {submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />}
        {submitting ? "Submitting..." : "Submit Inquiry"}
      </Button>
    </form>
  );
}
