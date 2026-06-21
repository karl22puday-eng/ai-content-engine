# Demo GIF — Shot Script (AI Content Engine)

> Goal: a recruiter watches one loop and *gets it* — AI generates a content pack from real
> news, a human approves it with one tap in Telegram, and it lands `ready` on the dashboard.
> The story is **controlled autonomy** (the human-in-the-loop gate), so the Telegram tap is the
> hero moment. Output: `assets/demo.gif` (README slot already wired).

---

## Before you record (setup)

1. **Three things visible**, arranged so you can move between them quickly:
   - **n8n** — the `01 Content Generator` workflow open on the canvas.
   - **Telegram** — the `@myleadqualbot` chat open (desktop app or web, in a small window).
   - **Dashboard** — https://karl22puday-eng.github.io/ai-content-engine/ (hard-refresh first).
2. The workflow must be **importable + active/manual-runnable** with creds wired (already is).
3. **Zoom browser to ~110–125%** so the dashboard text is legible in a small GIF.
4. Pick a clean recording region (you'll likely record the whole screen and crop later, since
   you're moving between three apps).

> ⚠️ This generates a **real** content pack row. That's fine — it's marketing copy, not
> sensitive. Optionally clean it up afterward (SQL at the bottom).

---

## Shot list (≈20–25 seconds — keep it tight)

| # | Time | Shot | Action |
|---|---|---|---|
| 1 | 0–3s | **n8n canvas** | Show the workflow, then click **Execute Workflow**. Let a few nodes light up green so it reads as "AI pipeline running." |
| 2 | 3–6s | **Pipeline runs** | Quick beat on the nodes going green through Groq Generate → Insert. Conveys "it fetched news + generated copy." |
| 3 | 6–13s | **Telegram alert** | Cut to Telegram: the **content pack preview** message arrives with **Approve / Disapprove** buttons. Let the copy be readable ~3s — this is the proof the AI wrote real content. |
| 4 | 13–16s | **The tap** | Tap **Approve**. (The hero moment — controlled autonomy.) |
| 5 | 16–20s | **Dashboard** | Switch to the dashboard, hit Refresh (or wait for the 30s auto-refresh). The new pack shows at top, badge **ready** (green). Optionally click a channel tab (LinkedIn / X thread) to show the generated copy. Hold to the end. |

Keep total ≤ 25s. The must-haves are shots 3 (Telegram preview) and 5 (ready on dashboard).
If recording all three apps is fiddly, the minimum viable loop is **Telegram preview → tap
Approve → dashboard shows ready**.

---

## On-screen captions (for the silent GIF — recommended)

Drop these as short overlays so the silent loop tells the story:

| Shot | Caption |
|---|---|
| n8n execute | `1. Scheduled AI pipeline runs` |
| Telegram | `2. AI writes the content pack — grounded in real news` |
| Tap Approve | `3. Human approves with one tap` |
| Dashboard | `4. Published-ready in the CRM dashboard` |

---

## Recording tips (ScreenToGif — free, Windows)

- **Tool:** [ScreenToGif](https://www.screentogif.com/) — record a region, then trim/edit frames.
- **Frame rate:** 15 fps is plenty; keeps the file small.
- **Trim dead air:** delete idle frames between app switches so it feels snappy.
- **File size:** aim **< 5 MB** for inline GitHub render. If over: drop to 10 fps, shrink the
  region, or reduce colors.
- **Loop:** make the first/last frames calm so the loop isn't jarring.
- **Save the source video** (mp4) too — hand it to me and I'll do the optimized conversion
  (I have ffmpeg set up; I produced #1's GIF + MP4 this way).

---

## After recording

Just give me the path to the screen recording (mp4) and I'll:
1. Convert it to an optimized `assets/demo.gif` (< 5 MB, looping) + a small `assets/demo.mp4`.
2. The README demo slot is already in place — I'll wire it and commit.

## Cleanup (optional — remove the demo row)

```sql
-- remove a specific demo pack by its source title, or just leave it (it's only marketing copy)
delete from content_items where source_title ilike '%<part of the title>%';
```
