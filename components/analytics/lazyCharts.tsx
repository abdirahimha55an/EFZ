"use client";

// Recharts is loaded on the client only, in its own chunk, and only on this page.
// next/dynamic requires its options as an object literal at each call.
import dynamic from "next/dynamic";
import { ChartLoading } from "./primitives";

export const SalesTrendChart = dynamic(() => import("./charts").then((m) => m.SalesTrendChart), { ssr: false, loading: () => <ChartLoading /> });
export const CumulativeChart = dynamic(() => import("./charts").then((m) => m.CumulativeChart), { ssr: false, loading: () => <ChartLoading /> });
export const ProductMixChart = dynamic(() => import("./charts").then((m) => m.ProductMixChart), { ssr: false, loading: () => <ChartLoading /> });
export const PriceRealizationChart = dynamic(() => import("./charts").then((m) => m.PriceRealizationChart), { ssr: false, loading: () => <ChartLoading /> });
export const ParetoChart = dynamic(() => import("./charts").then((m) => m.ParetoChart), { ssr: false, loading: () => <ChartLoading /> });
export const NewReturningChart = dynamic(() => import("./charts").then((m) => m.NewReturningChart), { ssr: false, loading: () => <ChartLoading /> });
export const OfficerChart = dynamic(() => import("./charts").then((m) => m.OfficerChart), { ssr: false, loading: () => <ChartLoading /> });
export const PipelineStatusChart = dynamic(() => import("./charts").then((m) => m.PipelineStatusChart), { ssr: false, loading: () => <ChartLoading /> });
export const WeeklyVelocityChart = dynamic(() => import("./charts").then((m) => m.WeeklyVelocityChart), { ssr: false, loading: () => <ChartLoading /> });
export const StockCoverChart = dynamic(() => import("./charts").then((m) => m.StockCoverChart), { ssr: false, loading: () => <ChartLoading /> });
