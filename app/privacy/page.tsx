import { LegalShell } from "@/components/legal-shell";
import { DATA_WE_HANDLE, LEGAL } from "@/lib/legal/content";

export const metadata = { title: "Privacy policy - EFZ" };

export default function PrivacyPage() {
  return (
    <LegalShell title="Privacy policy">
      <p>Last updated: {LEGAL.lastUpdated}</p>
      <p>This policy explains how {LEGAL.entityName} (&quot;EFZ&quot;, {LEGAL.entityAddress}) handles personal information in the EFZ customer app and on this website.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">What we handle</h2>
      <ul className="list-disc pl-6">{DATA_WE_HANDLE.map((d) => <li key={d}>{d}</li>)}</ul>
      <h2 className="font-heading text-xl font-semibold text-slate-900">Why</h2>
      <p>To approve your account, take and deliver your orders, issue invoices and receipts, and support you. We do not sell personal information.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">How long we keep it</h2>
      <p>Account data: {LEGAL.retentionAccount}. Order, payment and invoice records: {LEGAL.retentionRecords}.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">Your choices</h2>
      <p>You can ask us to delete your account at any time from the app (Account) or on our <a className="underline" href="/account-deletion">account deletion page</a>.</p>
      <h2 className="font-heading text-xl font-semibold text-slate-900">Contact</h2>
      <p>{LEGAL.contactEmail}, {LEGAL.contactPhone}. Governing law: {LEGAL.governingLaw}.</p>
    </LegalShell>
  );
}
