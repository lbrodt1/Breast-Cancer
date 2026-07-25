# Changelog

All notable changes to Recovery Tracker. Newest entries on top.

## v1.0.7 - 2026-07-24
- Fixed the app rebuilding the whole screen every 12 seconds (the database reordered JSON keys so the sync always thought data changed) - now it only re-renders on real changes, so calendars and how-tos stay put

## v1.0.6 - 2026-07-24
- Fixed how-tos and instructions collapsing when the app synced in the background - expanded sections now stay open through a re-render

## v1.0.5 - 2026-07-24
- Replaced the date fields with a built-in calendar (tap a field, a calendar drops down, tap a day) so date selection works reliably on desktop and phone with no flashing

## v1.0.4 - 2026-07-24
- Date pickers now use the browser's native calendar so they no longer flash open and close on desktop

## v1.0.3 - 2026-07-24
- Fixed the date pickers flashing open and closing on phones/tablets - the native calendar now opens normally on touch

## v1.0.2 - 2026-07-24
- Fixed popups/dialogs flashing closed on touch screens - the tap that opens a sheet no longer dismisses it

## v1.0.1 - 2026-07-24
- First full release live: Recovery Tracker rename, Schedule + calendar tab, end-of-care & per-task dates, test mode, per-phone caregivers, Gemini day summary, and date-picker fixes

## 2026-07-24 — Recovery Tracker relaunch

### Added
- **Schedule tab** (📅) with a **month calendar view** — the surgery day is marked, days with tasks due and days already logged get their own dots, today is outlined, months can be paged, and tapping any day opens it — followed by the week-by-week schedule cards.
- **End of care date** in Care setup that sets how long the recovery schedule runs (defaults to 6 weeks after surgery) and drives the "Week X of N" counter throughout the app.
- **Start and end dates on every medication and task**, pre-filled from the surgery date through the end-of-care date and editable per item; both the daily task list and the schedule honor these dates.
- **Test mode** toggle to preview drains, exercises, meds, and the AI day summary before the surgery date.
- **Caregivers set up at the start** (onboarding) plus a dedicated **Caregivers section** in More to add, rename, and remove caregivers.
- **Per-phone caregiver identity**: each phone is asked once who is using it and remembers the answer, so every sign-off is attributed automatically. (A web app can't read a person's name from the phone itself; this remembered-per-phone approach achieves the same result.)

### Changed
- **Renamed the app to "Recovery Tracker"** (setup screen and browser tab).
- **Reordered the More tab** to: Care setup (surgery date first), Prep checklist, Caregivers, Medications, Tasks.
- **Moved the weekly schedule** out of More into its own Schedule tab, recomputed live from the surgery date, the end-of-care date, and each task's date range.
- Medication and task editors now use **start/end date pickers** instead of week numbers.

### Fixed
- AI day summary error message still referenced the old `ANTHROPIC_API_KEY`; corrected it to `GEMINI_API_KEY`.
- Date fields (surgery date, end of care, and every medication/task start & end date) now open the calendar when you click anywhere in the field, not just the small calendar icon.

### AI day summary (Supabase Edge Function `daily-summary`)
- Confirmed the daily summary is running on **Google Gemini** (`gemini-flash-latest`).
- **Hardened the model fallback**: replaced the invalid `gemini-2.5-flash-latest` with the valid `gemini-2.5-flash`. Fallback order is now `gemini-flash-latest` → `gemini-2.5-flash` → `gemini-flash-lite-latest`.

### Deployment & tooling
- Added continuous-deployment scaffolding: `index.html` at the repo root, `netlify.toml`, `.gitignore`, and a `README`.
- Set up the VS Code → GitHub → Netlify workflow.
- Added this `CHANGELOG.md` and a deploy script (`deploy.ps1` / `deploy.bat`) that requires a changelog entry before it commits and pushes.
- Added an app version number (starting at **v1.0.0**) shown small in the app — in the header and the About footer — which the deploy script auto-increments each release.
