# BUILD_GUIDE — AI Content Engine

The single source of truth for building this system. Build **in order**; each step has an
acceptance check. Don't jump ahead (lesson from project #1: don't start a step before its
prerequisites/keys exist).

---

## 1. What we're building

An autonomous content-repurposing pipeline with a human approval gate:

```
Schedule/RSS (AI & automation news)
   -> Validate + dedup (skip items already processed)
   -> Fetch article text (grounding)
   -> AI generate content pack (LinkedIn post + X thread + newsletter blurb), strict JSON
   -> Validate/parse JSON (retry on malformed)
   -> Store in Supabase  (status = 'pending')
   -> Telegram preview + inline buttons [Approve] [Reject] [Regenerate]
   -> Wait for human callback
        Approve   -> status='ready'  (+ optional scheduled publish)
        Reject    -> status='rejected'
        Regenerate-> re-run generation, new preview
   -> Public content-calendar dashboard (read-only)
```

**Why this shape:** shows scheduled autonomy + structured generative AI + a real
human-in-the-loop control plane — a different class of system from the fully-autonomous
lead pipeline in project #1.

---

## 2. Stack (100% free, no card)

| Concern        | Tool                                   |
|----------------|----------------------------------------|
| Orchestration  | n8n Cloud (existing workspace)         |
| LLM            | Groq — `llama-3.3-70b-versatile`       |
| Database       | Supabase (existing project, new tables)|
| Notifications  | Telegram bot (existing `@myleadqualbot`)|
| Frontend host  | GitHub Pages (Actions deploy of /frontend) |
| Source         | Public RSS feeds (AI/automation news)  |

Reuse project #1's accounts; only new artifacts are the Supabase tables, the n8n
workflow(s), and the frontend.

---

## 3. Data model (Supabase)

Table `content_items` — one row per source article processed.

| column               | type          | notes                                            |
|----------------------|---------------|--------------------------------------------------|
| id                   | uuid pk       | `gen_random_uuid()`                              |
| source_url           | text          | the article link                                 |
| source_title         | text          | article headline                                 |
| source_published_at  | timestamptz   | from the feed (nullable)                         |
| topic                | text          | short AI-derived topic/tag                       |
| linkedin_post        | text          | generated                                        |
| twitter_thread       | jsonb         | array of strings (5–7 posts)                     |
| newsletter_blurb     | text          | generated                                        |
| status               | text          | `pending` / `ready` / `rejected` (default pending)|
| model                | text          | model id used                                    |
| dedup_key            | text unique   | hash of `source_url` (idempotency)               |
| created_at           | timestamptz   | `now()`                                          |
| reviewed_at          | timestamptz   | set when approved/rejected                       |

- **Idempotency:** `upsert` on `dedup_key` (`on_conflict=dedup_key`) so a re-seen article
  never duplicates a row (same fix pattern as project #1's leads upsert).
- **Public view** `content_public`: sanitized, anon-readable, e.g. exposes
  `source_title, topic, status, created_at` (+ the copy once not rejected) for the dashboard.
- **RLS:** anon = read-only on the view; raw `content_items` blocked to anon. n8n writes
  with the service role.
- Index on `(status, created_at desc)` for the dashboard.

See `db/schema.sql`.

---

## 4. Build order (do in sequence)

> ✅ = done · ⏳ = in progress · ⬜ = not started

1. ✅ **Repo + docs scaffold** — CLAUDE.md, this guide, schema, `.env.example`, `.gitignore`,
   README skeleton. Repo initialized + pushed (github.com/karl22puday-eng/ai-content-engine), `.env` ignored.
2. ✅ **Supabase schema** — ran `db/schema.sql`. Verified: `content_public` anon-readable (200),
   raw `content_items` RLS-blocked (200 `[]`).
3. ✅ **`.env` populated** — reused #1's Supabase/Groq/Telegram/n8n keys + `RSS_FEED_URL` (TechCrunch AI).
   Feed verified (20 items); grounding approach confirmed (fetch article body, fallback to summary).
4. ✅ **Slice 1 — the generator (no approval yet):** Schedule/Manual → RSS read → validate +
   dedup → fetch article text → Groq generate pack (strict JSON) → parse/validate → upsert to
   Supabase (`pending`). *Accept:* a real feed item produces one well-formed row; re-run does
   not duplicate; malformed/empty source handled.
   **VERIFIED 2026-06-20:** ran green in n8n; row landed (`pending`, topic + 6-post thread +
   LinkedIn + blurb). Idempotency proven — re-run did NOT duplicate the processed article; the
   pipeline correctly advanced to the next newest unprocessed item (2 rows = 2 unique dedup_keys).
   Behavior by design: one fresh content pack per run (ideal for the one-at-a-time approval in Slice 2).
5. ⏳ **Slice 2 — Telegram approval loop (HITL):** after insert, `Prep Approval` builds a preview
   → `Telegram Approve` (the node's built-in **Send and Wait for Response**, `responseType=approval`,
   `approvalType=double` → Approve/Disapprove) pauses the execution → `IF Approved` branches on
   `$json.data.approved` → `Set Ready` / `Set Rejected` PATCH the row (status + `reviewed_at`).
   *Accept:* tapping Approve flips the row to `ready` exactly once; Disapprove → `rejected`;
   the resume URL is single-use so a re-tap doesn't double-apply.
   **Scope note:** Approve/Reject only (the node's approval mode is two-button). "Regenerate" is a
   deferred enhancement (would re-invoke the generation pipeline for the row).
   *Built; awaiting in-n8n test.*
6. ⬜ **Slice 3 — dashboard:** `frontend/dashboard.html` reads `content_public` via anon key;
   content-calendar / status board (pending / ready / rejected), shows the generated copy.
   *Accept:* live on Pages, reads sanitized view, anon blocked on raw table.
7. ⬜ **Polish:** README (pitch, architecture diagram, demo GIF slot), exported workflow JSON,
   error-trigger workflow, repo About/topics/pin.

Each slice: build smallest working path → add failure handling → test with real data →
export + document → report honestly.

---

## 5. Contracts (JSON shapes between nodes)

**AI generation output (strict JSON the model must return):**
```json
{
  "topic": "string (<= 6 words)",
  "linkedin_post": "string",
  "twitter_thread": ["string", "..."],
  "newsletter_blurb": "string"
}
```
Validation rules enforced in a Code node after the model:
- `twitter_thread` is an array of 5–7 non-empty strings, each ≤ 280 chars.
- all string fields present and non-empty; else mark for regenerate, don't store.

**Supabase upsert row:** the table columns above, `dedup_key = hash(source_url)`,
`status='pending'`, `model='llama-3.3-70b-versatile'`.

**Telegram callback data:** encode `action:row_id` (e.g. `approve:<uuid>`) in
`callback_data` so the resume branch knows what to do and to which row.

---

## 6. Open decisions / notes

- **Publish step** (auto-post to LinkedIn/X) is intentionally **out of scope** for the free
  build (those APIs need app review / paid tiers). "Ready" = approved & queued; the dashboard
  is the deliverable surface. Note this honestly in the README as a deliberate boundary.
- RSS feed choice: **TechCrunch AI feed** (`https://techcrunch.com/category/artificial-intelligence/feed/`),
  stored in `.env` as `RSS_FEED_URL`. Verified: 20 items, but the feed carries only
  `title` + a one-line `description` (no `content:encoded`/full body).
- **Grounding decision (refines step 4's "fetch article text"):** because the feed lacks a
  full body, slice 1 does an HTTP GET on the article `link`, extracts `<p>` paragraphs
  (filter to length > ~60 chars to drop nav/menu boilerplate), and joins them as the
  grounding text. **Fallback:** if the fetch fails or yields too little text, ground on the
  RSS `description`. Verified a real article fetch returns ~8.8k chars of usable body. The
  prompt instructs the model to use ONLY the provided text and not fabricate facts/quotes/stats.
- Reuse the Telegram bot from project #1 but consider a distinct chat or a clear message
  prefix so the two projects' notifications don't get confused.
