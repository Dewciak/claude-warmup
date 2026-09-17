#!/usr/bin/env bash
# Poranny ping jednego konta Claude Code - kotwiczy 5-godzinne okno rozliczeniowe.
# Uruchamiany przez n8n (wezel Execute Command) na tej samej maszynie co n8n.
# Uzycie: claude-warmup <acc1|acc2|acc3|acc4>
#
# Zero GitHuba: godzine wyznacza cron n8n, wiec nie ma tu bramki czasowej
# ani dziennej blokady - te istnialy tylko po to, by ujarzmic kolejke runnerow.

set -uo pipefail

ACC="${1:-}"
if [ -z "$ACC" ]; then
  echo "uzycie: claude-warmup <acc1|acc2|acc3|acc4>" >&2
  exit 2
fi

ROOT="/home/specodit/claude-warmup"
HOME_DIR="$ROOT/homes/$ACC"
TOKEN_FILE="$ROOT/tokens/$ACC.token"
SMTP_ENV="$ROOT/smtp.env"
LOG_DIR="$ROOT/logs"
LOG="$LOG_DIR/$ACC.log"
CLAUDE_BIN="/home/specodit/.npm-global/bin/claude"
MAIL_TO="wiktor@specodit.pl"
ATTEMPTS=3
BACKOFF=60
PING_TIMEOUT=180

mkdir -p "$HOME_DIR" "$LOG_DIR" "$ROOT/tokens"

stamp() { TZ=Europe/Warsaw date '+%Y-%m-%d %H:%M:%S %Z'; }
log() { echo "[$(stamp)] $*" | tee -a "$LOG"; }

send_mail() {
  local subject="$1" body="$2"
  if [ ! -r "$SMTP_ENV" ]; then
    log "BRAK $SMTP_ENV - nie wyslano maila"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$SMTP_ENV"
  local msg
  msg="$(mktemp)"
  {
    printf 'From: Claude Warmup <%s>\r\n' "$SMTP_USER"
    printf 'To: %s\r\n' "$MAIL_TO"
    printf 'Subject: %s\r\n' "$subject"
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf 'MIME-Version: 1.0\r\n'
    printf '\r\n'
    printf '%s\r\n' "$body"
  } > "$msg"
  curl --silent --show-error --ssl-reqd \
    --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
    --user "${SMTP_USER}:${SMTP_PASS}" \
    --mail-from "${SMTP_USER}" \
    --mail-rcpt "${MAIL_TO}" \
    --upload-file "$msg" >>"$LOG" 2>&1
  local rc=$?
  rm -f "$msg"
  [ $rc -eq 0 ] && log "mail wyslany do $MAIL_TO" || log "mail NIE poszedl (curl=$rc)"
  return $rc
}

fail() {
  local reason="$1" detail="${2:-}"
  log "PAD: $reason"
  send_mail "Claude warmup PADL: $ACC ($(TZ=Europe/Warsaw date '+%Y-%m-%d %H:%M'))" \
"Konto:    $ACC
Czas:     $(stamp)
Maszyna:  $(hostname) (n8n)
Powod:    $reason

--- ostatnie wyjscie -------------------------------------
$detail
----------------------------------------------------------

Odswiezenie tokenu:
  na Macu:  HOME=~/claude-$ACC claude setup-token
  na VPS:   wklej nowy token do $TOKEN_FILE (chmod 600)

Pelny log: $LOG"
  exit 1
}

# --- token ---------------------------------------------------------------
[ -s "$TOKEN_FILE" ] || fail "brak tokenu w $TOKEN_FILE" "Plik nie istnieje albo jest pusty."
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[ -n "$TOKEN" ] || fail "token pusty po odfiltrowaniu bialych znakow" ""

# --- onboarding CLI ------------------------------------------------------
[ -f "$HOME_DIR/.claude.json" ] || echo '{"hasCompletedOnboarding":true}' > "$HOME_DIR/.claude.json"

# --- ping ----------------------------------------------------------------
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT
status=1

for i in $(seq 1 "$ATTEMPTS"); do
  log "proba $i/$ATTEMPTS - ping konta $ACC"
  HOME="$HOME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" \
    timeout "$PING_TIMEOUT" "$CLAUDE_BIN" -p "hi" --model haiku --no-session-persistence \
    >"$out_file" 2>&1
  status=$?
  head -c 2000 "$out_file" >> "$LOG"; echo >> "$LOG"

  if [ $status -eq 0 ]; then
    log "OK: $ACC rozgrzane"
    exit 0
  fi

  # Limit uzycia oznacza, ze token dziala, a okno i tak zostalo dotkniete.
  if grep -Eiq "rate limit|session limit|usage limit" "$out_file"; then
    log "OK: limit uzycia - token dziala, traktuje jako sukces"
    exit 0
  fi

  # Zly token nie naprawi sie przez powtorzenie - konczymy od razu.
  if grep -Eiq "expired|unauthorized|invalid token|authentication|auth failed|login required|not logged in" "$out_file"; then
    fail "token niewazny albo wygasl (exit=$status)" "$(tail -c 1500 "$out_file")"
  fi

  [ "$i" -lt "$ATTEMPTS" ] && { log "blad przejsciowy (exit=$status), ponawiam za ${BACKOFF}s"; sleep "$BACKOFF"; }
done

fail "ping nie przeszedl po $ATTEMPTS probach (exit=$status)" "$(tail -c 1500 "$out_file")"
