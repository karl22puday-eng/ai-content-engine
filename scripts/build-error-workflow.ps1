# Generates workflows/02_error_handler.json — a global Error Trigger workflow.
# Set this as the "Error Workflow" in each production workflow's Settings so any failed
# execution fires a Telegram alert with the workflow name, failed node, and a link.
# Re-run after edits:  pwsh ./scripts/build-error-workflow.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'workflows\02_error_handler.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'workflows') | Out-Null

$TG_CHAT = '7237369464'   # same Telegram chat as the generator (or a dedicated alerts chat)

# ---------- Code: Format Alert (defensive — Error Trigger payload shape varies) ----------
$jsFormat = @'
// n8n Error Trigger emits { execution: {...}, workflow: {...} }. Build a readable alert,
// guarding every field so a malformed/partial payload still produces a usable message.
const j = $input.first() ? $input.first().json : {};
const ex = j.execution || {};
const wf = j.workflow || {};
const err = ex.error || {};
const s = v => (v == null ? '' : String(v)).trim();

const lines = [
  '\u{1F6A8} n8n workflow FAILED',
  '',
  'Workflow: ' + (s(wf.name) || 'unknown'),
  'Failed node: ' + (s(ex.lastNodeExecuted) || 'unknown'),
  'Mode: ' + (s(ex.mode) || 'n/a'),
  '',
  'Error: ' + (s(err.message) || s(err.description) || 'no message provided')
];
if (s(ex.url)) { lines.push('', 'Execution: ' + s(ex.url)); }

let text = lines.join('\n');
if (text.length > 3900) text = text.slice(0, 3900) + '\n...';   // Telegram 4096-char limit
return [{ json: { text } }];
'@

# ---------- nodes ----------
$nodes = @(
  [ordered]@{ parameters=[ordered]@{}; id='n-errtrigger'; name='Error Trigger';
    type='n8n-nodes-base.errorTrigger'; typeVersion=1; position=@(360,300) },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsFormat };
    id='n-format'; name='Format Alert'; type='n8n-nodes-base.code'; typeVersion=2; position=@(580,300) },

  [ordered]@{ parameters=[ordered]@{ resource='message'; operation='sendMessage'; chatId=$TG_CHAT;
        text='={{ $json.text }}'; additionalFields=@{} };
    id='n-tgerr'; name='Telegram Error Alert'; type='n8n-nodes-base.telegram'; typeVersion=1.2; position=@(800,300);
    retryOnFail=$true; maxTries=2; waitBetweenTries=1500 }
)

# ---------- connections ----------
function One($to) { return @{ main = ,(,([ordered]@{ node=$to; type='main'; index=0 })) } }
$connections = [ordered]@{
  'Error Trigger' = One 'Format Alert'
  'Format Alert'  = One 'Telegram Error Alert'
}

$workflow = [ordered]@{
  name='02 Error Handler'; nodes=$nodes; connections=$connections;
  active=$false; settings=@{ executionOrder='v1' }
}

$json = $workflow | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($out, $json)
Write-Output "Wrote $out"
$null = Get-Content $out -Raw | ConvertFrom-Json
Write-Output "Valid JSON. Nodes: $($nodes.Count)"
