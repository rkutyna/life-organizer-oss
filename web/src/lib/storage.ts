/**
 * localStorage for per-device conveniences (last calendar view, theme, collapsed sections).
 * Every access is wrapped: private mode or blocked storage must never break the app.
 * Keys are namespaced "lo.<name>".
 */

export function readStorage<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage.getItem(`lo.${key}`);
    return raw === null ? fallback : (JSON.parse(raw) as T);
  } catch {
    return fallback;
  }
}

export function writeStorage<T>(key: string, value: T): void {
  try {
    window.localStorage.setItem(`lo.${key}`, JSON.stringify(value));
  } catch {
    // storage unavailable; the preference just won't persist
  }
}
