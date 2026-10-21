import { LegalShell } from "@/components/legal-shell";
import { LEGAL } from "@/lib/legal/content";

export const metadata = { title: "Delete your EFZ account" };

export default function AccountDeletionPage() {
  return (
    <LegalShell title="Delete your EFZ account">
      <p>You can ask EFZ to delete your customer account at any time.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">In the app</h2>
      <p>Open <strong>Account</strong> and choose the account deletion option and confirm. Your access ends immediately.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">Without the app</h2>
      <p>Contact us at {LEGAL.contactEmail} or {LEGAL.contactPhone} from the email address or phone number registered on your account.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">What happens next</h2>
      <p>{LEGAL.deletionHandler} processes your request within {LEGAL.deletionResponseTime}. What is removed: {LEGAL.deletionScope}. Order, payment and invoice records are kept as described in the <a className="underline" href="/privacy">privacy policy</a>: {LEGAL.retentionRecords}. Account data is kept for {LEGAL.retentionAccount}.</p>
    </LegalShell>
  );
}
