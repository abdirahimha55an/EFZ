"use client";

/**
 * The public Contact form. A message is stored by submit_public_inquiry() (migration 30) and shows up for staff in Admin > Inquiries.
 *
 * - Client checks (lib/inquiryForm.ts) give instant feedback; the database checks the same rules again and is the authority.
 * - One submission key per filled-in form: a double click or a network retry resubmits the same key and the database returns the first
 *   message instead of storing a second one. The key changes when the visitor edits anything, so an edited retry is a new message.
 * - A hidden honeypot field catches bots; the database also limits how often one phone/email can write.
 */
import { useRef, useState } from "react";
import { Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { FormError, Honeypot, SubmitSuccess, TextAreaField, TextField } from "@/components/public/fields";
import { describeDbError, getDb } from "@/lib/supabase/db";
import { INQUIRY_LIMITS, firstInvalid, validateContact, visitorFriendlyError, type ContactValues, type FieldErrors } from "@/lib/inquiryForm";

const EMPTY: ContactValues = { name: "", phone: "", email: "", subject: "", message: "" };
const FIELD_ORDER = ["name", "phone", "email", "subject", "message"] as const;
const FIELD_ID: Record<keyof ContactValues, string> = {
  name: "contact-name",
  phone: "contact-phone",
  email: "contact-email",
  subject: "contact-subject",
  message: "contact-message",
};

const newKey = () => globalThis.crypto?.randomUUID?.() ?? undefined;

export function ContactForm({ whatsappUrl }: { whatsappUrl: string }) {
  const [values, setValues] = useState<ContactValues>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors<keyof ContactValues>>({});
  const [honeypot, setHoneypot] = useState("");
  const [submissionKey, setSubmissionKey] = useState<string | undefined>(newKey);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const inFlight = useRef(false);

  const change = (field: keyof ContactValues) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
    setValues((v) => ({ ...v, [field]: e.target.value }));
    setSubmissionKey(newKey());
    setSubmitError(null);
    if (errors[field] || (field === "phone" || field === "email" ? errors.phone || errors.email : false)) {
      setErrors((prev) => {
        const next = { ...prev };
        delete next[field];
        return next;
      });
    }
  };

  const blur = (field: keyof ContactValues) => () => {
    const found = validateContact(values);
    setErrors((prev) => ({ ...prev, [field]: found[field] }));
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (inFlight.current) return;
    setSubmitError(null);

    const found = validateContact(values);
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
        kind: "contact",
        name: values.name.trim(),
        phone: values.phone.trim(),
        email: values.email.trim(),
        subject: values.subject.trim(),
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
        title="Message received"
        actionLabel="Send another message"
        onAgain={() => {
          setSubmissionKey(newKey());
          setDone(false);
        }}
      >
        <p>
          Thank you for contacting us. Our team will read your message and reply using the phone number or email you gave.
        </p>
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
    <form className="relative space-y-6" onSubmit={submit} noValidate aria-label="Contact form">
      <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
        <TextField
          id={FIELD_ID.name}
          label="Full Name"
          required
          autoComplete="name"
          maxLength={INQUIRY_LIMITS.name}
          placeholder="John Doe"
          value={values.name}
          onChange={change("name")}
          onBlur={blur("name")}
          error={errors.name}
        />
        <TextField
          id={FIELD_ID.phone}
          label="Phone Number"
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          maxLength={INQUIRY_LIMITS.phone}
          placeholder="061 234 5678"
          hint="Phone or email, so we can reply."
          value={values.phone}
          onChange={change("phone")}
          onBlur={blur("phone")}
          error={errors.phone}
        />
      </div>
      <TextField
        id={FIELD_ID.email}
        label="Email Address"
        type="email"
        inputMode="email"
        autoComplete="email"
        maxLength={INQUIRY_LIMITS.email}
        placeholder="john@example.com"
        value={values.email}
        onChange={change("email")}
        onBlur={blur("email")}
        error={errors.email}
      />
      <TextField
        id={FIELD_ID.subject}
        label="Subject"
        required
        maxLength={INQUIRY_LIMITS.subject}
        placeholder="How can we help you?"
        value={values.subject}
        onChange={change("subject")}
        onBlur={blur("subject")}
        error={errors.subject}
      />
      <TextAreaField
        id={FIELD_ID.message}
        label="Message"
        required
        maxLength={INQUIRY_LIMITS.message}
        placeholder="Your message here..."
        value={values.message}
        onChange={change("message")}
        onBlur={blur("message")}
        error={errors.message}
      />

      <Honeypot value={honeypot} onChange={setHoneypot} />
      <FormError message={submitError} />

      <Button type="submit" size="lg" className="w-full md:w-auto" disabled={submitting} aria-busy={submitting}>
        {submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />}
        {submitting ? "Sending..." : "Send Message"}
      </Button>
    </form>
  );
}
