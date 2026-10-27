#!/usr/bin/env python3
"""Send Supabase Auth emails through Gmail SMTP and make the sign-up email a 6-digit code.

Needs in .env (never printed):
  SUPABASE_PROJECT_URL     https://<ref>.supabase.co
  SUPABASE_ACCESS_TOKEN    a personal access token (dashboard > Account > Access Tokens)
  GMAIL_ADDRESS            the Gmail address that owns the app password
  GOOGLE_APP_PASSWORD      a 16-character Google app password (2-step verification must be on)

    python3 scripts/configure_auth_email.py          # apply
    python3 scripts/configure_auth_email.py --show   # print the non-secret settings only
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_env() -> dict:
    values = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def api(method: str, url: str, token: str, body: dict | None = None):
    # curl uses the system CA store; Python 3.14 on macOS often does not.
    cmd = [
        "curl", "-sS", "-X", method, url,
        "-H", f"Authorization: Bearer {token}",
        "-H", "Content-Type: application/json",
        "-H", "User-Agent: skippio-demo-setup",
        "-w", "\n%{http_code}",
    ]
    if body is not None:
        cmd += ["-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return 0, {"error": (out.stderr or out.stdout)[:300]}
    text, _, code = out.stdout.rpartition("\n")
    try:
        payload = json.loads(text) if text else {}
    except json.JSONDecodeError:
        payload = {"error": text[:300]}
    return int(code or 0), payload


CONFIRM_TEMPLATE = """<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:420px;margin:0 auto;padding:24px;color:#1f1c1a">
  <h2 style="margin:0 0 12px;font-size:22px">Confirm your Skippio account</h2>
  <p style="margin:0 0 16px;font-size:16px;line-height:1.4">Enter this code in the app to finish creating your account:</p>
  <p style="margin:0 0 16px;font-size:36px;font-weight:700;letter-spacing:8px;background:#fdf1e0;border-radius:12px;padding:16px;text-align:center">{{ .Token }}</p>
  <p style="margin:0;font-size:13px;color:#7a7168">The code expires in an hour. If you didn't sign up, you can ignore this email.</p>
</div>"""


def main() -> None:
    env = load_env()
    token = env.get("SUPABASE_ACCESS_TOKEN")
    project = re.match(r"https://([a-z0-9]+)\.supabase\.co", env.get("SUPABASE_PROJECT_URL", ""))
    gmail = env.get("GMAIL_ADDRESS")
    app_password = env.get("GOOGLE_APP_PASSWORD", "").replace(" ", "")
    missing = [n for n, v in [("SUPABASE_ACCESS_TOKEN", token), ("SUPABASE_PROJECT_URL", project), ("GMAIL_ADDRESS", gmail), ("GOOGLE_APP_PASSWORD", app_password)] if not v]
    if missing:
        sys.exit("Missing in .env: " + ", ".join(missing))
    ref = project.group(1)
    url = f"https://api.supabase.com/v1/projects/{ref}/config/auth"

    if "--show" in sys.argv:
        status, config = api("GET", url, token)
        shown = {k: config.get(k) for k in ["site_url", "mailer_autoconfirm", "rate_limit_email_sent", "smtp_host", "smtp_port", "smtp_user", "smtp_admin_email", "smtp_sender_name", "mailer_subjects_confirmation"]}
        print(status, json.dumps(shown, indent=1))
        return

    status, result = api(
        "PATCH",
        url,
        token,
        {
            "smtp_host": "smtp.gmail.com",
            "smtp_port": "465",
            "smtp_user": gmail,
            "smtp_pass": app_password,
            "smtp_admin_email": gmail,
            "smtp_sender_name": "Skippio Demo",
            "rate_limit_email_sent": 30,
            "mailer_otp_length": 6,
            "mailer_autoconfirm": False,
            "mailer_subjects_confirmation": "Your Skippio confirmation code",
            "mailer_templates_confirmation_content": CONFIRM_TEMPLATE,
        },
    )
    print("PATCH config/auth ->", status)
    if status >= 300:
        sys.exit(json.dumps(result)[:300])
    print("smtp_host:", result.get("smtp_host"), "| smtp_user set:", bool(result.get("smtp_user")),
          "| rate_limit_email_sent:", result.get("rate_limit_email_sent"))


if __name__ == "__main__":
    main()
