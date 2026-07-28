# OktoHands

A single-file web app that helps caregivers track a loved one's recovery after
breast surgery — drains, medications, exercises, notes, an AI daily summary, and
a calendar/schedule view.

## How it works
- The entire app is **index.html** (HTML + CSS + JS in one file).
- Caregivers sign in, then data syncs across their phones via Supabase.
- The AI day summary calls a Supabase Edge Function (`daily-summary`) that uses Google Gemini.

## Editing & deploying
1. Edit `index.html` in VS Code.
2. Run `.\deploy.ps1` — it bumps the version, writes the CHANGELOG entry, commits, and pushes.
3. Netlify auto-deploys the push to the live site (~30 seconds).

If `CHANGELOG.md` already has an unreleased entry at the top, deploy uses it and
asks nothing. Otherwise it prompts for bullets. Other modes:

    .\deploy.ps1 -Doctor      # what does the script see? writes nothing
    .\deploy.ps1 -DryRun      # full plan, changes nothing
    .\deploy.ps1 -FromDiff    # draft bullets from the actual changes
    .\deploy.ps1 -NoVersion   # changelog + commit, no version bump

If PowerShell refuses to run the script, use `.\deploy.bat` instead, or run
`Unblock-File .\deploy.ps1` once.

## Database setup
`db/01-setup.sql` creates the table and the authenticated-only policies.
`db/daily-summary.ts` is the Edge Function source; it needs `GEMINI_API_KEY`
and `APP_KEY` set as secrets, and Verify JWT off.
