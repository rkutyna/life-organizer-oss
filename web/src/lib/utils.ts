import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/** "wrong password" -> "Wrong password": server error details read as sentences in the UI. */
export function sentence(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** Merge Tailwind class names, later ones winning (shadcn/ui convention). */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
