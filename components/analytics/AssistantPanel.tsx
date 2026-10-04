"use client";

import { useEffect, useRef, useState } from "react";
import { Send, Sparkles, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { answerQuestion, SUGGESTED_QUESTIONS, type AssistantContext, type AssistantDetail } from "@/lib/analytics/assistant";

type Message = { id: number; from: "user" | "assistant"; text: string; details?: AssistantDetail[]; intent?: string };

/**
 * The Business Assistant. Rule-based and local: it answers from the same model
 * as the page (lib/analytics/assistant.ts). Nothing leaves the browser.
 */
export function AssistantPanel({ open, onClose, ctx }: { open: boolean; onClose: () => void; ctx: AssistantContext }) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const listRef = useRef<HTMLDivElement>(null);
  const nextId = useRef(1);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight });
  }, [messages, open]);

  const ask = (question: string) => {
    const q = question.trim();
    if (!q) return;
    const a = answerQuestion(q, ctx);
    setMessages((prev) => [
      ...prev,
      { id: nextId.current++, from: "user", text: q },
      { id: nextId.current++, from: "assistant", text: a.text, details: a.details, intent: a.intent },
    ]);
    setInput("");
  };

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex justify-end" role="dialog" aria-modal="true" aria-label="Business Assistant">
      <button type="button" aria-label="Close assistant" className="absolute inset-0 bg-slate-900/30" onClick={onClose} />
      <div className="relative flex h-full w-full flex-col bg-white shadow-2xl sm:max-w-md" data-testid="assistant-panel">
        <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
          <div>
            <p className="flex items-center gap-1.5 text-sm font-bold text-slate-900"><Sparkles className="h-4 w-4 text-emerald-600" /> Business Assistant</p>
            <p className="text-[10px] text-slate-500">Rule-based. Answers from the figures on this page and the order records behind them.</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close" className="rounded-md p-1 text-slate-500 hover:bg-slate-100"><X className="h-4 w-4" /></button>
        </div>
        <div ref={listRef} className="flex-1 space-y-3 overflow-y-auto px-4 py-3">
          {messages.length === 0 && (
            <div>
              <p className="mb-2 text-xs text-slate-500">Ask about sales, products, customers, Marketing Officers, the pipeline, the month-end outlook, stock cover, balances or payments.</p>
              <div className="flex flex-wrap gap-1.5">
                {SUGGESTED_QUESTIONS.map((q) => (
                  <button key={q} type="button" onClick={() => ask(q)} className="rounded-full border border-slate-200 px-2.5 py-1 text-left text-[11px] text-slate-700 hover:border-slate-400 hover:bg-slate-50">{q}</button>
                ))}
              </div>
            </div>
          )}
          {messages.map((msg) => (
            <div key={msg.id} className={cn("max-w-[92%] rounded-2xl px-3 py-2 text-xs", msg.from === "user" ? "ml-auto bg-slate-900 text-white" : "bg-slate-100 text-slate-800")}
              data-testid={msg.from === "assistant" ? "assistant-answer" : undefined} data-intent={msg.intent}>
              <p className="whitespace-pre-line leading-relaxed">{msg.text}</p>
              {msg.details && msg.details.length > 0 && (
                <dl className="mt-2 space-y-1 border-t border-slate-200 pt-2">
                  {msg.details.map((d, i) => (
                    <div key={`${d.label}-${i}`} className={d.value.length > 32 ? "space-y-0.5" : "flex justify-between gap-3"}>
                      <dt className={d.value.length > 32 ? "font-semibold text-slate-700" : "text-slate-500"}>{d.label}</dt>
                      <dd className={d.value.length > 32 ? "text-slate-600" : "text-right font-medium text-slate-800"}>{d.value}</dd>
                    </div>
                  ))}
                </dl>
              )}
            </div>
          ))}
        </div>
        <form className="flex gap-2 border-t border-slate-200 p-3" onSubmit={(e) => { e.preventDefault(); ask(input); }}>
          <input data-testid="assistant-input" value={input} onChange={(e) => setInput(e.target.value)} placeholder="Ask a question…" className="h-9 min-w-0 flex-1 rounded-lg border border-slate-200 px-3 text-xs outline-none focus:border-slate-400" />
          <button type="submit" data-testid="assistant-send" disabled={!input.trim()} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-3 text-white disabled:opacity-40"><Send className="h-4 w-4" /></button>
        </form>
      </div>
    </div>
  );
}
