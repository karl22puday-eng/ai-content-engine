-- AI Content Engine — Supabase schema
-- Run in the Supabase SQL editor (reuses the existing project from lead-qualification).
-- Idempotent: safe to re-run.

-- ── Table ────────────────────────────────────────────────────────────────────
create table if not exists public.content_items (
  id                  uuid primary key default gen_random_uuid(),
  source_url          text,
  source_title        text,
  source_published_at timestamptz,
  topic               text,
  linkedin_post       text,
  twitter_thread      jsonb,
  newsletter_blurb    text,
  status              text not null default 'pending'
                        check (status in ('pending','ready','rejected')),
  model               text,
  dedup_key           text unique,          -- hash of source_url -> idempotency
  created_at          timestamptz not null default now(),
  reviewed_at         timestamptz
);

-- Dashboard sort/filter: newest first within a status
create index if not exists content_items_status_created_idx
  on public.content_items (status, created_at desc);

-- ── Sanitized public view (anon-readable; no internal-only columns) ───────────
create or replace view public.content_public as
  select
    id,
    source_title,
    source_url,
    topic,
    -- only surface generated copy once it isn't rejected
    case when status <> 'rejected' then linkedin_post   end as linkedin_post,
    case when status <> 'rejected' then twitter_thread   end as twitter_thread,
    case when status <> 'rejected' then newsletter_blurb end as newsletter_blurb,
    status,
    created_at,
    reviewed_at
  from public.content_items;

-- ── Row Level Security ───────────────────────────────────────────────────────
-- Lock the raw table to anon; writes happen via the service role from n8n
-- (service role bypasses RLS). The dashboard reads the view with the anon key.
alter table public.content_items enable row level security;

-- No anon policy on content_items  -> anon SELECT returns nothing (blocked).
-- (n8n uses service_role which bypasses RLS for inserts/updates/upserts.)

-- Allow anon to read the sanitized view.
grant select on public.content_public to anon;

-- Note: a Postgres view runs with the view owner's privileges; granting SELECT
-- on the view to anon lets the dashboard read sanitized rows without exposing the
-- base table. Verify after setup: anon SELECT on content_public works, anon SELECT
-- on content_items returns [] (RLS).
