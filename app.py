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
# Configs (Reads from Hugging Face Secrets with secure default fallbacks)
# ---------------------------------------------------------------------------
SECRET_TOKEN = os.environ.get("STORAGE_PASSWORD")      # Passcode (No fallback for security)
TOTP_SECRET = os.environ.get("TOTP_SECRET")        # 2FA base32 seed (No fallback for security)
totp = pyotp.TOTP(TOTP_SECRET) if TOTP_SECRET else None
DATA_DIR = "/media/videos"                                           # Media folder
JELLYFIN_INTERNAL_URL = "http://127.0.0.1:8097"                       # Internal port 8097
if not SECRET_TOKEN or not TOTP_SECRET:
    print("====================================================")
    print("⚠️ WARNING: STORAGE_PASSWORD or TOTP_SECRET is not set!")
    print("Please set them in your Hugging Face Space Secrets.")
    print("====================================================")
# Read JELLYFIN_API_KEY from environment or fallback to auto-generated file
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")
if not JELLYFIN_API_KEY and os.path.exists("/config/downloader_api_key.txt"):
    try:
        with open("/config/downloader_api_key.txt", "r") as f:
            JELLYFIN_API_KEY = f.read().strip()
    except Exception as e:
        print(f"[config] Failed to read /config/downloader_api_key.txt: {e}")
os.makedirs(DATA_DIR, exist_ok=True)
# Print 2FA setup to terminal logs securely on start rather than rendering publicly
if totp:
    pairing_uri = totp.provisioning_uri(name="SpaceStorage", issuer_name="HuggingFace")
    print("====================================================")
    print("🔐 SECURE 2FA SETUP (Only visible in owner logs):")
    print(f"  Manual Key: {TOTP_SECRET}")
    print(f"  Setup URI: {pairing_uri}")
    print("====================================================")
# Global trackers for download progress & cancellation
current_download = {
    "filename": "",
    "progress": 0.0,
    "speed": "0.0 MB/s",
    "status": "idle"  # idle, downloading, extracting
}
cancel_download_requested = False
# Prevents browser from caching the login state (fixes logout button issue)
NO_CACHE_HEADERS = {
    "Cache-Control": "no-cache, no-store, must-revalidate",
    "Pragma": "no-cache",
    "Expires": "0"
}
def is_authenticated(auth_token: str):
    if not SECRET_TOKEN:
        return False
    return auth_token == SECRET_TOKEN
def trigger_jellyfin_scan():
    """
    Triggers Jellyfin's Library scan internally using the API key.
    Sends standard Authorization header, legacy headers, and query parameter
    to guarantee compatibility across all Jellyfin versions.
    """
    if not JELLYFIN_API_KEY:
        print("[scan] JELLYFIN_API_KEY not set — skipping Jellyfin library refresh. Set it in HF Space secrets.")
        return False
    print(f"[scan] Sending library refresh request to Jellyfin at {JELLYFIN_INTERNAL_URL}...")
    try:
        headers = {
            "X-MediaBrowser-Token": JELLYFIN_API_KEY,
            "X-Emby-Token": JELLYFIN_API_KEY,
            "Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"'
        }
        resp = requests.post(
            f"{JELLYFIN_INTERNAL_URL}/Library/Refresh?api_key={JELLYFIN_API_KEY}",
            headers=headers,
            timeout=10,
        )
        ok = resp.status_code in (200, 204)
        if ok:
            print("[scan] Jellyfin library refresh triggered successfully!")
        else:
            print(f"[scan] Jellyfin refresh failed! Status: {resp.status_code}, Body: {resp.text}")
        return ok
    except Exception as e:
        print(f"[scan] Failed to reach Jellyfin for library refresh: {e}")
        return False
# =========================================================================
# 1. WEB HOMEPAGE (Dashboard / Login UI)
# =========================================================================
@app.get("/download", response_class=HTMLResponse)
@app.get("/login", response_class=HTMLResponse)
@app.get("/view", response_class=HTMLResponse)
@app.get("/delete", response_class=HTMLResponse)
def get_home(auth_token: str = Cookie(None)):
    # CASE A: If NOT logged in, show the login screen
    if not is_authenticated(auth_token):
        html_login = f"""
        <html>
            <head>
                <title>Secure Storage Login</title>
                <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
                <style>
                    body {{
                        font-family: 'Plus Jakarta Sans', sans-serif;
                        background: radial-gradient(circle at center, #0f172a 0%, #020617 100%);
                        color: #f8fafc;
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        height: 100vh;
                        margin: 0;
                    }}
                    .login-card {{
                        background: rgba(15, 23, 42, 0.55);
                        backdrop-filter: blur(16px);
                        border: 1px solid rgba(255, 255, 255, 0.08);
                        padding: 2.5rem;
                        border-radius: 16px;
                        width: 360px;
                        text-align: center;
                        box-shadow: 0 10px 40px rgba(0, 0, 0, 0.5);
                    }}
                    h2 {{
                        background: linear-gradient(135deg, #06b6d4, #6366f1);
                        -webkit-background-clip: text;
                        -webkit-text-fill-color: transparent;
                        margin-bottom: 2rem;
                        font-size: 1.75rem;
                        font-weight: 700;
                        margin-top: 0;
                    }}
                    .form-group {{
                        margin-bottom: 1.25rem;
                        text-align: left;
                    }}
                    label {{
                        font-size: 0.8rem;
                        color: #94a3b8;
                        margin-bottom: 0.4rem;
                        display: block;
                        font-weight: 500;
                    }}
                    input {{
                        width: 100%;
                        padding: 0.8rem 1rem;
                        background: rgba(15, 23, 42, 0.6);
                        border: 1px solid rgba(255, 255, 255, 0.1);
                        border-radius: 8px;
                        color: white;
                        font-size: 0.9rem;
                        box-sizing: border-box;
                        font-family: inherit;
                        transition: all 0.2s;
                    }}
                    input:focus {{
                        outline: none;
                        border-color: #06b6d4;
                        box-shadow: 0 0 10px rgba(6, 182, 212, 0.2);
                        background: rgba(15, 23, 42, 0.85);
                    }}
                    button {{
                        background: linear-gradient(135deg, #06b6d4, #0891b2);
                        color: #0f172a;
                        border: none;
                        padding: 0.85rem;
                        border-radius: 8px;
                        font-weight: 700;
                        cursor: pointer;
                        width: 100%;
                        transition: all 0.25s;
                        font-size: 0.95rem;
                        margin-top: 1rem;
                        box-shadow: 0 4px 14px rgba(6, 182, 212, 0.3);
                        font-family: inherit;
                    }}
                    button:hover {{
                        transform: translateY(-2px);
                        box-shadow: 0 6px 20px rgba(6, 182, 212, 0.5);
                    }}
                    .security-notice {{
                        margin-top: 1.5rem;
                        padding-top: 1.25rem;
                        border-top: 1px dashed rgba(255, 255, 255, 0.06);
                        font-size: 0.75rem;
                        color: #64748b;
                        line-height: 1.4;
                    }}
                </style>
            </head>
            <body>
                <div class="login-card">
                    <h2>📁 Storage Portal</h2>
                    <form action="/login" method="post">
                        <div class="form-group">
                            <label>Username</label>
                            <input type="text" name="username" placeholder="admin" required autocomplete="off">
                        </div>
                        <div class="form-group">
                            <label>Passcode</label>
                            <input type="password" name="password" placeholder="••••••••" required>
                        </div>
                        <div class="form-group">
                            <label>2FA Authentication Code</label>
                            {f'<input type="text" name="totp_code" placeholder="6-digit code" maxlength="6" required autocomplete="off">' if TOTP_SECRET else '<input type="hidden" name="totp_code" value="000000">'}
                        </div>
                        <button type="submit">Verify & Unlock</button>
                    </form>
                    <div class="security-notice">
                        🔒 Setup details and keys are securely logged in the Hugging Face container logs on startup.
                    </div>
                    {f'''
                    <div style="background:rgba(239, 68, 68, 0.1); color:#f87171; padding:0.8rem; border-radius:8px; font-size:0.75rem; margin-top:1.25rem; border:1px solid rgba(239, 68, 68, 0.2); text-align:left; line-height:1.4;">
                        ⚠️ <b>STORAGE_PASSWORD</b> is not set. Login is disabled. Add it to your Hugging Face Space Settings as a Secret.
                    </div>
                    ''' if not SECRET_TOKEN else ""}
                </div>
            </body>
        </html>
        """
        return HTMLResponse(content=html_login, headers=NO_CACHE_HEADERS)
    # CASE B: If logged in, render the dashboard
    files = []
    # Recursively list files to show subdirectories nicely
    for root, _, filenames in os.walk(DATA_DIR):
        for f in filenames:
            rel_path = os.path.relpath(os.path.join(root, f), DATA_DIR)
            files.append(rel_path)
            
    files_list_html = ""
    for f in sorted(files):
        file_path = os.path.join(DATA_DIR, f)
        try:
            size_mb = os.path.getsize(file_path) / (1024 * 1024)
            files_list_html += f"""
            <li class="file-item">
                <div class="file-details">
                    <span class="file-icon">🎥</span>
                    <div class="file-text">
                        <a class="file-link" href="/view/{f}" target="_blank" title="{f}">{f}</a>
                        <span class="file-meta">{size_mb:.2f} MB</span>
                    </div>
                </div>
                <div class="file-actions">
                    <button class="btn-action btn-action-rename" onclick="renameFile('{f}')">Rename</button>
                    <a class="btn-action btn-action-delete" href="/delete/{f}">Delete</a>
                </div>
            </li>
            """
        except Exception:
            pass
            
    if not files:
        files_list_html = "<li class='file-item empty-state'>No media files found in /media/videos yet.</li>"
    scan_warning_html = ""
    if not JELLYFIN_API_KEY:
        scan_warning_html = """
        <div style="background: rgba(239, 68, 68, 0.1); color: #f87171; padding: 1rem; border-radius: 12px; border: 1px solid rgba(239, 68, 68, 0.2); font-size: 0.85rem; margin-bottom: 1.5rem; line-height: 1.4;">
            ⚠️ <b>JELLYFIN_API_KEY</b> is not set. Downloads will land in /media/videos but Jellyfin
            won't auto-refresh to see them. Please ensure the latest <b>entrypoint.sh</b> is deployed to generate this automatically.
        </div>
        """
    html_dashboard = f"""
    <html>
        <head>
            <title>Space Storage Explorer</title>
            <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&family=Fira+Code:wght@400;500&display=swap" rel="stylesheet">
            <style>
                :root {{
                    --bg-gradient: radial-gradient(circle at top center, #0f172a 0%, #020617 100%);
                    --card-bg: rgba(15, 23, 42, 0.55);
                    --border-glow: rgba(99, 102, 241, 0.15);
                    --teal: #06b6d4;
                    --indigo: #6366f1;
                    --red: #ef4444;
                    --green: #10b981;
                    --text-primary: #f8fafc;
                    --text-secondary: #94a3b8;
                }}
                body {{
                    font-family: 'Plus Jakarta Sans', sans-serif;
                    background: var(--bg-gradient);
                    color: var(--text-primary);
                    min-height: 100vh;
                    margin: 0;
                    padding: 2rem;
                    box-sizing: border-box;
                }}
                .container {{
                    max-width: 1200px;
                    margin: 0 auto;
                }}
                header {{
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    background: var(--card-bg);
                    backdrop-filter: blur(12px);
                    padding: 1.5rem 2rem;
                    border-radius: 16px;
                    border: 1px solid rgba(255, 255, 255, 0.08);
                    box-shadow: 0 4px 30px rgba(0, 0, 0, 0.4);
                    margin-bottom: 2rem;
                    flex-wrap: wrap;
                    gap: 1rem;
                }}
                h1 {{
                    font-size: 1.4rem;
                    font-weight: 700;
                    background: linear-gradient(135deg, var(--teal), var(--indigo));
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                    margin: 0;
                    display: flex;
                    align-items: center;
                    gap: 0.5rem;
                }}
                .status-indicators {{
                    display: flex;
                    gap: 1.5rem;
                    font-size: 0.8rem;
                    color: var(--text-secondary);
                }}
                .status-item {{
                    display: flex;
                    align-items: center;
                    gap: 0.4rem;
                }}
                .dot {{
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    display: inline-block;
                }}
                .dot-online {{
                    background: var(--green);
                    box-shadow: 0 0 8px var(--green);
                }}
                .header-actions {{
                    display: flex;
                    gap: 0.75rem;
                }}
                .btn {{
                    font-family: inherit;
                    font-size: 0.85rem;
                    font-weight: 600;
                    padding: 0.6rem 1.2rem;
                    border-radius: 8px;
                    border: none;
                    cursor: pointer;
                    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    gap: 0.5rem;
                    text-decoration: none;
                }}
                .btn-primary {{
                    background: linear-gradient(135deg, var(--teal), #0891b2);
                    color: #0f172a;
                    box-shadow: 0 4px 14px rgba(6, 182, 212, 0.3);
                }}
                .btn-primary:hover {{
                    transform: translateY(-2px);
                    box-shadow: 0 6px 20px rgba(6, 182, 212, 0.5);
                }}
                .btn-danger {{
                    background: linear-gradient(135deg, var(--red), #dc2626);
                    color: white;
                    box-shadow: 0 4px 14px rgba(239, 68, 68, 0.3);
                }}
                .btn-danger:hover {{
                    transform: translateY(-2px);
                    box-shadow: 0 6px 20px rgba(239, 68, 68, 0.5);
                }}
                .btn-secondary {{
                    background: rgba(255, 255, 255, 0.05);
                    color: var(--text-primary);
                    border: 1px solid rgba(255, 255, 255, 0.1);
                }}
                .btn-secondary:hover {{
                    background: rgba(255, 255, 255, 0.1);
                    transform: translateY(-2px);
                }}
                
                .grid {{
                    display: grid;
                    grid-template-columns: 4fr 5fr;
                    gap: 2rem;
                }}
                
                @media (max-width: 900px) {{
                    .grid {{
                        grid-template-columns: 1fr;
                    }}
                    body {{
                        padding: 1rem;
                    }}
                }}
                
                .panel {{
                    background: var(--card-bg);
                    backdrop-filter: blur(12px);
                    border: 1px solid rgba(255, 255, 255, 0.06);
                    border-radius: 16px;
                    padding: 2rem;
                    box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.3);
                    display: flex;
                    flex-direction: column;
                    gap: 1.5rem;
                }}
                h3 {{
                    font-size: 1.15rem;
                    font-weight: 600;
                    margin: 0;
                    background: linear-gradient(135deg, #a855f7, var(--indigo));
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                    display: flex;
                    align-items: center;
                    gap: 0.5rem;
                }}
                
                .form-group {{
                    display: flex;
                    flex-direction: column;
                    gap: 0.5rem;
                    margin-bottom: 0.5rem;
                }}
                .form-group label {{
                    font-size: 0.8rem;
                    color: var(--text-secondary);
                    font-weight: 500;
                }}
                input[type="text"], input[type="password"] {{
                    background: rgba(15, 23, 42, 0.6);
                    border: 1px solid rgba(255, 255, 255, 0.1);
                    border-radius: 8px;
                    padding: 0.8rem 1rem;
                    color: var(--text-primary);
                    font-family: inherit;
                    font-size: 0.9rem;
                    transition: all 0.2s;
                    width: 100%;
                    box-sizing: border-box;
                }}
                input[type="text"]:focus, input[type="password"]:focus {{
                    outline: none;
                    border-color: var(--teal);
                    box-shadow: 0 0 10px rgba(6, 182, 212, 0.2);
                    background: rgba(15, 23, 42, 0.85);
                }}
                
                /* Progress Box */
                .progress-container {{
                    background: rgba(15, 23, 42, 0.85);
                    border-radius: 12px;
                    padding: 1.25rem;
                    border: 1px solid rgba(6, 182, 212, 0.15);
                    box-shadow: 0 4px 20px rgba(6, 182, 212, 0.05);
                    display: none;
                }}
                .progress-header {{
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    margin-bottom: 0.75rem;
                }}
                .progress-title {{
                    font-size: 0.85rem;
                    font-weight: 600;
                    color: var(--teal);
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    max-width: 70%;
                }}
                .progress-bar-bg {{
                    background: rgba(255, 255, 255, 0.05);
                    height: 8px;
                    border-radius: 4px;
                    overflow: hidden;
                    margin-bottom: 0.75rem;
                    border: 1px solid rgba(255, 255, 255, 0.03);
                }}
                .progress-bar-fill {{
                    background: linear-gradient(90deg, var(--teal) 0%, var(--indigo) 100%);
                    height: 100%;
                    width: 0%;
                    transition: width 0.3s ease;
                }}
                .progress-footer {{
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    font-size: 0.8rem;
                }}
                .progress-info {{
                    color: var(--text-secondary);
                }}
                .btn-cancel-download {{
                    background: rgba(239, 68, 68, 0.15);
                    color: #ef4444;
                    border: 1px solid rgba(239, 68, 68, 0.3);
                    padding: 0.3rem 0.75rem;
                    font-size: 0.75rem;
                    border-radius: 6px;
                    cursor: pointer;
                    font-weight: 600;
                    transition: all 0.2s;
                }}
                .btn-cancel-download:hover {{
                    background: #ef4444;
                    color: white;
                    box-shadow: 0 0 10px rgba(239, 68, 68, 0.4);
                }}
                
                /* Code Box */
                .code-section {{
                    display: flex;
                    flex-direction: column;
                    gap: 0.75rem;
                    margin-top: 1rem;
                    border-top: 1px solid rgba(255, 255, 255, 0.06);
                    padding-top: 1.5rem;
                }}
                .code-box-wrapper {{
                    position: relative;
                    width: 100%;
                }}
                .code-box {{
                    background: #05070c !important;
                    padding: 1rem;
                    border-radius: 8px;
                    font-family: 'Fira Code', monospace;
                    font-size: 0.8rem;
                    color: #38bdf8;
                    overflow-x: auto;
                    white-space: nowrap;
                    border: 1px solid rgba(255, 255, 255, 0.06);
                    width: 100%;
                    box-sizing: border-box;
                    padding-right: 4.5rem;
                }}
                .btn-copy {{
                    position: absolute;
                    right: 0.5rem;
                    top: 50%;
                    transform: translateY(-50%);
                    background: var(--indigo);
                    color: white;
                    border: none;
                    padding: 0.35rem 0.8rem;
                    border-radius: 6px;
                    cursor: pointer;
                    font-size: 0.75rem;
                    font-weight: 600;
                    transition: all 0.2s;
                }}
                .btn-copy:hover {{
                    background: #4f46e5;
                    box-shadow: 0 0 10px rgba(99, 102, 241, 0.4);
                }}
                
                /* File Explorer */
                ul.file-list {{
                    list-style: none;
                    padding: 0;
                    margin: 0;
                    max-height: 480px;
                    overflow-y: auto;
                    display: flex;
                    flex-direction: column;
                    gap: 0.6rem;
                }}
                ul.file-list::-webkit-scrollbar {{
                    width: 6px;
                }}
                ul.file-list::-webkit-scrollbar-track {{
                    background: rgba(255, 255, 255, 0.02);
                    border-radius: 4px;
                }}
                ul.file-list::-webkit-scrollbar-thumb {{
                    background: rgba(255, 255, 255, 0.1);
                    border-radius: 4px;
                }}
                ul.file-list::-webkit-scrollbar-thumb:hover {{
                    background: rgba(255, 255, 255, 0.2);
                    border-radius: 4px;
                }}
                li.file-item {{
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding: 0.9rem 1.2rem;
                    background: rgba(255, 255, 255, 0.02);
                    border: 1px solid rgba(255, 255, 255, 0.04);
                    border-radius: 10px;
                    transition: all 0.2s;
                }}
                li.file-item:hover {{
                    background: rgba(255, 255, 255, 0.05);
                    border-color: rgba(99, 102, 241, 0.15);
                    transform: translateX(4px);
                }}
                .file-details {{
                    display: flex;
                    align-items: center;
                    gap: 0.75rem;
                    overflow: hidden;
                    max-width: 60%;
                }}
                .file-icon {{
                    font-size: 1.25rem;
                    flex-shrink: 0;
                }}
                .file-text {{
                    display: flex;
                    flex-direction: column;
                    overflow: hidden;
                }}
                .file-link {{
                    color: var(--teal);
                    text-decoration: none;
                    font-weight: 600;
                    font-size: 0.85rem;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    transition: color 0.2s;
                }}
                .file-link:hover {{
                    color: #22d3ee;
                    text-decoration: underline;
                }}
                .file-meta {{
                    color: var(--text-secondary);
                    font-size: 0.75rem;
                    margin-top: 0.15rem;
                }}
                .file-actions {{
                    display: flex;
                    gap: 0.4rem;
                    flex-shrink: 0;
                }}
                .btn-action {{
                    padding: 0.35rem 0.7rem;
                    border-radius: 6px;
                    font-size: 0.75rem;
                    font-weight: 600;
                    cursor: pointer;
                    border: none;
                    transition: all 0.2s;
                    text-decoration: none;
                    display: inline-flex;
                    align-items: center;
                }}
                .btn-action-rename {{
                    background: rgba(99, 102, 241, 0.1);
                    color: #818cf8;
                    border: 1px solid rgba(99, 102, 241, 0.2);
                }}
                .btn-action-rename:hover {{
                    background: var(--indigo);
                    color: white;
                }}
                .btn-action-delete {{
                    background: rgba(239, 68, 68, 0.1);
                    color: #f87171;
                    border: 1px solid rgba(239, 68, 68, 0.2);
                }}
                .btn-action-delete:hover {{
                    background: var(--red);
                    color: white;
                }}
                li.empty-state {{
                    justify-content: center;
                    color: var(--text-secondary);
                    font-style: italic;
                    padding: 2rem;
                    background: transparent;
                    border: 1px dashed rgba(255, 255, 255, 0.08);
                }}
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <h1>📁 Media Storage Explorer</h1>
                    
                    <div class="status-indicators">
                        <div class="status-item">
                            <span class="dot dot-online"></span>
                            <span>Downloader: Active</span>
                        </div>
                        <div class="status-item">
                            <span class="dot dot-online"></span>
                            <span>Nginx Proxy: Active</span>
                        </div>
                        <div class="status-item">
                            <span class="dot dot-online"></span>
                            <span>Jellyfin: Connected</span>
                        </div>
                    </div>
                    
                    <div class="header-actions">
                        <a href="/scan" class="btn btn-secondary">🔄 Rescan Library</a>
                        <a href="/chat/" class="btn btn-secondary">💬 Element Web</a>
                        <a href="/" class="btn btn-primary">🎬 Jellyfin Server</a>
                        <a href="/logout" class="btn btn-danger">Log Out</a>
                    </div>
                </header>
                {scan_warning_html}
                <div class="grid">
                    <!-- Left Panel -->
                    <div class="panel">
                        <div>
                            <h3>📥 Download File from Web</h3>
                            <form id="download-form" style="margin-top:1rem; display:flex; flex-direction:column; gap:1rem;">
                                <div class="form-group">
                                    <label>Direct Source URL</label>
                                    <input type="text" name="url" placeholder="https://example.com/movie.mp4" required autocomplete="off">
                                </div>
                                <div class="form-group">
                                    <label>Save As File Name</label>
                                    <input type="text" name="filename" placeholder="movie.mp4 or folder/movie.mp4" required autocomplete="off">
                                </div>
                                <button type="submit" class="btn btn-primary" id="download-btn" style="width:100%; margin-top:0.5rem;">Download to Space</button>
                            </form>
                            <!-- Visual Progress Bar -->
                            <div class="progress-container" id="progress-container" style="margin-top:1.5rem;">
                                <div class="progress-header">
                                    <div class="progress-title" id="progress-title">Initializing...</div>
                                    <button class="btn-cancel-download" id="cancel-download-btn">Cancel</button>
                                </div>
                                <div class="progress-bar-bg">
                                    <div class="progress-bar-fill" id="progress-bar"></div>
                                </div>
                                <div class="progress-footer">
                                    <span class="progress-info" id="progress-speed">Connecting...</span>
                                    <span class="progress-info" id="progress-text" style="font-weight:700; color:var(--teal);">0%</span>
                                </div>
                            </div>
                        </div>
                        <div class="code-section">
                            <h3>💻 Automate with Curl</h3>
                            <p style="font-size: 0.8rem; color: var(--text-secondary); margin: 0 0 0.5rem 0; line-height:1.4;">Copy and run this command in your local terminal to download without 2FA validation:</p>
                            <div class="code-box-wrapper">
                                <div class="code-box" id="curl-code">Loading API address...</div>
                                <button class="btn-copy" id="copy-btn">Copy</button>
                            </div>
                            <div style="font-size: 0.75rem; color: #64748b; margin-top: 0.25rem;">💡 Replace <b>YOUR_URL</b> and <b>YOUR_FILENAME</b> in the copied command.</div>
                        </div>
                    </div>
                    <!-- Right Panel -->
                    <div class="panel">
                        <div>
                            <h3 style="margin-bottom:1.5rem;">🎬 Video Library (/media/videos)</h3>
                            <ul class="file-list">
                                {files_list_html}
                            </ul>
                        </div>
                    </div>
                </div>
            </div>
            <script>
                document.addEventListener("DOMContentLoaded", () => {{
                    const spaceHost = window.location.origin;
                    const curlCommand = `curl -d "url=YOUR_URL&filename=YOUR_FILENAME" "\${{spaceHost}}/download?token=${SECRET_TOKEN or ''}"`;
                    document.getElementById("curl-code").innerText = curlCommand;
                    
                    document.getElementById("copy-btn").addEventListener("click", () => {{
                        navigator.clipboard.writeText(curlCommand);
                        const btn = document.getElementById("copy-btn");
                        btn.innerText = "Copied!";
                        setTimeout(() => btn.innerText = "Copy", 1500);
                    }});
                }});
                function renameFile(filename) {{
                    const defaultSuggestion = filename;
                    const newName = prompt(`Rename File:\\n"\${{filename}}"\\n\\nEnter new filename (make sure to include the extension e.g. .mp4 or .mkv):`, defaultSuggestion);
                    if (newName && newName.trim() !== "" && newName.trim() !== filename) {{
                        window.location.href = `/rename?old=\${{encodeURIComponent(filename)}}&new=\${{encodeURIComponent(newName.trim())}}`;
                    }}
                }}
                let pollInterval = null;
                document.getElementById('cancel-download-btn').addEventListener('click', async () => {{
                    if (confirm("Are you sure you want to cancel the active download?")) {{
                        try {{
                            await fetch('/download/cancel', {{ method: 'POST' }});
                            alert("Cancellation request sent.");
                        }} catch (err) {{
                            console.error("Cancel failed:", err);
                        }}
                    }}
                }});
                document.getElementById('download-form').addEventListener('submit', async (e) => {{
                    e.preventDefault();
                    const formData = new FormData(e.target);
                    const filenameInput = formData.get('filename');
                    
                    const progressContainer = document.getElementById('progress-container');
                    const progressBar = document.getElementById('progress-bar');
                    const progressText = document.getElementById('progress-text');
                    const progressSpeed = document.getElementById('progress-speed');
                    const progressTitle = document.getElementById('progress-title');
                    const downloadBtn = document.getElementById('download-btn');
                    
                    downloadBtn.disabled = true;
                    downloadBtn.innerText = "Processing...";
                    progressContainer.style.display = 'block';
                    progressBar.style.width = '0%';
                    progressText.innerText = '0%';
                    progressSpeed.innerText = 'Initializing connection...';
                    progressTitle.innerText = `Downloading: \${{filenameInput}}`;
                    pollInterval = setInterval(async () => {{
                        try {{
                            const res = await fetch('/progress');
                            const data = await res.json();
                            if (data.status === 'downloading') {{
                                progressBar.style.width = data.progress + '%';
                                progressText.innerText = data.progress + '%';
                                progressSpeed.innerText = `Speed: \${{data.speed}}`;
                            }} else if (data.status === 'extracting') {{
                                progressBar.style.width = '95%';
                                progressText.innerText = '95%';
                                progressSpeed.innerText = 'Extracting files...';
                            }}
                        }} catch (err) {{
                            console.error(err);
                        }}
                    }}, 1000);
                    try {{
                        const response = await fetch('/download', {{
                            method: 'POST',
                            body: new URLSearchParams(formData)
                        }});
                        
                        clearInterval(pollInterval);
                        
                        if (response.ok) {{
                            progressSpeed.innerText = 'Syncing with Jellyfin...';
                            progressBar.style.width = '100%';
                            progressText.innerText = '100%';
                            setTimeout(() => {{
                                window.location.reload();
                            }}, 1200);
                        }} else {{
                            const errData = await response.json();
                            alert('Download ended: ' + (errData.detail || 'Server error or cancelled'));
                            resetUI();
                        }}
                    }} catch (err) {{
                        clearInterval(pollInterval);
                        alert('Connection Error: ' + err.message);
                        resetUI();
                    }}
                    
                    function resetUI() {{
                        downloadBtn.disabled = false;
                        downloadBtn.innerText = "Download to Space";
                        progressContainer.style.display = 'none';
                    }}
                }});
            </script>
        </body>
    </html>
    """
    return HTMLResponse(content=html_dashboard, headers=NO_CACHE_HEADERS)
# =========================================================================
# 2. LOGIN / LOGOUT WITH USERNAME & 2FA BUFFER (Iframe compatible)
# =========================================================================
@app.post("/login")
def login(username: str = Form(...), password: str = Form(...), totp_code: str = Form(...)):
    if username == "admin" and password == SECRET_TOKEN:
        if totp and not totp.verify(totp_code, valid_window=2):
            return HTMLResponse("<h2>Invalid 2FA code! <a href='/download'>Try again</a></h2>", status_code=401)
            
        response = RedirectResponse(url="/download", status_code=303)
        response.set_cookie(
            key="auth_token", 
            value=SECRET_TOKEN, 
            httponly=True, 
            path="/", 
            samesite="none", 
            secure=True
        )
        return response
    return HTMLResponse("<h2>Invalid credentials! <a href='/download'>Try again</a></h2>", status_code=401)
@app.get("/logout")
def logout():
    response = RedirectResponse(url="/download", status_code=303)
    response.set_cookie(
        key="auth_token", 
        value="", 
        max_age=0, 
        path="/", 
        samesite="none", 
        secure=True
    )
    return response
# =========================================================================
# 3. PROGRESS LOGGING & CANCELLATION ENDPOINTS
# =========================================================================
@app.get("/progress")
def get_progress():
    return current_download
@app.post("/download/cancel")
@app.get("/download/cancel")
def cancel_download(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    global cancel_download_requested
    cancel_download_requested = True
    return {"status": "success", "message": "Cancellation request received"}
# =========================================================================
# 3.5 RENAME FILE ENDPOINT
# =========================================================================
@app.get("/rename")
def rename_file(old: str, new: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    
    old_path = os.path.abspath(os.path.join(DATA_DIR, old))
    new_path = os.path.abspath(os.path.join(DATA_DIR, new))
    
    if not old_path.startswith(os.path.abspath(DATA_DIR)) or \
       not new_path.startswith(os.path.abspath(DATA_DIR)):
        raise HTTPException(status_code=400, detail="Access denied")
        
    if os.path.exists(old_path):
        parent_dir = os.path.dirname(new_path)
        if not os.path.exists(parent_dir):
            os.makedirs(parent_dir, exist_ok=True)
            try:
                os.chmod(parent_dir, 0o777)
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
# 3.6 MANUAL LIBRARY RESCAN ENDPOINT
# =========================================================================
@app.get("/scan")
def manual_scan(auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
    ok = trigger_jellyfin_scan()
    if ok:
        return RedirectResponse(url="/download", status_code=303)
    
    error_msg = "Could not trigger Jellyfin scan. Check that your JELLYFIN_API_KEY is correct, and that Jellyfin is running."
    if not JELLYFIN_API_KEY:
        error_msg = "JELLYFIN_API_KEY secret is not set in your Hugging Face Space Settings."
        
    return HTMLResponse(f"""
    <html>
        <body style="font-family:sans-serif; background:#0b0f19; color:#f43f5e; padding:3rem; text-align:center;">
            <h2>⚠️ Rescan Failed</h2>
            <p style="color:#9ca3af;">{error_msg}</p>
            <p style="color:#6b7280; font-size:0.9rem;">Check your Hugging Face space logs for the exact error detail.</p>
            <a href="/download" style="color:#06b6d4; text-decoration:none; font-weight:bold;">Go Back to Dashboard</a>
        </body>
    </html>
    """, status_code=500)
def fix_permissions_recursive(directory):
    """
    Recursively apply read/write permissions to files and read/write/execute to directories
    to ensure the Jellyfin process (which might run as a different user) can index them.
    """
    for root, dirs, files in os.walk(directory):
        for d in dirs:
            dir_path = os.path.join(root, d)
            try:
                os.chmod(dir_path, 0o777)
            except Exception as e:
                print(f"[perms] Failed chmod 777 on dir {dir_path}: {e}")
        for f in files:
            file_path = os.path.join(root, f)
            try:
                os.chmod(file_path, 0o666)
            except Exception as e:
                print(f"[perms] Failed chmod 666 on file {file_path}: {e}")
# =========================================================================
# 4. DOWNLOAD & EXTRACT API
# =========================================================================
@app.post("/download")
def download_file(url: str = Form(...), filename: str = Form(...), token: str = None, auth_token: str = Cookie(None)):
    if not is_authenticated(token) and not is_authenticated(auth_token):
        raise HTTPException(status_code=403, detail="Unauthorized")
        
    global current_download, cancel_download_requested
    cancel_download_requested = False
    current_download = {"filename": filename, "progress": 0.0, "speed": "0.0 MB/s", "status": "downloading"}
        
    try:
        save_path = os.path.join(DATA_DIR, filename)
        
        # Create directories if they do not exist (e.g. folder/movie.mp4)
        parent_dir = os.path.dirname(save_path)
        if not os.path.exists(parent_dir):
            os.makedirs(parent_dir, exist_ok=True)
            try:
                os.chmod(parent_dir, 0o777)
            except Exception:
                pass
                
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        }
        
        with requests.get(url, headers=headers, stream=True) as r:
            r.raise_for_status()
            total_size = r.headers.get('content-length')
            
            with open(save_path, 'wb') as f:
                if total_size is None:
                    for chunk in r.iter_content(chunk_size=1024*1024):
                        if cancel_download_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                    current_download["progress"] = 100.0
                else:
                    total_size = int(total_size)
                    downloaded = 0
                    start_time = time.time()
                    
                    for chunk in r.iter_content(chunk_size=1024*1024):
                        if cancel_download_requested:
                            raise Exception("Download cancelled by user")
                        if chunk:
                            f.write(chunk)
                            downloaded += len(chunk)
                            current_download["progress"] = round((downloaded / total_size) * 100, 1)
                            
                            elapsed = time.time() - start_time
                            if elapsed > 0:
                                speed_mbs = (downloaded / (1024*1024)) / elapsed
                                current_download["speed"] = f"{speed_mbs:.1f} MB/s"
                                
        # Apply standard read/write permissions so Jellyfin can access the file
        try:
            os.chmod(save_path, 0o666)
        except Exception:
            pass
            
        # Check if it needs extraction
        if filename.endswith(".zip"):
            if cancel_download_requested:
                raise Exception("Download cancelled by user")
            current_download["status"] = "extracting"
            with zipfile.ZipFile(save_path, 'r') as zip_ref:
                zip_ref.extractall(DATA_DIR)
            os.remove(save_path)
            
        elif filename.endswith(".tar.gz") or filename.endswith(".tgz"):
            if cancel_download_requested:
                raise Exception("Download cancelled by user")
            current_download["status"] = "extracting"
            with tarfile.open(save_path, "r:gz") as tar_ref:
                tar_ref.extractall(DATA_DIR)
            os.remove(save_path)
        # Fix permissions recursively across the entire media directory
        fix_permissions_recursive(DATA_DIR)
        # Tell Jellyfin to pick up the new file right now.
        trigger_jellyfin_scan()
        current_download = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}
        
        if auth_token == SECRET_TOKEN:
            return RedirectResponse(url="/download", status_code=303)
        return {"status": "success", "message": f"Downloaded {filename}"}
        
    except Exception as e:
        current_download = {"filename": "", "progress": 0.0, "speed": "0.0 MB/s", "status": "idle"}
        raise HTTPException(status_code=500, detail=str(e))
@app.get("/view/{filename:path}")
def view_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        return HTMLResponse("<h2>Unauthorized! Please log in.</h2>", status_code=401)
    file_path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")
        
    return FileResponse(file_path)
@app.get("/delete/{filename:path}")
def delete_file(filename: str, auth_token: str = Cookie(None)):
    if not is_authenticated(auth_token):
        return HTMLResponse("<h2>Unauthorized! Please log in.</h2>", status_code=401)
    file_path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    try:
        if os.path.isdir(file_path):
            shutil.rmtree(file_path)
        else:
            os.remove(file_path)
        print(f"[delete] Deleted file: {filename}")
        
        # Trigger Jellyfin rescan after file removal
        trigger_jellyfin_scan()
        
    except Exception as e:
        print(f"[delete] Failed to delete file: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete: {e}")
    return RedirectResponse(url="/download", status_code=303)
