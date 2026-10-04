"use client";

// Recharts is loaded on the client only, in its own chunk, and only on this page.
import dynamic from "next/dynamic";
import { ChartLoading } from "./primitives";

const opts = { ssr: false, loading: () => <ChartLoading /> } as const;

export const SalesTrendChart = dynamic(() => import("./charts").then((m) => m.SalesTrendChart), opts);
export const CumulativeChart = dynamic(() => import("./charts").then((m) => m.CumulativeChart), opts);
export const ProductMixChart = dynamic(() => import("./charts").then((m) => m.ProductMixChart), opts);
export const PriceRealizationChart = dynamic(() => import("./charts").then((m) => m.PriceRealizationChart), opts);
export const ParetoChart = dynamic(() => import("./charts").then((m) => m.ParetoChart), opts);
export const NewReturningChart = dynamic(() => import("./charts").then((m) => m.NewReturningChart), opts);
export const OfficerChart = dynamic(() => import("./charts").then((m) => m.OfficerChart), opts);
export const PipelineStatusChart = dynamic(() => import("./charts").then((m) => m.PipelineStatusChart), opts);
export const WeeklyVelocityChart = dynamic(() => import("./charts").then((m) => m.WeeklyVelocityChart), opts);
export const StockCoverChart = dynamic(() => import("./charts").then((m) => m.StockCoverChart), opts);
