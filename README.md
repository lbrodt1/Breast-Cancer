# Recovery Track

A single-file web app that helps caregivers track a loved one's recovery after
breast surgery — drains, medications, exercises, notes, an AI daily summary, and
a calendar/schedule view.

## How it works
- The entire app is **index.html** (HTML + CSS + JS in one file).
- Data syncs across caregivers' phones via Supabase.
- The AI day summary calls a Supabase Edge Function (`daily-summary`) that uses Google Gemini.

## Editing & deploying
1. Edit `index.html` in VS Code.
2. Commit and push to GitHub.
3. Netlify auto-deploys the push to the live site.
