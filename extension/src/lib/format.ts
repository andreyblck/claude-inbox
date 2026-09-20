/** Formatting that both views share. Nothing here reaches the filesystem. */
import { Color } from "@raycast/api";
import { age, oneLine, truncate } from "./state";
import type { UsageRecord } from "./inbox";

/** "resets in 2h 14m" — a countdown answers "can I keep going", a timestamp doesn't. */
export function resetsIn(resetsAt?: number | null, now = Date.now()): string | undefined {
  if (!resetsAt) return undefined;
  const secs = Math.round(resetsAt - now / 1000);
  if (secs <= 0) return "resetting";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `resets in ${mins}m`;
  const hours = Math.floor(mins / 60);
  const rest = mins % 60;
  if (hours < 24) return rest ? `resets in ${hours}h ${rest}m` : `resets in ${hours}h`;
  return `resets in ${Math.round(hours / 24)}d`;
}

/** One scale for every usage number in the product. */
export function usageTint(percentage: number): Color {
  if (percentage >= 90) return Color.Red;
  if (percentage >= 70) return Color.Yellow;
  return Color.SecondaryText;
}

export function pct(value?: number | null): string | undefined {
  return typeof value === "number" ? `${Math.round(value)}%` : undefined;
}

/**
 * The single-line usage summary, used verbatim in the menu bar.
 * A reading that hides its own staleness is worse than no reading.
 */
export function usageLine(u: UsageRecord, now = Date.now()): string {
  const five = pct(u.rate_limits?.five_hour?.used_percentage);
  const week = pct(u.rate_limits?.seven_day?.used_percentage);
  const parts: string[] = [];
  if (five) parts.push(`5h ${five}`);
  if (week) parts.push(`7d ${week}`);
  if (!parts.length) return `no limit data · ${age(u.ts, now)}`;
  const soonest = [u.rate_limits?.five_hour?.resets_at, u.rate_limits?.seven_day?.resets_at]
    .filter((t): t is number => typeof t === "number")
    .sort((a, b) => a - b)[0];
  const reset = resetsIn(soonest, now);
  if (reset) parts.push(reset);
  parts.push(age(u.ts, now));
  return parts.join(" · ");
}

/** Highest of the two windows: what a threshold should watch. */
export function usagePeak(u: UsageRecord): number {
  return Math.max(u.rate_limits?.five_hour?.used_percentage ?? 0, u.rate_limits?.seven_day?.used_percentage ?? 0);
}

export function codeBlock(value?: string): string {
  if (!value) return "";
  return ["```bash", oneLine(value).length > 400 ? truncate(value, 400) : value, "```", ""].join("\n");
}

