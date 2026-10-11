"use client";

import dynamic from "next/dynamic";
import { ChartLoading } from "@/components/analytics/primitives";

export const CashFlowChart = dynamic(() => import("./charts").then((m) => m.CashFlowChart), { ssr: false, loading: () => <ChartLoading /> });
export const AgingChart = dynamic(() => import("./charts").then((m) => m.AgingChart), { ssr: false, loading: () => <ChartLoading /> });
export const ProductProfitChart = dynamic(() => import("./charts").then((m) => m.ProductProfitChart), { ssr: false, loading: () => <ChartLoading /> });
