import * as React from "react";
import { cn } from "@/lib/utils";

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "outline" | "ghost" | "secondary" | "danger" | "whatsapp";
  size?: "default" | "sm" | "lg" | "icon";
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default", ...props }, ref) => {
    return (
      <button
        ref={ref}
        className={cn(
          "inline-flex items-center justify-center whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-green disabled:pointer-events-none disabled:opacity-50",
          {
            "bg-brand-blue text-white hover:bg-brand-blue-light shadow-md dark:bg-brand-blue dark:hover:bg-brand-blue-light": variant === "default",
            "border-2 border-brand-blue text-brand-blue hover:bg-brand-blue hover:text-white dark:text-blue-400 dark:border-blue-400 dark:hover:bg-blue-400 dark:hover:text-slate-900": variant === "outline",
            "hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300": variant === "ghost",
            "bg-slate-100 dark:bg-slate-800 text-slate-900 dark:text-slate-100 hover:bg-slate-200 dark:hover:bg-slate-700": variant === "secondary",
            "bg-red-500 text-white hover:bg-red-600": variant === "danger",
            "bg-[#25D366] text-white hover:bg-[#128C7E] shadow-md": variant === "whatsapp",
            "h-10 px-4 py-2": size === "default",
            "h-9 rounded-md px-3": size === "sm",
            "h-12 rounded-md px-8 text-base": size === "lg",
            "h-10 w-10": size === "icon",
          },
          className
        )}
        {...props}
      />
    );
  }
);
Button.displayName = "Button";

export { Button };
