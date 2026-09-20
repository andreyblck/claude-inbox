/**
 * `@raycast/api` only loads inside Raycast's own runtime, so the tests bundle
 * against this instead. It carries exactly what lib/ touches: the two enums are
 * compared by value in assertions, and preferences are whatever the test sets.
 */
export const Color = {
  Yellow: "raycast-yellow",
  Orange: "raycast-orange",
  Blue: "raycast-blue",
  Green: "raycast-green",
  Red: "raycast-red",
  SecondaryText: "raycast-secondary-text",
} as const;

export const Icon = new Proxy({} as Record<string, string>, {
  get: (_t, name) => `icon-${String(name)}`,
});

let prefs: Record<string, unknown> = {};
export function setPreferences(next: Record<string, unknown>) {
  prefs = next;
}
export function getPreferenceValues<T>(): T {
  return prefs as T;
}
