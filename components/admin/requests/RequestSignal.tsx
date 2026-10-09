"use client";

import { createContext, useContext } from "react";

/**
 * The admin layout's alert loop (Realtime on orders and order_requests, the 30 s
 * poll, focus/visibility) bumps `version` every time it refreshes, and publishes
 * the open-request count it read. The Website Requests page re-reads its list
 * whenever `version` changes, so it never opens a Realtime channel of its own.
 */
export type RequestSignal = {
  version: number;
  openCount: number | null;
  /** Ask the layout to refresh now (after this tab changed something). */
  refresh: () => void;
};

export const RequestSignalContext = createContext<RequestSignal>({ version: 0, openCount: null, refresh: () => {} });

export const useRequestSignal = () => useContext(RequestSignalContext);
