/**
 * Shared schedule utilities for Fazm routines.
 *
 * Schedule strings come in three flavors:
 *   "cron:0 9 * * 1-5"       — 5-field cron (minute hour dom month dow)
 *   "every:1800"             — interval in seconds
 *   "at:2026-04-30T18:00:00Z" — one-shot absolute timestamp (ISO 8601)
 */

/**
 * Compute the next fire time for a schedule string.
 * Returns a Date, or null if there is no next fire (one-shot already past).
 */
export function computeNextRun(schedule, fromDate = new Date()) {
  if (!schedule) return null;
  const colon = schedule.indexOf(":");
  if (colon < 0) return null;
  const kind = schedule.slice(0, colon);
  const rest = schedule.slice(colon + 1).trim();

  if (kind === "every") {
    const sec = parseInt(rest, 10);
    if (!Number.isFinite(sec) || sec <= 0) return null;
    return new Date(fromDate.getTime() + sec * 1000);
  }

  if (kind === "at") {
    const t = new Date(rest);
    if (isNaN(t.getTime())) return null;
    return t > fromDate ? t : null;
  }

  if (kind === "cron") {
    return nextCronFire(rest, fromDate);
  }

  return null;
}

/**
 * Return null on success, or a string explaining why the schedule is invalid.
 */
export function validateSchedule(schedule) {
  if (typeof schedule !== "string" || !schedule.includes(":")) {
    return 'schedule must be one of "cron:<expr>", "every:<seconds>", or "at:<ISO 8601>"';
  }
  const next = computeNextRun(schedule, new Date());
  if (next === null) {
    if (schedule.startsWith("at:")) return "absolute timestamp is in the past";
    return "schedule string failed to parse — check format and field ranges";
  }
  return null;
}

function nextCronFire(expr, fromDate) {
  const parts = expr.split(/\s+/);
  if (parts.length !== 5) return null;
  const [minP, hourP, domP, monP, dowP] = parts;
  const mins = expandField(minP, 0, 59);
  const hours = expandField(hourP, 0, 23);
  const doms = expandField(domP, 1, 31);
  const mons = expandField(monP, 1, 12);
  const dows = expandField(dowP, 0, 6).map((d) => (d === 7 ? 0 : d));
  if (!mins || !hours || !doms || !mons || !dows) return null;

  const start = new Date(fromDate.getTime() + 60 * 1000);
  start.setSeconds(0, 0);
  const limit = new Date(start.getTime() + 366 * 24 * 60 * 60 * 1000);

  for (let t = start.getTime(); t < limit.getTime(); t += 60 * 1000) {
    const d = new Date(t);
    if (!mins.includes(d.getMinutes())) continue;
    if (!hours.includes(d.getHours())) continue;
    if (!mons.includes(d.getMonth() + 1)) continue;
    const domAny = domP === "*";
    const dowAny = dowP === "*";
    const domMatch = doms.includes(d.getDate());
    const dowMatch = dows.includes(d.getDay());
    if (domAny && dowAny) return d;
    if (domAny) { if (dowMatch) return d; continue; }
    if (dowAny) { if (domMatch) return d; continue; }
    // Standard cron: when both fields are restricted, EITHER match qualifies
    if (domMatch || dowMatch) return d;
  }
  return null;
}

function expandField(field, min, max) {
  const out = new Set();
  for (const part of field.split(",")) {
    const stepIdx = part.indexOf("/");
    let step = 1;
    let body = part;
    if (stepIdx >= 0) {
      step = parseInt(part.slice(stepIdx + 1), 10);
      body = part.slice(0, stepIdx);
      if (!Number.isFinite(step) || step <= 0) return null;
    }
    let lo = min, hi = max;
    if (body !== "*") {
      const dash = body.indexOf("-");
      if (dash >= 0) {
        lo = parseInt(body.slice(0, dash), 10);
        hi = parseInt(body.slice(dash + 1), 10);
      } else {
        lo = hi = parseInt(body, 10);
      }
      if (!Number.isFinite(lo) || !Number.isFinite(hi)) return null;
      if (lo < min || hi > max || lo > hi) return null;
    }
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return [...out].sort((a, b) => a - b);
}
