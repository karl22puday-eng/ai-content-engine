# Generates workflows/01_content_generator.json  (Slice 1: RSS -> dedup -> fetch -> Groq pack -> upsert, no approval yet).
# Re-run after edits:  pwsh ./scripts/build-generator-workflow.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'workflows\01_content_generator.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'workflows') | Out-Null

$SUPA = 'https://sjomutxvmiatruokjgjy.supabase.co'
$RSS  = 'https://techcrunch.com/category/artificial-intelligence/feed/'

# ---------- Code: Prep Candidates (sort newest-first, compute dedup_key, keep top N) ----------
$jsPrep = @'
// RSS Read emits one item per feed entry. Normalize, sort newest-first, hash the link for dedup.
const N = 5;
function cyrb53(str, seed = 0) {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
  for (let i = 0, ch; i < str.length; i++) {
    ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
}
const s = v => (v == null ? '' : String(v)).trim();
const rows = $input.all().map(i => i.json).map(j => {
  const url = s(j.link || j.guid || j.id);
  const d = j.isoDate || j.pubDate || null;
  let published = null;
  try { if (d) published = new Date(d).toISOString(); } catch (e) { published = null; }
  return {
    source_url: url,
    source_title: s(j.title),
    source_published_at: published,
    description: s(j.contentSnippet || j.content || j.summary || ''),
    dedup_key: cyrb53(url)
  };
}).filter(r => r.source_url);
rows.sort((a, b) => new Date(b.source_published_at || 0) - new Date(a.source_published_at || 0));
return rows.slice(0, N).map(json => ({ json }));
'@

# ---------- Code: Check Exists (normalize RPC + re-align candidate fields by index) ----------
$jsCheckExists = @'
// Dedup Check (HTTP, per item) returns the content_exists RPC result; re-attach the candidate
// fields from Prep Candidates by index (n8n preserves item order through the HTTP node).
const resp = $input.all();
const cands = $('Prep Candidates').all();
return resp.map((it, idx) => {
  const r = it.json;
  const row = Array.isArray(r) ? r[0] : r;
  const found = !!(row && (row.found === true || row.found === 'true'));
  const cand = (cands[idx] && cands[idx].json) || {};
  return { json: { ...cand, found } };
});
'@

# ---------- Code: Extract Article Text (paragraphs, with RSS-summary fallback) ----------
$jsExtract = @'
// Fetch Article (HTTP) returned the page HTML in .data; pull <p> paragraphs and drop nav/boilerplate.
// Fall back to the RSS summary if the fetch was thin or failed (Fetch node is set to continue on error).
const s = v => (v == null ? '' : String(v)).trim();
const resp = $input.first() ? $input.first().json : {};
const html = s(resp.data || resp.body || '');
const cand = $('Limit to Newest').first().json;
let text = '';
if (html) {
  const paras = html.match(/<p[^>]*>([\s\S]*?)<\/p>/gi) || [];
  text = paras
    .map(p => p.replace(/<[^>]+>/g, ''))
    .map(t => t.replace(/&#?[a-z0-9]+;/gi, ' '))
    .map(t => t.replace(/\s+/g, ' ').trim())
    .filter(t => t.length > 60)
    .join('\n\n');
}
if (text.length < 200) text = cand.description || text;   // fallback to feed summary
text = text.slice(0, 6000);                               // cap grounding size
return [{ json: { ...cand, article_text: text } }];
'@

# ---------- Code: Assemble Prompt (content-pack generation, grounded) ----------
$jsAssemble = @'
const s = v => (v == null ? '' : String(v)).trim();
const j = $json;
const systemPrompt =
  'You are a senior content strategist for Xenogliph, an AI automation and workflow consultancy. ' +
  'Repurpose the SOURCE article into a social content pack in Xenoglyph-style voice: practical, ' +
  'technical but accessible, no hype, genuinely useful to founders and operators. ' +
  'Use ONLY facts present in the SOURCE; do NOT invent statistics, quotes, names, or details. ' +
  'Return STRICT JSON only (no prose, no markdown) with exactly these keys: ' +
  '{"topic": string (<=6 words), ' +
  '"linkedin_post": string (120-200 words, at most 2 emojis, ends with a question), ' +
  '"twitter_thread": array of 5 to 7 strings (each <=270 chars; first is a strong hook; last has a call to action), ' +
  '"newsletter_blurb": string (2-3 sentences)}.';
const userPrompt =
  'SOURCE TITLE: ' + s(j.source_title) + '\n' +
  'SOURCE URL: ' + s(j.source_url) + '\n\n' +
  'SOURCE TEXT:\n' + s(j.article_text);
return [{ json: { systemPrompt, userPrompt, source_url: j.source_url, source_title: j.source_title,
  source_published_at: j.source_published_at || null, dedup_key: j.dedup_key } }];
'@

# ---------- Code: Parse Pack (parse + validate model JSON, build row) ----------
$jsParse = @'
const src = $('Assemble Prompt').first().json;
const s = v => (v == null ? '' : String(v)).trim();
let ai = null;
try { ai = JSON.parse($json.choices[0].message.content); } catch (e) { ai = null; }
function validPack(p) {
  if (!p) return false;
  if (!s(p.topic) || !s(p.linkedin_post) || !s(p.newsletter_blurb)) return false;
  if (!Array.isArray(p.twitter_thread)) return false;
  return p.twitter_thread.map(s).filter(Boolean).length >= 3;
}
if (!validPack(ai)) throw new Error('AI returned an invalid content pack (JSON shape check failed)');
const thread = ai.twitter_thread.map(s).filter(Boolean).slice(0, 7);
return [{ json: {
  source_url: src.source_url,
  source_title: src.source_title,
  source_published_at: src.source_published_at || null,
  topic: s(ai.topic),
  linkedin_post: s(ai.linkedin_post),
  twitter_thread: thread,
  newsletter_blurb: s(ai.newsletter_blurb),
  status: 'pending',
  model: 'llama-3.3-70b-versatile',
  dedup_key: src.dedup_key
}}];
'@

# ---------- Code: Prep Approval (normalize inserted row + build the Telegram preview) ----------
$jsPrepApproval = @'
// Insert Content returned the upserted row (representation). Normalize and build a preview message.
const items = $input.all();
let row = items[0] ? items[0].json : {};
if (Array.isArray(row)) row = row[0] || {};
const s = v => (v == null ? '' : String(v));
const thread = Array.isArray(row.twitter_thread) ? row.twitter_thread : [];
let preview =
  'NEW CONTENT PACK -- approve to publish\n\n' +
  'Topic: ' + s(row.topic) + '\n' +
  'Source: ' + s(row.source_title) + '\n\n' +
  'LINKEDIN:\n' + s(row.linkedin_post) + '\n\n' +
  'THREAD (' + thread.length + ' posts):\n' + thread.map((t, i) => (i + 1) + '. ' + s(t)).join('\n') + '\n\n' +
  'NEWSLETTER:\n' + s(row.newsletter_blurb);
if (preview.length > 3900) preview = preview.slice(0, 3900) + '\n...';   // Telegram 4096-char limit
return [{ json: { id: row.id, source_title: s(row.source_title), preview } }];
'@

# ---------- expression bodies ----------
$dedupBody  = '={{ JSON.stringify({ p_key: $json.dedup_key }) }}'
$readyUrl   = '={{ "' + $SUPA + '/rest/v1/content_items?id=eq." + $(''Prep Approval'').first().json.id }}'
$readyBody  = '={{ JSON.stringify({ status: "ready", reviewed_at: $now.toISO() }) }}'
$rejectBody = '={{ JSON.stringify({ status: "rejected", reviewed_at: $now.toISO() }) }}'
$groqBody   = '={{ JSON.stringify({ model: "llama-3.3-70b-versatile", temperature: 0.4, response_format: { type: "json_object" }, messages: [ { role: "system", content: $json.systemPrompt }, { role: "user", content: $json.userPrompt } ] }) }}'
$insertBody = '={{ JSON.stringify({ source_url: $json.source_url, source_title: $json.source_title, source_published_at: $json.source_published_at, topic: $json.topic, linkedin_post: $json.linkedin_post, twitter_thread: $json.twitter_thread, newsletter_blurb: $json.newsletter_blurb, status: $json.status, model: $json.model, dedup_key: $json.dedup_key }) }}'

# ---------- nodes ----------
$nodes = @(
  [ordered]@{ parameters=[ordered]@{}; id='n-manual'; name='Manual Trigger';
    type='n8n-nodes-base.manualTrigger'; typeVersion=1; position=@(220,260) },

  [ordered]@{ parameters=[ordered]@{ rule=[ordered]@{ interval=@( [ordered]@{ field='hours'; hoursInterval=6 } ) } };
    id='n-schedule'; name='Schedule Trigger'; type='n8n-nodes-base.scheduleTrigger'; typeVersion=1.2; position=@(220,460) },

  [ordered]@{ parameters=[ordered]@{ url=$RSS; options=@{} };
    id='n-rss'; name='RSS Read'; type='n8n-nodes-base.rssFeedRead'; typeVersion=1.1; position=@(440,360) },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsPrep };
    id='n-prep'; name='Prep Candidates'; type='n8n-nodes-base.code'; typeVersion=2; position=@(660,360) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url=($SUPA + '/rest/v1/rpc/content_exists');
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendBody=$true; specifyBody='json'; jsonBody=$dedupBody; options=@{} };
    id='n-dedup'; name='Dedup Check'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(880,360);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsCheckExists };
    id='n-checkexists'; name='Check Exists'; type='n8n-nodes-base.code'; typeVersion=2; position=@(1100,360) },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-new'; leftValue='={{ $json.found }}'; rightValue=$false;
          operator=[ordered]@{ type='boolean'; operation='false'; singleValue=$true } } );
        combinator='and' } };
    id='n-filter'; name='Filter New'; type='n8n-nodes-base.filter'; typeVersion=2; position=@(1320,360) },

  [ordered]@{ parameters=[ordered]@{ maxItems=1; keep='firstItems' };
    id='n-limit'; name='Limit to Newest'; type='n8n-nodes-base.limit'; typeVersion=1; position=@(1540,360) },

  [ordered]@{ parameters=[ordered]@{ method='GET'; url='={{ $json.source_url }}';
        sendHeaders=$true; headerParameters=@{ parameters=@(
          [ordered]@{ name='User-Agent'; value='Mozilla/5.0 (compatible; XenoglyphBot/1.0)' } ) };
        options=[ordered]@{ response=[ordered]@{ response=[ordered]@{ responseFormat='text'; outputPropertyName='data' } } } };
    id='n-fetch'; name='Fetch Article'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(1760,360);
    retryOnFail=$true; maxTries=2; waitBetweenTries=1500; onError='continueRegularOutput' },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsExtract };
    id='n-extract'; name='Extract Article Text'; type='n8n-nodes-base.code'; typeVersion=2; position=@(1980,360) },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsAssemble };
    id='n-assemble'; name='Assemble Prompt'; type='n8n-nodes-base.code'; typeVersion=2; position=@(2200,360) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url='https://api.groq.com/openai/v1/chat/completions';
        authentication='genericCredentialType'; genericAuthType='httpHeaderAuth';
        sendBody=$true; specifyBody='json'; jsonBody=$groqBody; options=@{} };
    id='n-groq'; name='Groq Generate'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(2420,360);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsParse };
    id='n-parse'; name='Parse Pack'; type='n8n-nodes-base.code'; typeVersion=2; position=@(2640,360) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url=($SUPA + '/rest/v1/content_items?on_conflict=dedup_key');
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendHeaders=$true; headerParameters=@{ parameters=@(
          [ordered]@{ name='Prefer'; value='resolution=merge-duplicates,return=representation' } ) };
        sendBody=$true; specifyBody='json'; jsonBody=$insertBody; options=@{} };
    id='n-insert'; name='Insert Content'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(2860,360);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  # ----- Slice 2: human-in-the-loop approval -----
  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsPrepApproval };
    id='n-prepapproval'; name='Prep Approval'; type='n8n-nodes-base.code'; typeVersion=2; position=@(3080,360) },

  [ordered]@{ parameters=[ordered]@{ operation='sendAndWait'; chatId='7237369464';
        message='={{ $json.preview }}'; responseType='approval';
        approvalOptions=[ordered]@{ values=[ordered]@{ approvalType='double' } }; options=@{} };
    id='n-approve'; name='Telegram Approve'; type='n8n-nodes-base.telegram'; typeVersion=1.2; position=@(3300,360);
    webhookId='content-approval' },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-approved'; leftValue='={{ $json.data.approved }}'; rightValue=$true;
          operator=[ordered]@{ type='boolean'; operation='true'; singleValue=$true } } );
        combinator='and' } };
    id='n-ifapproved'; name='IF Approved'; type='n8n-nodes-base.if'; typeVersion=2; position=@(3520,360) },

  [ordered]@{ parameters=[ordered]@{ method='PATCH'; url=$readyUrl;
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendHeaders=$true; headerParameters=@{ parameters=@(
          [ordered]@{ name='Prefer'; value='return=minimal' } ) };
        sendBody=$true; specifyBody='json'; jsonBody=$readyBody; options=@{} };
    id='n-setready'; name='Set Ready'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(3740,260);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ method='PATCH'; url=$readyUrl;
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendHeaders=$true; headerParameters=@{ parameters=@(
          [ordered]@{ name='Prefer'; value='return=minimal' } ) };
        sendBody=$true; specifyBody='json'; jsonBody=$rejectBody; options=@{} };
    id='n-setrejected'; name='Set Rejected'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(3740,460);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 }
)

# ---------- connections ----------
function One($to) { return @{ main = ,(,([ordered]@{ node=$to; type='main'; index=0 })) } }
$connections = [ordered]@{
  'Manual Trigger'       = One 'RSS Read'
  'Schedule Trigger'     = One 'RSS Read'
  'RSS Read'             = One 'Prep Candidates'
  'Prep Candidates'      = One 'Dedup Check'
  'Dedup Check'          = One 'Check Exists'
  'Check Exists'         = One 'Filter New'
  'Filter New'           = One 'Limit to Newest'
  'Limit to Newest'      = One 'Fetch Article'
  'Fetch Article'        = One 'Extract Article Text'
  'Extract Article Text' = One 'Assemble Prompt'
  'Assemble Prompt'      = One 'Groq Generate'
  'Groq Generate'        = One 'Parse Pack'
  'Parse Pack'           = One 'Insert Content'
  # Slice 2: after storing the pending pack, ask a human to approve via Telegram, then set status.
  'Insert Content'       = One 'Prep Approval'
  'Prep Approval'        = One 'Telegram Approve'
  'Telegram Approve'     = One 'IF Approved'
  'IF Approved'          = @{ main = @(
                              (,([ordered]@{ node='Set Ready';    type='main'; index=0 })),
                              (,([ordered]@{ node='Set Rejected'; type='main'; index=0 }))
                            ) }
}

$workflow = [ordered]@{
  name='01 Content Generator'; nodes=$nodes; connections=$connections;
  active=$false; settings=@{ executionOrder='v1' }
}

$json = $workflow | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($out, $json)
Write-Output "Wrote $out"
$null = Get-Content $out -Raw | ConvertFrom-Json
Write-Output "Valid JSON. Nodes: $($nodes.Count)"
