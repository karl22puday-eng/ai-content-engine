<h1 align="center">AI Content Engine</h1>

<p align="center">
  <em>Autonomous content repurposing with a human-in-the-loop approval gate.</em><br/>
  AI/automation news in → on-brand LinkedIn post + X thread + newsletter blurb out →
  one Telegram tap to approve.
</p>

<p align="center">
  <img alt="n8n" src="https://img.shields.io/badge/n8n-workflow-EA4B71" />
  <img alt="Groq" src="https://img.shields.io/badge/Groq-llama--3.3--70b-000" />
  <img alt="Supabase" src="https://img.shields.io/badge/Supabase-Postgres-3ECF8E" />
  <img alt="Telegram" src="https://img.shields.io/badge/Telegram-HITL_approval-2AABEE" />
</p>

<!-- Demo GIF slot — add once recorded: assets/demo.gif -->

---

## What it does

A scheduled n8n workflow reads AI/automation news, and for each fresh article an LLM
generates a **content pack** — a LinkedIn post, a 5–7 post X/Twitter thread, and a
newsletter blurb — all in a consistent brand voice. Each pack is stored as `pending` and
pushed to **Telegram with inline buttons**: **Approve · Reject · Regenerate**. A `Wait`
node pauses the run until a human taps a button; the choice updates the record and (on
approve) marks it publish-ready. A public dashboard shows the content calendar.

**Why this design:** it demonstrates *controlled* autonomy — scheduled generation that
never marks anything publish-ready without an explicit human decision — a different class
of system from a fully-autonomous pipeline.

## Architecture

```
Schedule / RSS (AI & automation news)
   -> Validate + dedup (skip already-processed URLs)
   -> Fetch article text (grounding)
   -> Groq llama-3.3-70b  ->  content pack (strict JSON)
   -> Validate / parse (retry on malformed)
   -> Supabase upsert  (status = pending)        [idempotent on source-URL hash]
   -> Telegram preview + [Approve][Reject][Regenerate]
   -> Wait for callback
        Approve    -> status = ready
        Reject     -> status = rejected
        Regenerate -> re-generate -> new preview
   -> Public content-calendar dashboard (read-only, sanitized view)
```

## Stack (100% free, no card)

| Concern        | Tool                                |
|----------------|-------------------------------------|
| Orchestration  | n8n Cloud                           |
| LLM            | Groq · `llama-3.3-70b-versatile`    |
| Database       | Supabase (Postgres + RLS)           |
| Approval / alerts | Telegram bot (inline keyboards)  |
| Dashboard host | GitHub Pages (Actions deploy)       |

## Engineering decisions & what I learned

<!-- filled in as we build: idempotent upsert on source-URL hash, structured-output
     validation + regenerate loop, Telegram callback + Wait-node resume for HITL,
     sanitized public view for safe anon reads, deliberate out-of-scope publish step. -->

## Live demo

- **Content dashboard:** https://karl22puday-eng.github.io/ai-content-engine/ &nbsp;<sub>(read-only, sanitized view)</sub>

## Status

Working end to end: RSS → AI content pack → Telegram approval → status flip → dashboard.
See [`docs/BUILD_GUIDE.md`](docs/BUILD_GUIDE.md) for the build order and engineering notes.

---

> Companion to my [AI Lead Qualification & CRM Automation System](https://github.com/karl22puday-eng/ai-lead-qualification-system).
