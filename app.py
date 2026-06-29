import os
import shutil
import zipfile
import tarfile
import requests
import pyotp
import time
import threading
from urllib.parse import urlparse
from fastapi import FastAPI, HTTPException, Form, Cookie, Request
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse

app = FastAPI()

# ---------------------------------------------------------------------------
# Configs — read from HF Secrets (no hardcoded fallbacks for security)
# ---------------------------------------------------------------------------
SECRET_TOKEN  = os.environ.get("STORAGE_PASSWORD")   # portal passcode
TOTP_SECRET   = os.environ.get("TOTP_SECRET")         # base32 2FA seed
totp          = pyotp.TOTP(TOTP_SECRET) if TOTP_SECRET else None
DATA_DIR      = "/media/videos"
JELLYFIN_URL  = "http://127.0.0.1:8096"

if not SECRET_TOKEN or not TOTP_SECRET:
    print("=" * 52)
    print("⚠️  WARNING: STORAGE_PASSWORD or TOTP_SECRET not set!")
    print("   Add them in HF Space → Settings → Repository Secrets.")
    print("=" * 52)

# Read Jellyfin API key from env or auto-generated file
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")
if not JELLYFIN_API_KEY and os.path.exists("/config/downloader_api_key.txt"):
    try:
        with open("/config/downloader_api_key.txt") as f:
            JELLYFIN_API_KEY = f.read().strip()
    except Exception as e:
        print(f"[config] Cannot read downloader_api_key.txt: {e}")

os.makedirs(DATA_DIR, exist_ok=True)

if totp:
    uri = totp.provisioning_uri(name="SpaceStorage", issuer_name="HuggingFace")
    print("=" * 52)
    print("🔐 2FA SETUP (owner-only container logs):")
    print(f"   Manual Key : {TOTP_SECRET}")
    print(f"   Pairing URI: {uri}")
    print("=" * 52)

# ---------------------------------------------------------------------------
# Thread-safe download state
# ---------------------------------------------------------------------------
_dl_lock = threading.Lock()
_current_dl: dict = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}
_cancel_requested = False

# ---------------------------------------------------------------------------
# Brute-force rate limiter (in-memory, per-IP)
# ---------------------------------------------------------------------------
_failed: dict[str, list[float]] = {}
_RL_WINDOW = 300   # 5 minutes
_RL_MAX    = 10    # max attempts per window

COOKIE_MAX_AGE = 7 * 24 * 3600  # 7 days

NO_CACHE = {
    "Cache-Control": "no-cache, no-store, must-revalidate",
    "Pragma": "no-cache",
    "Expires": "0",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def is_authenticated(token: str | None) -> bool:
    if not SECRET_TOKEN:
        return False
    return token == SECRET_TOKEN


def safe_path(filename: str) -> str:
    """Resolve to absolute path and verify it stays inside DATA_DIR (path traversal guard)."""
    resolved = os.path.abspath(os.path.join(DATA_DIR, filename))
    base = os.path.abspath(DATA_DIR)
    # allow exact base or anything under it
    if resolved != base and not resolved.startswith(base + os.sep):
        raise HTTPException(status_code=400, detail="Access denied: path traversal detected")
    return resolved


def validate_url(url: str) -> None:
    """Basic SSRF guard — only allow public http/https URLs."""
    try:
        p = urlparse(url)
    except Exception:
        raise HTTPException(status_code=400, detail="Malformed URL")
    if p.scheme not in ("http", "https"):
        raise HTTPException(status_code=400, detail="Only http/https URLs are allowed")
    host = (p.hostname or "").lower()
    private = ("localhost", "127.", "10.", "172.16.", "172.17.", "172.18.",
                "172.19.", "172.20.", "172.21.", "172.22.", "172.23.",
                "172.24.", "172.25.", "172.26.", "172.27.", "172.28.",
                "172.29.", "172.30.", "172.31.", "192.168.", "169.254.", "::1", "0.")
    if any(host == p or host.startswith(p) for p in private):
        raise HTTPException(status_code=400, detail="Requests to private/internal addresses are not allowed")


def trigger_jellyfin_scan() -> bool:
    if not JELLYFIN_API_KEY:
        print("[scan] JELLYFIN_API_KEY not set — skipping library refresh.")
        return False
    try:
        headers = {
            "X-MediaBrowser-Token": JELLYFIN_API_KEY,
            "X-Emby-Token": JELLYFIN_API_KEY,
            "Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"',
        }
        r = requests.post(
            f"{JELLYFIN_URL}/Library/Refresh?api_key={JELLYFIN_API_KEY}",
            headers=headers,
            timeout=10,
        )
        ok = r.status_code in (200, 204)
        print(f"[scan] Jellyfin refresh {'OK' if ok else f'FAILED ({r.status_code})'}")
        return ok
    except Exception as e:
        print(f"[scan] Cannot reach Jellyfin: {e}")
        return False


def fix_permissions(directory: str) -> None:
    for root, dirs, files in os.walk(directory):
        for d in dirs:
            try:
                os.chmod(os.path.join(root, d), 0o777)
            except Exception:
                pass
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o666)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Shared CSS / design tokens (injected into every page)
# ---------------------------------------------------------------------------
_COMMON_CSS = """
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&family=Fira+Code:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{--bg:radial-gradient(circle at top center,#0f172a 0%,#020617 100%);
      --card:rgba(15,23,42,0.55);--teal:#06b6d4;--indigo:#6366f1;
      --red:#ef4444;--green:#10b981;--txt:#f8fafc;--txt2:#94a3b8;}
*{box-sizing:border-box;}
body{font-family:'Plus Jakarta Sans',sans-serif;background:var(--bg);color:var(--txt);min-height:100vh;margin:0;}
</style>
"""


# =========================================================================
# 1.  HOME — login or dashboard
# =========================================================================
@app.get("/download", response_class=HTMLResponse)
@app.get("/login",    response_class=HTMLResponse)
@app.get("/view",     response_class=HTMLResponse)
@app.get("/delete",   response_class=HTMLResponse)
def get_home(auth_token: str = Cookie(None)):

    # ---- Not logged in: show login form ----
    if not is_authenticated(auth_token):
        totp_field = (
            '<input type="text" name="totp_code" placeholder="6-digit code" maxlength="6" required autocomplete="off">'
            if TOTP_SECRET else
            '<input type="hidden" name="totp_code" value="000000">'
        )
        missing_warn = (
            '<div style="background:rgba(239,68,68,.1);color:#f87171;padding:.8rem;border-radius:8px;'
            'font-size:.75rem;margin-top:1.25rem;border:1px solid rgba(239,68,68,.2);">'
            '⚠️ <b>STORAGE_PASSWORD</b> not set — login disabled.</div>'
            if not SECRET_TOKEN else ""
        )
        html = f"""<!DOCTYPE html>
<html>
<head><title>Secure Storage Login</title>{_COMMON_CSS}
<style>
body{{display:flex;align-items:center;justify-content:center;padding:1rem;}}
.card{{background:var(--card);backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.08);
       padding:2.5rem;border-radius:16px;width:100%;max-width:360px;text-align:center;
       box-shadow:0 10px 40px rgba(0,0,0,.5);}}
h2{{background:linear-gradient(135deg,#06b6d4,#6366f1);-webkit-background-clip:text;
    -webkit-text-fill-color:transparent;margin:0 0 2rem;font-size:1.75rem;font-weight:700;}}
.fg{{margin-bottom:1.25rem;text-align:left;}}
label{{font-size:.8rem;color:var(--txt2);margin-bottom:.4rem;display:block;font-weight:500;}}
input{{width:100%;padding:.8rem 1rem;background:rgba(15,23,42,.6);border:1px solid rgba(255,255,255,.1);
       border-radius:8px;color:white;font-size:.9rem;font-family:inherit;transition:all .2s;}}
input:focus{{outline:none;border-color:var(--teal);box-shadow:0 0 10px rgba(6,182,212,.2);background:rgba(15,23,42,.85);}}
.submit{{background:linear-gradient(135deg,var(--teal),#0891b2);color:#0f172a;border:none;padding:.85rem;
         border-radius:8px;font-weight:700;cursor:pointer;width:100%;transition:all .25s;
         font-size:.95rem;margin-top:1rem;box-shadow:0 4px 14px rgba(6,182,212,.3);font-family:inherit;}}
.submit:hover{{transform:translateY(-2px);box-shadow:0 6px 20px rgba(6,182,212,.5);}}
.note{{margin-top:1.5rem;padding-top:1.25rem;border-top:1px dashed rgba(255,255,255,.06);
       font-size:.75rem;color:#64748b;line-height:1.4;}}
</style>
</head>
<body>
<div class="card">
  <h2>📁 Storage Portal</h2>
  <form action="/login" method="post">
    <div class="fg"><label>Username</label>
      <input type="text" name="username" placeholder="admin" required autocomplete="off"></div>
    <div class="fg"><label>Passcode</label>
      <input type="password" name="password" placeholder="••••••••" required></div>
    <div class="fg"><label>2FA Code</label>{totp_field}</div>
    <button type="submit" class="submit">Verify &amp; Unlock</button>
  </form>
  <div class="note">🔒 Setup keys are in container logs only — never sent to the browser.</div>
  {missing_warn}
</div>
</body>
</html>"""
        return HTMLResponse(content=html, headers=NO_CACHE)

    # ---- Logged in: build dashboard ----
    files: list[str] = []
    for root, _, filenames in os.walk(DATA_DIR):
        for fname in filenames:
            files.append(os.path.relpath(os.path.join(root, fname), DATA_DIR))

    total_bytes = 0
    file_rows = ""
    icon_map = {"mkv": "🎬", "mp4": "🎬", "avi": "🎬", "m4v": "🎬", "mov": "🎬",
                "zip": "🗜️", "tar": "🗜️", "gz": "🗜️", "mkv": "🎬"}
    for fname in sorted(files):
        fpath = os.path.join(DATA_DIR, fname)
        try:
            sz = os.path.getsize(fpath)
            total_bytes += sz
            sz_mb = sz / (1024 * 1024)
            ext = os.path.splitext(fname)[1].lstrip(".").lower()
            icon = icon_map.get(ext, "📄")
            safe_f = fname.replace("'", "\\'")
            file_rows += f"""
<li class="fi" data-name="{fname.lower()}">
  <div class="fd">
    <span class="ficon">{icon}</span>
    <div class="ft">
      <a class="fl" href="/view/{fname}" target="_blank" title="{fname}">{fname}</a>
      <span class="fm">{sz_mb:.2f} MB</span>
    </div>
  </div>
  <div class="fa">
    <button class="ba ba-r" onclick="renameFile('{safe_f}')">Rename</button>
    <a class="ba ba-d" href="/delete/{fname}"
       onclick="return confirm('Delete {fname}?')">Delete</a>
  </div>
</li>"""
        except Exception:
            pass

    if not files:
        file_rows = "<li class='fi empty'>No media files in /media/videos yet.</li>"

    total_display = (f"{total_bytes/1024**3:.2f} GB" if total_bytes >= 1024**3
                     else f"{total_bytes/1024**2:.1f} MB")
    jf_warn = (
        '<div style="background:rgba(239,68,68,.1);color:#f87171;padding:1rem;border-radius:12px;'
        'border:1px solid rgba(239,68,68,.2);font-size:.85rem;margin-bottom:1.5rem;line-height:1.4;">'
        '⚠️ <b>JELLYFIN_API_KEY</b> not set — downloads won\'t auto-sync with Jellyfin.</div>'
        if not JELLYFIN_API_KEY else ""
    )

    # NOTE: SECRET_TOKEN is intentionally NOT embedded in the HTML.
    # The curl command uses a placeholder — user supplies their own token from HF Secrets.
    html = f"""<!DOCTYPE html>
<html>
<head>
<title>Space Storage Explorer</title>{_COMMON_CSS}
<style>
body{{padding:2rem;}}
.container{{max-width:1200px;margin:0 auto;}}
header{{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:1rem;
        background:var(--card);backdrop-filter:blur(12px);padding:1.5rem 2rem;border-radius:16px;
        border:1px solid rgba(255,255,255,.08);box-shadow:0 4px 30px rgba(0,0,0,.4);margin-bottom:2rem;}}
h1{{font-size:1.4rem;font-weight:700;background:linear-gradient(135deg,var(--teal),var(--indigo));
    -webkit-background-clip:text;-webkit-text-fill-color:transparent;margin:0;}}
.stats{{display:flex;gap:.75rem;flex-wrap:wrap;}}
.badge{{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.07);
        padding:.3rem .75rem;border-radius:20px;font-size:.8rem;color:var(--txt2);}}
.hdr-btns{{display:flex;gap:.75rem;flex-wrap:wrap;}}
.btn{{font-family:inherit;font-size:.85rem;font-weight:600;padding:.6rem 1.2rem;border-radius:8px;
      border:none;cursor:pointer;transition:all .25s cubic-bezier(.4,0,.2,1);
      display:inline-flex;align-items:center;gap:.5rem;text-decoration:none;}}
.btn-p{{background:linear-gradient(135deg,var(--teal),#0891b2);color:#0f172a;
        box-shadow:0 4px 14px rgba(6,182,212,.3);}}
.btn-p:hover{{transform:translateY(-2px);box-shadow:0 6px 20px rgba(6,182,212,.5);}}
.btn-d{{background:linear-gradient(135deg,var(--red),#dc2626);color:white;
        box-shadow:0 4px 14px rgba(239,68,68,.3);}}
.btn-d:hover{{transform:translateY(-2px);box-shadow:0 6px 20px rgba(239,68,68,.5);}}
.btn-s{{background:rgba(255,255,255,.05);color:var(--txt);border:1px solid rgba(255,255,255,.1);}}
.btn-s:hover{{background:rgba(255,255,255,.1);transform:translateY(-2px);}}
.grid{{display:grid;grid-template-columns:4fr 5fr;gap:2rem;}}
@media(max-width:900px){{.grid{{grid-template-columns:1fr;}}body{{padding:1rem;}}}}
.panel{{background:var(--card);backdrop-filter:blur(12px);border:1px solid rgba(255,255,255,.06);
        border-radius:16px;padding:2rem;box-shadow:0 8px 32px rgba(0,0,0,.3);
        display:flex;flex-direction:column;gap:1.5rem;}}
h3{{font-size:1.1rem;font-weight:600;margin:0;
    background:linear-gradient(135deg,#a855f7,var(--indigo));
    -webkit-background-clip:text;-webkit-text-fill-color:transparent;
    display:flex;align-items:center;gap:.5rem;}}
.fg{{display:flex;flex-direction:column;gap:.5rem;margin-bottom:.5rem;}}
.fg label{{font-size:.8rem;color:var(--txt2);font-weight:500;}}
input[type=text],input[type=password]{{background:rgba(15,23,42,.6);border:1px solid rgba(255,255,255,.1);
  border-radius:8px;padding:.8rem 1rem;color:var(--txt);font-family:inherit;font-size:.9rem;
  transition:all .2s;width:100%;}}
input[type=text]:focus,input[type=password]:focus{{outline:none;border-color:var(--teal);
  box-shadow:0 0 10px rgba(6,182,212,.2);background:rgba(15,23,42,.85);}}
/* progress */
.prog-wrap{{background:rgba(15,23,42,.85);border-radius:12px;padding:1.25rem;
            border:1px solid rgba(6,182,212,.15);display:none;margin-top:1.5rem;}}
.prog-hdr{{display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem;}}
.prog-title{{font-size:.85rem;font-weight:600;color:var(--teal);
             white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:70%;}}
.bar-bg{{background:rgba(255,255,255,.05);height:8px;border-radius:4px;
         overflow:hidden;margin-bottom:.75rem;}}
.bar-fill{{background:linear-gradient(90deg,var(--teal),var(--indigo));height:100%;width:0%;transition:width .3s;}}
.prog-ftr{{display:flex;justify-content:space-between;font-size:.8rem;color:var(--txt2);}}
.btn-cancel{{background:rgba(239,68,68,.15);color:#ef4444;border:1px solid rgba(239,68,68,.3);
             padding:.3rem .75rem;font-size:.75rem;border-radius:6px;cursor:pointer;
             font-weight:600;transition:all .2s;font-family:inherit;}}
.btn-cancel:hover{{background:var(--red);color:white;}}
/* code box */
.code-section{{border-top:1px solid rgba(255,255,255,.06);padding-top:1.5rem;
               display:flex;flex-direction:column;gap:.75rem;}}
.code-wrap{{position:relative;}}
.code-box{{background:#05070c!important;padding:1rem;border-radius:8px;
           font-family:'Fira Code',monospace;font-size:.8rem;color:#38bdf8;
           overflow-x:auto;white-space:nowrap;border:1px solid rgba(255,255,255,.06);
           width:100%;padding-right:4.5rem;}}
.btn-copy{{position:absolute;right:.5rem;top:50%;transform:translateY(-50%);
           background:var(--indigo);color:white;border:none;padding:.35rem .8rem;
           border-radius:6px;cursor:pointer;font-size:.75rem;font-weight:600;
           transition:all .2s;font-family:inherit;}}
.btn-copy:hover{{background:#4f46e5;box-shadow:0 0 10px rgba(99,102,241,.4);}}
/* file list */
.search{{width:100%;padding:.6rem 1rem;background:rgba(15,23,42,.6);
         border:1px solid rgba(255,255,255,.1);border-radius:8px;color:var(--txt);
         font-family:inherit;font-size:.85rem;}}
.search:focus{{outline:none;border-color:var(--teal);}}
ul.flist{{list-style:none;padding:0;margin:0;max-height:500px;overflow-y:auto;
          display:flex;flex-direction:column;gap:.6rem;}}
ul.flist::-webkit-scrollbar{{width:6px;}}
ul.flist::-webkit-scrollbar-thumb{{background:rgba(255,255,255,.1);border-radius:4px;}}
ul.flist::-webkit-scrollbar-thumb:hover{{background:rgba(255,255,255,.2);}}
li.fi{{display:flex;justify-content:space-between;align-items:center;padding:.9rem 1.2rem;
       background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.04);
       border-radius:10px;transition:all .2s;}}
li.fi:hover{{background:rgba(255,255,255,.05);border-color:rgba(99,102,241,.15);transform:translateX(4px);}}
.fd{{display:flex;align-items:center;gap:.75rem;overflow:hidden;max-width:60%;}}
.ficon{{font-size:1.25rem;flex-shrink:0;}}
.ft{{display:flex;flex-direction:column;overflow:hidden;}}
.fl{{color:var(--teal);text-decoration:none;font-weight:600;font-size:.85rem;
     white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:color .2s;}}
.fl:hover{{color:#22d3ee;text-decoration:underline;}}
.fm{{color:var(--txt2);font-size:.75rem;margin-top:.15rem;}}
.fa{{display:flex;gap:.4rem;flex-shrink:0;}}
.ba{{padding:.35rem .7rem;border-radius:6px;font-size:.75rem;font-weight:600;cursor:pointer;
     border:none;transition:all .2s;text-decoration:none;display:inline-flex;align-items:center;
     font-family:inherit;}}
.ba-r{{background:rgba(99,102,241,.1);color:#818cf8;border:1px solid rgba(99,102,241,.2);}}
.ba-r:hover{{background:var(--indigo);color:white;}}
.ba-d{{background:rgba(239,68,68,.1);color:#f87171;border:1px solid rgba(239,68,68,.2);}}
.ba-d:hover{{background:var(--red);color:white;}}
li.empty{{justify-content:center;color:var(--txt2);font-style:italic;padding:2rem;
          background:transparent;border:1px dashed rgba(255,255,255,.08);}}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>📁 Media Storage Explorer</h1>
    <div class="stats">
      <span class="badge">📂 {len(files)} files</span>
      <span class="badge">💾 {total_display}</span>
    </div>
    <div class="hdr-btns">
      <a href="/scan"  class="btn btn-s">🔄 Rescan Library</a>
      <a href="/chat/" class="btn btn-s">💬 Element Web</a>
      <a href="/"      class="btn btn-p">🎬 Jellyfin</a>
      <a href="/logout" class="btn btn-d">Log Out</a>
    </div>
  </header>

  {jf_warn}

  <div class="grid">
    <!-- Left: Downloader -->
    <div class="panel">
      <div>
        <h3>📥 Download File from Web</h3>
        <form id="dl-form" style="margin-top:1rem;display:flex;flex-direction:column;gap:1rem;">
          <div class="fg"><label>Direct Source URL</label>
            <input type="text" name="url" placeholder="https://example.com/movie.mp4" required autocomplete="off"></div>
          <div class="fg"><label>Save As Filename</label>
            <input type="text" name="filename" placeholder="movie.mp4  or  ShowName/ep01.mkv" required autocomplete="off"></div>
          <button type="submit" class="btn btn-p" id="dl-btn" style="width:100%;margin-top:.5rem;">
            ⬇️ Download to Space
          </button>
        </form>

        <!-- Progress bar (hidden until download starts) -->
        <div class="prog-wrap" id="prog-wrap">
          <div class="prog-hdr">
            <div class="prog-title" id="prog-title">Initializing...</div>
            <button class="btn-cancel" id="cancel-btn">✕ Cancel</button>
          </div>
          <div class="bar-bg"><div class="bar-fill" id="prog-bar"></div></div>
          <div class="prog-ftr">
            <span id="prog-speed">Connecting...</span>
            <span id="prog-pct" style="font-weight:700;color:var(--teal);">0%</span>
          </div>
        </div>
      </div>

      <!-- Curl snippet — token is NOT pre-filled; user pastes from HF Secrets -->
      <div class="code-section">
        <h3>💻 Automate with Curl</h3>
        <p style="font-size:.8rem;color:var(--txt2);margin:0 0 .5rem;line-height:1.4;">
          Run from any terminal (no 2FA required — token auth only).<br>
          Replace <b>YOUR_TOKEN</b> with your <code>STORAGE_PASSWORD</code> secret.
        </p>
        <div class="code-wrap">
          <div class="code-box" id="curl-box">Loading...</div>
          <button class="btn-copy" id="copy-btn">Copy</button>
        </div>
        <div style="font-size:.75rem;color:#64748b;margin-top:.25rem;">
          💡 Also replace <b>YOUR_URL</b> and <b>YOUR_FILENAME</b>.
        </div>
      </div>
    </div>

    <!-- Right: File library -->
    <div class="panel">
      <h3>🎬 Video Library</h3>
      <input type="text" class="search" id="search" placeholder="🔍 Search files...">
      <ul class="flist" id="flist">
        {file_rows}
      </ul>
    </div>
  </div>
</div>
<script>
// Curl command — SECRET_TOKEN is NOT embedded in HTML (security).
// User must fill in their own token from HF Secrets.
document.addEventListener("DOMContentLoaded", () => {{
  const host = window.location.origin;
  const cmd = `curl -X POST "${{host}}/download?token=YOUR_TOKEN" \\
  -d "url=YOUR_URL&filename=YOUR_FILENAME"`;
  document.getElementById("curl-box").innerText = cmd;

  document.getElementById("copy-btn").addEventListener("click", () => {{
    navigator.clipboard.writeText(cmd);
    const b = document.getElementById("copy-btn");
    b.innerText = "Copied!";
    setTimeout(() => b.innerText = "Copy", 1500);
  }});
}});

// Live search
document.getElementById("search").addEventListener("input", function() {{
  const q = this.value.toLowerCase();
  document.querySelectorAll("#flist li.fi:not(.empty)").forEach(li => {{
    li.style.display = (li.dataset.name || "").includes(q) ? "" : "none";
  }});
}});

// Rename dialog
function renameFile(fname) {{
  const n = prompt(`Rename:\\n"${{fname}}"\\n\\nNew filename (include extension):`, fname);
  if (n && n.trim() && n.trim() !== fname)
    window.location.href = `/rename?old=${{encodeURIComponent(fname)}}&new=${{encodeURIComponent(n.trim())}}`;
}}

// Cancel download
document.getElementById("cancel-btn").addEventListener("click", async () => {{
  if (!confirm("Cancel the active download?")) return;
  try {{ await fetch("/download/cancel", {{ method: "POST" }}); }}
  catch(e) {{ console.error(e); }}
}});

// Download form with progress polling
let poll = null;
document.getElementById("dl-form").addEventListener("submit", async (e) => {{
  e.preventDefault();
  const fd   = new FormData(e.target);
  const pw   = document.getElementById("prog-wrap"),
        pb   = document.getElementById("prog-bar"),
        pp   = document.getElementById("prog-pct"),
        ps   = document.getElementById("prog-speed"),
        pt   = document.getElementById("prog-title"),
        btn  = document.getElementById("dl-btn");

  btn.disabled = true;
  btn.innerText = "Processing...";
  pw.style.display = "block";
  pb.style.width = "0%";
  pp.innerText = "0%";
  ps.innerText = "Initializing...";
  pt.innerText = "Downloading: " + fd.get("filename");

  poll = setInterval(async () => {{
    try {{
      const r = await fetch("/progress");
      const d = await r.json();
      if (d.status === "downloading") {{
        pb.style.width = d.progress + "%";
        pp.innerText   = d.progress + "%";
        ps.innerText   = "Speed: " + d.speed;
      }} else if (d.status === "extracting") {{
        pb.style.width = "95%";
        pp.innerText   = "95%";
        ps.innerText   = "Extracting...";
      }}
    }} catch(e) {{ console.error(e); }}
  }}, 1000);

  try {{
    const resp = await fetch("/download", {{ method: "POST", body: new URLSearchParams(fd) }});
    clearInterval(poll);
    if (resp.ok) {{
      ps.innerText = "Syncing with Jellyfin...";
      pb.style.width = "100%";
      pp.innerText = "100%";
      setTimeout(() => window.location.reload(), 1200);
    }} else {{
      const err = await resp.json().catch(() => ({{ detail: "Unknown error" }}));
      alert("Error: " + err.detail);
      reset();
    }}
  }} catch(e) {{
    clearInterval(poll);
    alert("Connection error: " + e.message);
    reset();
  }}

  function reset() {{
    btn.disabled = false;
    btn.innerText = "⬇️ Download to Space";
    pw.style.display = "none";
  }}
}});
</script>
</body>
</html>"""
    return HTMLResponse(content=html, headers=NO_CACHE)


# =========================================================================
# 2.  LOGIN  (rate-limited) / LOGOUT
# =========================================================================
@app.post("/login")
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    totp_code: str = Form(...),
):
    ip  = request.client.host if request.client else "unknown"
    now = time.time()

    # Clean stale entries + rate-limit check
    hits = [t for t in _failed.get(ip, []) if now - t < _RL_WINDOW]
    if len(hits) >= _RL_MAX:
        return HTMLResponse(
            "<h2 style='font-family:sans-serif;color:#ef4444;padding:2rem;'>"
            "⛔ Too many failed attempts. Try again in 5 minutes.<br>"
            "<a href='/download' style='color:#06b6d4;'>Back to login</a></h2>",
            status_code=429,
        )

    if username == "admin" and password == SECRET_TOKEN:
        if totp and not totp.verify(totp_code, valid_window=2):
            hits.append(now)
            _failed[ip] = hits
            return HTMLResponse(
                "<h2 style='font-family:sans-serif;padding:2rem;'>❌ Invalid 2FA code."
                " <a href='/download' style='color:#06b6d4;'>Try again</a></h2>",
                status_code=401,
            )
        _failed.pop(ip, None)  # clear on success
        resp = RedirectResponse(url="/download", status_code=303)
        resp.set_cookie(
            key="auth_token", value=SECRET_TOKEN,
            httponly=True, path="/", samesite="none", secure=True,
            max_age=COOKIE_MAX_AGE,
        )
        return resp

    hits.append(now)
    _failed[ip] = hits
    remaining = _RL_MAX - len(hits)
    return HTMLResponse(
        f"<h2 style='font-family:sans-serif;padding:2rem;'>❌ Invalid credentials."
        f" {remaining} attempt(s) remaining.<br>"
        f"<a href='/download' style='color:#06b6d4;'>Try again</a></h2>",
        status_code=401,
    )


@app.get("/logout")
def logout():
    resp = RedirectResponse(url="/download", status_code=303)
    resp.set_cookie(key="auth_token", value="", max_age=0, path="/", samesite="none", secure=True)
    return resp


# =========================================================================
# 3.  PROGRESS  (auth-gated to prevent info leak)
# =========================================================================
@app.get("/progress")
def get_progress(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    with _dl_lock:
        return dict(_current_dl)


# =========================================================================
# 3.1  CANCEL DOWNLOAD  (POST only — GET would be CSRF-able)
# =========================================================================
@app.post("/download/cancel")
def cancel_download(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    global _cancel_requested
    _cancel_requested = True
    return {"status": "success", "message": "Cancellation requested"}


# =========================================================================
# 3.5  RENAME
# =========================================================================
@app.get("/rename")
def rename_file(old: str, new: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")

    old_path = safe_path(old)
    new_path = safe_path(new)

    if not os.path.exists(old_path):
        raise HTTPException(status_code=404, detail="Source file not found")

    parent = os.path.dirname(new_path)
    os.makedirs(parent, exist_ok=True)
    try:
        os.chmod(parent, 0o777)
    except Exception:
        pass

    os.rename(old_path, new_path)
    try:
        os.chmod(new_path, 0o666)
    except Exception:
        pass

    trigger_jellyfin_scan()
    return RedirectResponse(url="/download", status_code=303)


# =========================================================================
# 3.6  MANUAL RESCAN
# =========================================================================
@app.get("/scan")
def manual_scan(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    if trigger_jellyfin_scan():
        return RedirectResponse(url="/download", status_code=303)

    msg = ("JELLYFIN_API_KEY secret is not set." if not JELLYFIN_API_KEY
           else "Cannot reach Jellyfin. Check container logs for details.")
    return HTMLResponse(
        f"""<!DOCTYPE html>
<html><body style="font-family:sans-serif;background:#0b0f19;color:#f43f5e;padding:3rem;text-align:center;">
<h2>⚠️ Rescan Failed</h2>
<p style="color:#9ca3af;">{msg}</p>
<a href="/download" style="color:#06b6d4;font-weight:bold;">← Back to Dashboard</a>
</body></html>""",
        status_code=500,
    )


# =========================================================================
# 4.  DOWNLOAD & EXTRACT
# =========================================================================
@app.post("/download")
def download_file(
    url: str      = Form(...),
    filename: str = Form(...),
    token: str | None = None,
    auth_token: str   = Cookie(None),
):
    if not is_authenticated(token) and not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")

    validate_url(url)                    # SSRF guard
    filename = filename.lstrip("/")      # strip leading slashes

    global _current_dl, _cancel_requested

    # Prevent concurrent downloads
    with _dl_lock:
        if _current_dl.get("status") in ("downloading", "extracting"):
            raise HTTPException(
                status_code=409,
                detail="A download is already in progress. Cancel it first.",
            )
        _cancel_requested = False
        _current_dl = {"filename": filename, "progress": 0.0, "speed": "0.0 MB/s", "status": "downloading"}

    save_path: str | None = None
    try:
        save_path = safe_path(filename)
        parent = os.path.dirname(save_path)
        os.makedirs(parent, exist_ok=True)
        try:
            os.chmod(parent, 0o777)
        except Exception:
            pass

        hdrs = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            )
        }
        # timeout=(connect_timeout, read_timeout) — None = no read timeout for large files
        with requests.get(url, headers=hdrs, stream=True, timeout=(30, None)) as r:
            r.raise_for_status()
            total = r.headers.get("content-length")

            with open(save_path, "wb") as f:
                if total is None:
                    # Unknown size — stream without progress %
                    for chunk in r.iter_content(chunk_size=1024 * 1024):
                        if _cancel_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                    with _dl_lock:
                        _current_dl["progress"] = 100.0
                else:
                    total = int(total)
                    done  = 0
                    t0    = time.time()
                    for chunk in r.iter_content(chunk_size=1024 * 1024):
                        if _cancel_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                            done += len(chunk)
                            elapsed = time.time() - t0
                            with _dl_lock:
                                _current_dl["progress"] = round(done / total * 100, 1)
                                if elapsed > 0:
                                    _current_dl["speed"] = f"{done / (1024*1024) / elapsed:.1f} MB/s"

        try:
            os.chmod(save_path, 0o666)
        except Exception:
            pass

        # Extract archives
        lower = filename.lower()
        if lower.endswith(".zip"):
            if _cancel_requested:
                raise Exception("Download cancelled by user")
            with _dl_lock:
                _current_dl["status"] = "extracting"
            with zipfile.ZipFile(save_path, "r") as z:
                z.extractall(DATA_DIR)
            os.remove(save_path)
            save_path = None

        elif lower.endswith((".tar.gz", ".tgz")):
            if _cancel_requested:
                raise Exception("Download cancelled by user")
            with _dl_lock:
                _current_dl["status"] = "extracting"
            with tarfile.open(save_path, "r:gz") as t:
                t.extractall(DATA_DIR)
            os.remove(save_path)
            save_path = None

        fix_permissions(DATA_DIR)
        trigger_jellyfin_scan()

    except Exception as e:
        # Remove partial file on failure
        if save_path and os.path.exists(save_path):
            try:
                os.remove(save_path)
            except Exception:
                pass
        with _dl_lock:
            _current_dl = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}
        raise HTTPException(status_code=500, detail=str(e))

    with _dl_lock:
        _current_dl = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}

    # Browser-form requests get a redirect; API/curl requests get JSON
    if auth_token == SECRET_TOKEN:
        return RedirectResponse(url="/download", status_code=303)
    return {"status": "success", "message": f"Downloaded {filename}"}


# =========================================================================
# 5.  VIEW / STREAM FILE
# =========================================================================
@app.get("/view/{filename:path}")
def view_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=401, detail="Unauthorized")
    path = safe_path(filename)       # path traversal guard
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path)


# =========================================================================
# 6.  DELETE FILE
# =========================================================================
@app.get("/delete/{filename:path}")
def delete_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=401, detail="Unauthorized")
    path = safe_path(filename)       # path traversal guard
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="File not found")
    try:
        if os.path.isdir(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Delete failed: {e}")
    trigger_jellyfin_scan()
    return RedirectResponse(url="/download", status_code=303)


# =========================================================================
# 7.  HEALTH (used by Docker HEALTHCHECK & keep-alive)
# =========================================================================
@app.get("/health")
def health():
    return {"status": "ok", "jellyfin_key": bool(JELLYFIN_API_KEY)}
