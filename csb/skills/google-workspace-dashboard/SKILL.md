---
name: google-workspace-dashboard
description: Create, restore, or update the pinned employee-friendly Google Workspace, daily briefing, and presentation dashboards in OpenClaw. Use when the user asks for Google Workspace buttons, a workday dashboard, executive briefing, presentation studio, or a non-technical interface for common Google tasks.
---

# Google Workspace Dashboard

Install the three versioned dashboard assets into the current Control UI thread.

## Install or update

1. Call `dashboard` with `action: read`.
2. Ensure these tabs exist, creating only the missing tabs by calling `dashboard` with `action`: `tab_create`:
   - `tabId`: `overview`, `title`: `Overview`
   - `tabId`: `briefing`, `title`: `Daily Briefing`
   - `tabId`: `presentations`, `title`: `Presentation Studio`
3. Install each asset with `show_widget`, using its complete file contents as `widget_code`, `pin: true`, `size: lg`, and `capabilities.tools: ["prompt"]`:
   - `{baseDir}/assets/google-workspace-dashboard.html`: title `Google Workspace`, name `google-workspace-actions`, tab `overview`
   - `{baseDir}/assets/daily-briefing-dashboard.html`: title `Daily Briefing`, name `daily-briefing-actions`, tab `briefing`
   - `{baseDir}/assets/presentation-studio-dashboard.html`: title `Presentation Studio`, name `presentation-studio-actions`, tab `presentations`
4. Tell the user to approve each widget's one-time Prompt capability grant if requested.

Reuse the stable widget name when updating so the existing board placement is preserved. Do not add network capabilities: every button sends a visible prompt into the owning thread and the agent performs the Google operation.

## Safety contract

- Treat Gmail as read-only. Never send, draft, reply, label, archive, move, or delete email.
- Pass `--readonly` to `gog` for Gmail operations as an additional local safeguard.
- Read Calendar without extra confirmation.
- Before creating or changing a calendar event, show the final title, attendees, date, start time, timezone, duration, and conferencing choice. Require explicit user confirmation immediately before the write.
- Build presentation previews as self-contained HTML widgets without network capabilities. Preserve source links and visibly label assumptions or unsupported claims.
- Never overwrite a source presentation. Create a review copy, inspect the rendered preview, and report visual issues instead of claiming success from text extraction alone.
- Never run an action merely because the dashboard was installed; wait for a button-generated user prompt.
- If `show_widget` is unavailable, ask the user to open the OpenClaw Control UI and retry in that browser session.

## Transient Google failures

If a read-only Google command fails with `round trip: EOF`, retry that same command once. Do not retry a write operation automatically.

If the retry succeeds, continue normally. If it fails again, report the command, exact error, host, HTTP method, and API path when available. Check the OpenShell audit log when that capability is available and report the relevant event verbatim or as a close paraphrase. If the audit log is unavailable or inconclusive, say that the cause is unknown; do not infer an allowlist, connectivity, or credential diagnosis without supporting evidence.
