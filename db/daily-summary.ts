// OktoHands — daily AI summary (Gemini)
// Redeploy this into the NEW Supabase project as an Edge Function named
// "daily-summary". Set GEMINI_API_KEY as a secret on the function.
//
// CHANGED from the original: APP_KEY is now read from an environment
// variable instead of being hardcoded, so rotating it doesn't require a
// code edit. Set APP_KEY to the NEW project's publishable key.

const APP_KEY = Deno.env.get("APP_KEY") ?? "";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-app-key, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Live aliases first so Google retiring dated versions doesn't break us.
const MODELS = ["gemini-flash-latest", "gemini-2.5-flash", "gemini-flash-lite-latest"];

async function callGenerateContent(apiKey: string, model: string, prompt: string) {
  return await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "x-goog-api-key": apiKey, "content-type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: { maxOutputTokens: 2048, temperature: 0.4 },
    }),
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405, headers: { ...CORS, "content-type": "application/json" } });
  }

  if (!APP_KEY || req.headers.get("x-app-key") !== APP_KEY) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { ...CORS, "content-type": "application/json" } });
  }

  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    return new Response(
      JSON.stringify({ error: "AI summary isn't set up yet — add GEMINI_API_KEY as a secret for this Edge Function in the Supabase dashboard." }),
      { status: 500, headers: { ...CORS, "content-type": "application/json" } }
    );
  }

  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }
  const { patient, date, facts } = body || {};
  // The app sends a placeholder, never a real name. Do not log `facts`.
  if (!facts || typeof facts !== "string") {
    return new Response(JSON.stringify({ error: "missing facts" }), { status: 400, headers: { ...CORS, "content-type": "application/json" } });
  }

  const prompt = `You write short daily recap notes for family caregivers using a post-mastectomy home-care app. Write a warm, plain-language summary of ${date || "today"} for ${patient || "the patient"}, 2-4 sentences, based ONLY on the facts listed below. Do not invent numbers, symptoms, or events that are not listed. If something notable stands out (a drain trending up, a missed dose, an open watch item), mention it plainly and calmly — no alarm, no medical advice, no diagnosis. Just recap what was actually logged. Plain prose, no markdown formatting, no bullet points, no headers.

Facts:
${facts}`;

  const errors: string[] = [];

  for (const model of MODELS) {
    try {
      const r = await callGenerateContent(apiKey, model, prompt);
      if (r.ok) {
        const data = await r.json();
        const parts = data?.candidates?.[0]?.content?.parts || [];
        const text = parts.map((p: any) => p?.text || "").join("").trim();
        if (text) return new Response(JSON.stringify({ summary: text, model }), { headers: { ...CORS, "content-type": "application/json" } });
        errors.push(`${model}: empty output (finishReason ${data?.candidates?.[0]?.finishReason || "?"})`);
        continue;
      }
      const data = await r.json().catch(() => ({}));
      const msg = data?.error?.message || `HTTP ${r.status}`;
      errors.push(`${model}: ${msg}`);
    } catch (e) {
      errors.push(`${model}: ${String(e)}`);
    }
  }

  return new Response(JSON.stringify({ error: `AI request failed on every attempt:\n${errors.join("\n")}` }), { status: 502, headers: { ...CORS, "content-type": "application/json" } });
});
