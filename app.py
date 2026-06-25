import os
import shutil
import urllib.request
import zipfile
import tarfile
import requests
import pyotp
import time
from fastapi import FastAPI, File, UploadFile, HTTPException, Form, Response, Cookie
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse

app = FastAPI()

# ---------------------------------------------------------------------------
# Configs — reads from Hugging Face Space Secrets
# ---------------------------------------------------------------------------
SECRET_TOKEN = os.environ.get("STORAGE_PASSWORD")   # HF secret: STORAGE_PASSWORD
TOTP_SECRET  = os.environ.get("TOTP_SECRET")        # HF secret: TOTP_SECRET  ← must be TOTP not TOPT

totp = pyotp.TOTP(TOTP_SECRET) if TOTP_SECRET else None

DATA_DIR             = "/media/videos"
JELLYFIN_INTERNAL_URL = "http://127.0.0.1:8097"

# Startup diagnostics
if not SECRET_TOKEN:
    print("=" * 52)
    print("⚠️  STORAGE_PASSWORD secret is NOT set.")
    print("    Login will be completely disabled until set.")
    print("=" * 52)

if not TOTP_SECRET:
    print("=" * 52)
    print("⚠️  TOTP_SECRET secret is NOT set.")
    print("    2FA is DISABLED — login requires password only.")
    print("    Set TOTP_SECRET in HF Space Secrets to enable.")
    print("=" * 52)
else:
    pairing_uri = totp.provisioning_uri(name="SpaceStorage", issuer_name="HuggingFace")
    print("=" * 52)
    print("🔐 SECURE 2FA SETUP (owner logs only):")
    print(f"   Manual Key : {TOTP_SECRET}")
    print(f"   Setup URI  : {pairing_uri}")
    print("=" * 52)

# Read JELLYFIN_API_KEY — env var preferred, then auto-generated file fallback
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")
if not JELLYFIN_API_KEY and os.path.exists("/config/downloader_api_key.txt"):
    try:
        with open("/config/downloader_api_key.txt", "r") as f:
            JELLYFIN_API_KEY = f.read().strip()
    except Exception as e:
        print(f"[config] Failed to read /config/downloader_api_key.txt: {e}")

os.makedirs(DATA_DIR, exist_ok=True)

# Download state tracker
current_download = {
    "filename": "",
    "progress": 0.0,
    "speed": "0.0 MB/s",
    "status": "idle"   # idle | downloading | extracting
}
cancel_download_requested = False

# Prevent browser from caching auth state (ensures logout is reliable)
NO_CACHE_HEADERS = {
    "Cache-Control": "no-cache, no-store, must-revalidate",
    "Pragma": "no-cache",
    "Expires": "0"
}

# Cookie config — 60 days, persists across browser restarts and Space restarts
COOKIE_MAX_AGE = 86400 * 60   # 60 days in seconds

# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------
def is_authenticated(token: str) -> bool:
    """Returns True if token matches STORAGE_PASSWORD. Safe against None values."""
    if not SECRET_TOKEN or not token:
        return False
    return token == SECRET_TOKEN


def trigger_jellyfin_scan() -> bool:
    """
    POST /Library/Refresh to Jellyfin so new/deleted files appear immediately.
    Sends all three auth header variants for cross-version compatibility.
    """
    if not JELLYFIN_API_KEY:
        print("[scan] JELLYFIN_API_KEY not available — skipping library refresh.")
        return False
    try:
        headers = {
            "X-MediaBrowser-Token": JELLYFIN_API_KEY,
            "X-Emby-Token": JELLYFIN_API_KEY,
            "Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"',
        }
        resp = requests.post(
            f"{JELLYFIN_INTERNAL_URL}/Library/Refresh?api_key={JELLYFIN_API_KEY}",
            headers=headers,
            timeout=10,
        )
        ok = resp.status_code in (200, 204)
        if ok:
            print("[scan] Jellyfin library refresh triggered.")
        else:
            print(f"[scan] Jellyfin refresh failed — HTTP {resp.status_code}: {resp.text}")
        return ok
    except Exception as e:
        print(f"[scan] Could not reach Jellyfin: {e}")
        return False


def fix_permissions_recursive(directory: str):
    """chmod 777 dirs and 666 files so Jellyfin can read everything regardless of owner."""
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


# =========================================================================
# 1. LOGIN UI + DASHBOARD  (GET /login, /download, /view, /delete)
# =========================================================================
@app.get("/download", response_class=HTMLResponse)
@app.get("/login",    response_class=HTMLResponse)
@app.get("/view",     response_class=HTMLResponse)
@app.get("/delete",   response_class=HTMLResponse)
def get_home(auth_token: str = Cookie(None)):

    # ── Not logged in: show login form ──────────────────────────────────
    if not is_authenticated(auth_token):
        totp_field = (
            '<input type="text" name="totp_code" placeholder="6-digit 2FA code"'
            ' maxlength="6" required autocomplete="off">'
            if TOTP_SECRET
            else '<input type="hidden" name="totp_code" value="000000">'
        )
        no_password_warn = (
            """<div style="background:rgba(239,68,68,.1);color:#f87171;padding:.8rem;
            border-radius:8px;font-size:.75rem;margin-top:1.25rem;
            border:1px solid rgba(239,68,68,.2);text-align:left;line-height:1.4;">
            ⚠️ <b>STORAGE_PASSWORD</b> is not set in HF Secrets. Login is disabled.</div>"""
            if not SECRET_TOKEN
            else ""
        )
        no_totp_warn = (
            """<div style="background:rgba(234,179,8,.08);color:#fbbf24;padding:.6rem;
            border-radius:8px;font-size:.72rem;margin-top:.75rem;
            border:1px solid rgba(234,179,8,.2);text-align:left;line-height:1.4;">
            ⚠️ <b>TOTP_SECRET</b> not set — 2FA is disabled. Password only.</div>"""
            if not TOTP_SECRET
            else ""
        )
        html = f"""
        <!DOCTYPE html><html><head>
        <title>Secure Storage Login</title>
        <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
        <style>
          body{{font-family:'Plus Jakarta Sans',sans-serif;background:radial-gradient(circle at center,#0f172a 0%,#020617 100%);
               color:#f8fafc;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}}
          .card{{background:rgba(15,23,42,.55);backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.08);
                 padding:2.5rem;border-radius:16px;width:360px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.5)}}
          h2{{background:linear-gradient(135deg,#06b6d4,#6366f1);-webkit-background-clip:text;
              -webkit-text-fill-color:transparent;margin:0 0 2rem;font-size:1.75rem;font-weight:700}}
          .fg{{margin-bottom:1.25rem;text-align:left}}
          label{{font-size:.8rem;color:#94a3b8;display:block;margin-bottom:.4rem;font-weight:500}}
          input{{width:100%;padding:.8rem 1rem;background:rgba(15,23,42,.6);border:1px solid rgba(255,255,255,.1);
                 border-radius:8px;color:#fff;font-size:.9rem;box-sizing:border-box;font-family:inherit;transition:all .2s}}
          input:focus{{outline:none;border-color:#06b6d4;box-shadow:0 0 10px rgba(6,182,212,.2)}}
          button{{background:linear-gradient(135deg,#06b6d4,#0891b2);color:#0f172a;border:none;
                  padding:.85rem;border-radius:8px;font-weight:700;cursor:pointer;width:100%;
                  font-size:.95rem;margin-top:1rem;box-shadow:0 4px 14px rgba(6,182,212,.3);font-family:inherit}}
          .note{{margin-top:1.5rem;padding-top:1.25rem;border-top:1px dashed rgba(255,255,255,.06);
                 font-size:.75rem;color:#64748b;line-height:1.4}}
        </style></head><body>
        <div class="card">
          <h2>📁 Storage Portal</h2>
          <form action="/login" method="post">
            <div class="fg"><label>Username</label>
              <input type="text" name="username" placeholder="admin" required autocomplete="off"></div>
            <div class="fg"><label>Passcode</label>
              <input type="password" name="password" placeholder="••••••••" required></div>
            <div class="fg"><label>2FA Code {'' if TOTP_SECRET else '(disabled)'}</label>
              {totp_field}</div>
            <button type="submit">Verify & Unlock</button>
          </form>
          {no_password_warn}
          {no_totp_warn}
          <div class="note">🔒 2FA setup URI is printed in the Space container logs on first boot.</div>
        </div></body></html>"""
        return HTMLResponse(content=html, headers=NO_CACHE_HEADERS)

    # ── Logged in: show dashboard ────────────────────────────────────────
    files = []
    for root, _, filenames in os.walk(DATA_DIR):
        for f in filenames:
            files.append(os.path.relpath(os.path.join(root, f), DATA_DIR))

    files_html = ""
    for f in sorted(files):
        fp = os.path.join(DATA_DIR, f)
        try:
            size_mb = os.path.getsize(fp) / (1024 * 1024)
            files_html += f"""
            <li class="fi">
              <div class="fd">
                <span>🎥</span>
                <div>
                  <a class="fl" href="/view/{f}" target="_blank" title="{f}">{f}</a>
                  <span class="fm">{size_mb:.2f} MB</span>
                </div>
              </div>
              <div class="fa">
                <button class="ba br" onclick="renameFile('{f}')">Rename</button>
                <a class="ba bd" href="/delete/{f}">Delete</a>
              </div>
            </li>"""
        except Exception:
            pass

    if not files_html:
        files_html = "<li class='fi empty'>No media files found in /media/videos yet.</li>"

    api_warn = ""
    if not JELLYFIN_API_KEY:
        api_warn = """<div style="background:rgba(239,68,68,.1);color:#f87171;padding:1rem;border-radius:12px;
        border:1px solid rgba(239,68,68,.2);font-size:.85rem;margin-bottom:1.5rem;">
        ⚠️ <b>JELLYFIN_API_KEY</b> not available — library won't auto-refresh after downloads.</div>"""

    html = f"""
    <!DOCTYPE html><html><head>
    <title>Space Storage Explorer</title>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&family=Fira+Code:wght@400;500&display=swap" rel="stylesheet">
    <style>
      :root{{--teal:#06b6d4;--indigo:#6366f1;--red:#ef4444;--green:#10b981;--bg:rgba(15,23,42,.55)}}
      body{{font-family:'Plus Jakarta Sans',sans-serif;background:radial-gradient(circle at top,#0f172a,#020617);
           color:#f8fafc;min-height:100vh;margin:0;padding:2rem;box-sizing:border-box}}
      .wrap{{max-width:1200px;margin:0 auto}}
      header{{display:flex;justify-content:space-between;align-items:center;background:var(--bg);
              backdrop-filter:blur(12px);padding:1.5rem 2rem;border-radius:16px;
              border:1px solid rgba(255,255,255,.08);margin-bottom:2rem;flex-wrap:wrap;gap:1rem}}
      h1{{font-size:1.4rem;font-weight:700;background:linear-gradient(135deg,var(--teal),var(--indigo));
          -webkit-background-clip:text;-webkit-text-fill-color:transparent;margin:0}}
      .si{{display:flex;gap:1.5rem;font-size:.8rem;color:#94a3b8}}
      .dot{{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);display:inline-block}}
      .ha{{display:flex;gap:.75rem}}
      .btn{{font-family:inherit;font-size:.85rem;font-weight:600;padding:.6rem 1.2rem;border-radius:8px;
            border:none;cursor:pointer;display:inline-flex;align-items:center;text-decoration:none;transition:all .25s}}
      .bp{{background:linear-gradient(135deg,var(--teal),#0891b2);color:#0f172a;box-shadow:0 4px 14px rgba(6,182,212,.3)}}
      .bd2{{background:linear-gradient(135deg,var(--red),#dc2626);color:#fff;box-shadow:0 4px 14px rgba(239,68,68,.3)}}
      .bs{{background:rgba(255,255,255,.05);color:#f8fafc;border:1px solid rgba(255,255,255,.1)}}
      .grid{{display:grid;grid-template-columns:4fr 5fr;gap:2rem}}
      @media(max-width:900px){{.grid{{grid-template-columns:1fr}}body{{padding:1rem}}}}
      .panel{{background:var(--bg);backdrop-filter:blur(12px);border:1px solid rgba(255,255,255,.06);
              border-radius:16px;padding:2rem;box-shadow:0 8px 32px rgba(0,0,0,.3);display:flex;flex-direction:column;gap:1.5rem}}
      h3{{font-size:1.15rem;font-weight:600;margin:0;background:linear-gradient(135deg,#a855f7,var(--indigo));
          -webkit-background-clip:text;-webkit-text-fill-color:transparent}}
      .fg{{display:flex;flex-direction:column;gap:.5rem;margin-bottom:.5rem}}
      .fg label{{font-size:.8rem;color:#94a3b8;font-weight:500}}
      input[type=text]{{background:rgba(15,23,42,.6);border:1px solid rgba(255,255,255,.1);border-radius:8px;
                        padding:.8rem 1rem;color:#f8fafc;font-family:inherit;font-size:.9rem;width:100%;box-sizing:border-box}}
      /* Progress */
      .pc{{background:rgba(15,23,42,.85);border-radius:12px;padding:1.25rem;
           border:1px solid rgba(6,182,212,.15);display:none;margin-top:1.5rem}}
      .ph{{display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem}}
      .pt{{font-size:.85rem;font-weight:600;color:var(--teal);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:70%}}
      .pbg{{background:rgba(255,255,255,.05);height:8px;border-radius:4px;overflow:hidden;margin-bottom:.75rem}}
      .pbf{{background:linear-gradient(90deg,var(--teal),var(--indigo));height:100%;width:0%;transition:width .3s}}
      .pf{{display:flex;justify-content:space-between;font-size:.8rem}}
      .cancel-btn{{background:rgba(239,68,68,.15);color:#ef4444;border:1px solid rgba(239,68,68,.3);
                   padding:.3rem .75rem;font-size:.75rem;border-radius:6px;cursor:pointer;font-weight:600}}
      /* Code */
      .cs{{display:flex;flex-direction:column;gap:.75rem;margin-top:1rem;border-top:1px solid rgba(255,255,255,.06);padding-top:1.5rem}}
      .cbw{{position:relative;width:100%}}
      .cb{{background:#05070c!important;padding:1rem;border-radius:8px;font-family:'Fira Code',monospace;
           font-size:.8rem;color:#38bdf8;overflow-x:auto;white-space:nowrap;
           border:1px solid rgba(255,255,255,.06);width:100%;box-sizing:border-box;padding-right:4.5rem}}
      .copy{{position:absolute;right:.5rem;top:50%;transform:translateY(-50%);background:var(--indigo);
             color:#fff;border:none;padding:.35rem .8rem;border-radius:6px;cursor:pointer;font-size:.75rem;font-weight:600}}
      /* File list */
      ul.fl{{list-style:none;padding:0;margin:0;max-height:480px;overflow-y:auto;display:flex;flex-direction:column;gap:.6rem}}
      li.fi{{display:flex;justify-content:space-between;align-items:center;padding:.9rem 1.2rem;
             background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.04);border-radius:10px;transition:all .2s}}
      li.fi:hover{{background:rgba(255,255,255,.05);transform:translateX(4px)}}
      .fd{{display:flex;align-items:center;gap:.75rem;overflow:hidden;max-width:60%}}
      .flt{{display:flex;flex-direction:column;overflow:hidden}}
      a.fl{{color:var(--teal);text-decoration:none;font-weight:600;font-size:.85rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
      .fm{{color:#94a3b8;font-size:.75rem;margin-top:.15rem}}
      .fa{{display:flex;gap:.4rem;flex-shrink:0}}
      .ba{{padding:.35rem .7rem;border-radius:6px;font-size:.75rem;font-weight:600;cursor:pointer;border:none;
           display:inline-flex;align-items:center;text-decoration:none;transition:all .2s}}
      .br{{background:rgba(99,102,241,.1);color:#818cf8;border:1px solid rgba(99,102,241,.2)}}
      .br:hover{{background:var(--indigo);color:#fff}}
      .bd{{background:rgba(239,68,68,.1);color:#f87171;border:1px solid rgba(239,68,68,.2)}}
      .bd:hover{{background:var(--red);color:#fff}}
      li.empty{{justify-content:center;color:#94a3b8;font-style:italic;padding:2rem;background:transparent;border:1px dashed rgba(255,255,255,.08)}}
    </style></head><body>
    <div class="wrap">
      <header>
        <h1>📁 Media Storage Explorer</h1>
        <div class="si">
          <span><span class="dot"></span> Downloader</span>
          <span><span class="dot"></span> Nginx</span>
          <span><span class="dot"></span> Jellyfin</span>
        </div>
        <div class="ha">
          <a href="/scan"   class="btn bs">🔄 Rescan Library</a>
          <a href="/chat/"  class="btn bs">💬 Element Web</a>
          <a href="/"       class="btn bp">🎬 Jellyfin Server</a>
          <a href="/logout" class="btn bd2">Log Out</a>
        </div>
      </header>
      {api_warn}
      <div class="grid">
        <!-- Left: Downloader -->
        <div class="panel">
          <div>
            <h3>📥 Download File from Web</h3>
            <form id="dlform" style="margin-top:1rem;display:flex;flex-direction:column;gap:1rem">
              <div class="fg"><label>Direct Source URL</label>
                <input type="text" name="url" placeholder="https://example.com/movie.mkv" required autocomplete="off"></div>
              <div class="fg"><label>Save As (e.g. movie.mkv or folder/movie.mkv)</label>
                <input type="text" name="filename" placeholder="movie.mkv" required autocomplete="off"></div>
              <button type="submit" class="btn bp" id="dlbtn" style="width:100%;margin-top:.5rem">Download to Space</button>
            </form>
            <div class="pc" id="pc">
              <div class="ph">
                <div class="pt" id="pt">Initializing...</div>
                <button class="cancel-btn" id="cbtn">Cancel</button>
              </div>
              <div class="pbg"><div class="pbf" id="pbf"></div></div>
              <div class="pf">
                <span id="pspeed" style="color:#94a3b8">Connecting...</span>
                <span id="ppct"   style="font-weight:700;color:var(--teal)">0%</span>
              </div>
            </div>
          </div>
          <div class="cs">
            <h3>💻 Automate with Curl</h3>
            <p style="font-size:.8rem;color:#94a3b8;margin:0 0 .5rem;line-height:1.4">Run this in your terminal to download programmatically (no 2FA required, password token used):</p>
            <div class="cbw">
              <div class="cb" id="curlcmd">Loading...</div>
              <button class="copy" id="copybtn">Copy</button>
            </div>
            <div style="font-size:.75rem;color:#64748b;margin-top:.25rem">💡 Replace <b>YOUR_URL</b> and <b>YOUR_FILENAME</b> before running.</div>
          </div>
        </div>
        <!-- Right: File List -->
        <div class="panel">
          <h3>🎬 Video Library (/media/videos)</h3>
          <ul class="fl">{files_html}</ul>
        </div>
      </div>
    </div>
    <script>
    document.addEventListener("DOMContentLoaded", () => {{
      const origin = window.location.origin;
      // NOTE: token is your STORAGE_PASSWORD — visible here only to you (logged-in owner)
      const cmd = `curl -X POST "${{origin}}/download?token={SECRET_TOKEN or 'NOT_SET'}" -d "url=YOUR_URL&filename=YOUR_FILENAME"`;
      document.getElementById("curlcmd").textContent = cmd;
      document.getElementById("copybtn").addEventListener("click", () => {{
        navigator.clipboard.writeText(cmd);
        const b = document.getElementById("copybtn");
        b.textContent = "Copied!";
        setTimeout(() => b.textContent = "Copy", 1500);
      }});
    }});

    function renameFile(fn) {{
      const nn = prompt(`Rename "${{fn}}"\\n\\nEnter new filename (keep the extension):`, fn);
      if (nn && nn.trim() && nn.trim() !== fn)
        window.location.href = `/rename?old=${{encodeURIComponent(fn)}}&new=${{encodeURIComponent(nn.trim())}}`;
    }}

    let poll = null;
    document.getElementById("cbtn").addEventListener("click", async () => {{
      if (confirm("Cancel the active download?")) {{
        await fetch("/download/cancel", {{method:"POST"}}).catch(() => {{}});
        alert("Cancellation sent.");
      }}
    }});

    document.getElementById("dlform").addEventListener("submit", async (e) => {{
      e.preventDefault();
      const fd   = new FormData(e.target);
      const fn   = fd.get("filename");
      const pc   = document.getElementById("pc");
      const pbf  = document.getElementById("pbf");
      const ppct = document.getElementById("ppct");
      const pspd = document.getElementById("pspeed");
      const pt   = document.getElementById("pt");
      const btn  = document.getElementById("dlbtn");

      btn.disabled = true; btn.textContent = "Processing...";
      pc.style.display  = "block";
      pbf.style.width   = "0%";
      ppct.textContent  = "0%";
      pt.textContent    = `Downloading: ${{fn}}`;
      pspd.textContent  = "Initializing...";

      poll = setInterval(async () => {{
        try {{
          const r = await fetch("/progress");
          const d = await r.json();
          if (d.status === "downloading") {{
            pbf.style.width  = d.progress + "%";
            ppct.textContent = d.progress + "%";
            pspd.textContent = `Speed: ${{d.speed}}`;
          }} else if (d.status === "extracting") {{
            pbf.style.width  = "95%";
            ppct.textContent = "95%";
            pspd.textContent = "Extracting archive...";
          }}
        }} catch(_) {{}}
      }}, 1000);

      try {{
        const resp = await fetch("/download", {{method:"POST", body: new URLSearchParams(fd)}});
        clearInterval(poll);
        if (resp.ok) {{
          pspd.textContent = "Syncing with Jellyfin...";
          pbf.style.width  = "100%";
          ppct.textContent = "100%";
          setTimeout(() => location.reload(), 1200);
        }} else {{
          const err = await resp.json();
          alert("Download error: " + (err.detail || "Server error"));
          resetUI();
        }}
      }} catch(err) {{
        clearInterval(poll);
        alert("Connection error: " + err.message);
        resetUI();
      }}

      function resetUI() {{
        btn.disabled = false; btn.textContent = "Download to Space";
        pc.style.display = "none";
      }}
    }});
    </script></body></html>"""
    return HTMLResponse(content=html, headers=NO_CACHE_HEADERS)


# =========================================================================
# 2. LOGIN (POST) — sets 60-day persistent cookie
# =========================================================================
@app.post("/login")
def login(
    username:  str = Form(...),
    password:  str = Form(...),
    totp_code: str = Form(...),
):
    # Check username + password
    if username != "admin" or password != SECRET_TOKEN:
        return HTMLResponse(
            "<h2 style='font-family:sans-serif;padding:2rem'>Invalid credentials. "
            "<a href='/download'>Try again</a></h2>",
            status_code=401,
        )

    # Check 2FA only if TOTP_SECRET is configured
    if totp and not totp.verify(totp_code, valid_window=2):
        return HTMLResponse(
            "<h2 style='font-family:sans-serif;padding:2rem'>Invalid 2FA code. "
            "<a href='/download'>Try again</a></h2>",
            status_code=401,
        )

    response = RedirectResponse(url="/download", status_code=303)
    response.set_cookie(
        key="auth_token",
        value=SECRET_TOKEN,
        httponly=True,          # not accessible from JS
        path="/",
        samesite="none",        # required for HuggingFace iframe/proxy
        secure=True,            # HTTPS only
        max_age=COOKIE_MAX_AGE, # ← 60 days: survives browser closes, Space restarts, phone app kills
    )
    return response


# =========================================================================
# 3. LOGOUT — expires cookie immediately
# =========================================================================
@app.get("/logout")
def logout():
    response = RedirectResponse(url="/download", status_code=303)
    response.set_cookie(
        key="auth_token",
        value="",
        max_age=0,          # expires immediately
        path="/",
        samesite="none",
        secure=True,
    )
    return response


# =========================================================================
# 4. HEALTH (FastAPI-level backup — Nginx already handles /health directly)
# =========================================================================
@app.get("/health")
def health():
    return {"status": "ok"}


# =========================================================================
# 5. DOWNLOAD PROGRESS POLLING
# =========================================================================
@app.get("/progress")
def get_progress():
    return current_download


# =========================================================================
# 6. CANCEL ACTIVE DOWNLOAD
# =========================================================================
@app.post("/download/cancel")
@app.get("/download/cancel")
def cancel_download(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    global cancel_download_requested
    cancel_download_requested = True
    return {"status": "success", "message": "Cancellation request received"}


# =========================================================================
# 7. RENAME FILE
# =========================================================================
@app.get("/rename")
def rename_file(old: str, new: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")

    old_path = os.path.abspath(os.path.join(DATA_DIR, old))
    new_path = os.path.abspath(os.path.join(DATA_DIR, new))
    data_root = os.path.abspath(DATA_DIR)

    # Path traversal guard
    if not old_path.startswith(data_root) or not new_path.startswith(data_root):
        raise HTTPException(status_code=400, detail="Access denied: path outside media directory")

    if os.path.exists(old_path):
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
# 8. MANUAL LIBRARY RESCAN
# =========================================================================
@app.get("/scan")
def manual_scan(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")

    ok = trigger_jellyfin_scan()
    if ok:
        return RedirectResponse(url="/download", status_code=303)

    msg = (
        "JELLYFIN_API_KEY is not set in your HF Space Secrets."
        if not JELLYFIN_API_KEY
        else "Jellyfin scan failed — check container logs for details."
    )
    return HTMLResponse(
        f"""<html><body style="font-family:sans-serif;background:#0b0f19;color:#f43f5e;padding:3rem;text-align:center">
        <h2>⚠️ Rescan Failed</h2>
        <p style="color:#9ca3af">{msg}</p>
        <a href="/download" style="color:#06b6d4;font-weight:bold">← Back to Dashboard</a>
        </body></html>""",
        status_code=500,
    )


# =========================================================================
# 9. FILE DOWNLOAD (programmatic API via token OR cookie)
# =========================================================================
@app.post("/download")
def download_file(
    url:        str = Form(...),
    filename:   str = Form(...),
    token:      str = None,          # ?token=STORAGE_PASSWORD for curl access
    auth_token: str = Cookie(None),
):
    if not is_authenticated(token) and not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")

    global current_download, cancel_download_requested
    cancel_download_requested = False
    current_download = {"filename": filename, "progress": 0.0, "speed": "0.0 MB/s", "status": "downloading"}

    try:
        save_path  = os.path.join(DATA_DIR, filename)
        parent_dir = os.path.dirname(save_path)

        if not os.path.abspath(save_path).startswith(os.path.abspath(DATA_DIR)):
            raise HTTPException(status_code=400, detail="Invalid filename — path traversal detected")

        os.makedirs(parent_dir, exist_ok=True)
        try:
            os.chmod(parent_dir, 0o777)
        except Exception:
            pass

        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        }

        with requests.get(url, headers=headers, stream=True, timeout=30) as r:
            r.raise_for_status()
            total = r.headers.get("content-length")

            with open(save_path, "wb") as f:
                if total is None:
                    for chunk in r.iter_content(chunk_size=1024 * 1024):
                        if cancel_download_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                    current_download["progress"] = 100.0
                else:
                    total      = int(total)
                    downloaded = 0
                    t0         = time.time()
                    for chunk in r.iter_content(chunk_size=1024 * 1024):
                        if cancel_download_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                            downloaded += len(chunk)
                            current_download["progress"] = round(downloaded / total * 100, 1)
                            elapsed = time.time() - t0
                            if elapsed > 0:
                                current_download["speed"] = f"{(downloaded / 1048576) / elapsed:.1f} MB/s"

        try:
            os.chmod(save_path, 0o666)
        except Exception:
            pass

        # Extract archives
        lf = filename.lower()
        if lf.endswith(".zip"):
            current_download["status"] = "extracting"
            with zipfile.ZipFile(save_path, "r") as z:
                z.extractall(DATA_DIR)
            os.remove(save_path)
        elif lf.endswith(".tar.gz") or lf.endswith(".tgz"):
            current_download["status"] = "extracting"
            with tarfile.open(save_path, "r:gz") as t:
                t.extractall(DATA_DIR)
            os.remove(save_path)

        fix_permissions_recursive(DATA_DIR)
        trigger_jellyfin_scan()
        current_download = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}

        if is_authenticated(auth_token):
            return RedirectResponse(url="/download", status_code=303)
        return {"status": "success", "message": f"Downloaded {filename}"}

    except Exception as e:
        current_download = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}
        raise HTTPException(status_code=500, detail=str(e))


# =========================================================================
# 10. VIEW / STREAM FILE
# =========================================================================
@app.get("/view/{filename:path}")
def view_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        return HTMLResponse("<h2>Unauthorized — <a href='/download'>Log in</a></h2>", status_code=401)

    file_path = os.path.join(DATA_DIR, filename)
    if not os.path.abspath(file_path).startswith(os.path.abspath(DATA_DIR)):
        raise HTTPException(status_code=400, detail="Invalid path")
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(file_path)


# =========================================================================
# 11. DELETE FILE
# =========================================================================
@app.get("/delete/{filename:path}")
def delete_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        return HTMLResponse("<h2>Unauthorized — <a href='/download'>Log in</a></h2>", status_code=401)

    file_path = os.path.join(DATA_DIR, filename)
    if not os.path.abspath(file_path).startswith(os.path.abspath(DATA_DIR)):
        raise HTTPException(status_code=400, detail="Invalid path")
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")

    try:
        if os.path.isdir(file_path):
            shutil.rmtree(file_path)
        else:
            os.remove(file_path)
        print(f"[delete] Removed: {filename}")
        trigger_jellyfin_scan()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Delete failed: {e}")

    return RedirectResponse(url="/download", status_code=303)