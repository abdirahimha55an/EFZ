import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { ConvertRequestDialog } from "@/components/admin/requests/ConvertRequestDialog";
import { stub } from "@/lib/supabase/db";

window.__h = { React, act, createRoot, ConvertRequestDialog, stub };
