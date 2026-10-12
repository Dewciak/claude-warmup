#!/usr/bin/env bash
# Poranny ping jednego konta Claude Code - kotwiczy 5-godzinne okno rozliczeniowe.
# Uruchamiany przez crona uzytkownika specodit na tej samej maszynie.
# Uzycie: claude-warmup <acc1|acc2|acc3> [--now]
#
# DLACZEGO BRAMKA CZASU: serwer chodzi w UTC, a tutejszy cron nie zna ustawienia
# strefy (wersja Ubuntu nie ma CRON_TZ). Zeby godzina warszawska nie skakala przy
# zmianie czasu, cron wola kazde konto DWA razy - o godzinie zimowej i letniej -
# a skrypt sam decyduje, ktore wolanie jest tym wlasciwym. Dzienna blokada
# pilnuje, zeby drugie wolanie nie pingowalo po raz drugi.
#
# --now pomija bramke i blokade (reczne sprawdzenie).

set -uo pipefail

ACC="${1:-}"
FORCE="${2:-}"
if [ -z "$ACC" ]; then
  echo "uzycie: claude-warmup <acc1|acc2|acc3> [--now]" >&2
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
# Kto jest kim: numeracja warmupow nie pokrywa sie z numeracja katalogow
# konfiguracyjnych na Macu (historia zakladania profili). Zrodlo prawdy:
# ~/.claude-accounts/config.json na Macu.
case "$ACC" in
  acc1) OWNER="wiktor@specodit.pl";     CFG_DIR="/Users/specodit/.claude-acc2"; TARGET="0630" ;;
  acc2) OWNER="g.handzlik@specodit.pl"; CFG_DIR="/Users/specodit/.claude-acc4"; TARGET="0630" ;;
  acc3) OWNER="joanna@specodit.pl";     CFG_DIR="/Users/specodit/.claude-acc3"; TARGET="0630" ;;
  *)    echo "nieznane konto: $ACC" >&2; exit 2 ;;
esac
GRACE_MIN=70   # ile minut po docelowej godzinie wolanie jest jeszcze "to wlasciwe"

ATTEMPTS=3
BACKOFF=60
PING_TIMEOUT=180

LOCK="$ROOT/locks/$ACC-$(TZ=Europe/Warsaw date +%F)"
mkdir -p "$HOME_DIR" "$LOG_DIR" "$ROOT/tokens" "$ROOT/locks"
find "$ROOT/locks" -type f -mtime +7 -delete 2>/dev/null

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
"Warmup:   $ACC
Konto:    $OWNER
Czas:     $(stamp)
Maszyna:  $(hostname) (n8n)
Powod:    $reason

--- ostatnie wyjscie -------------------------------------
$detail
----------------------------------------------------------

Odswiezenie tokenu:
  1. na Macu, w oknie przegladarki zalogowanym jako $OWNER:
       CLAUDE_CONFIG_DIR=$CFG_DIR claude setup-token
  2. wklej wynik na VPS:
       ssh specodit@87.106.130.91 'umask 077; cat > $TOKEN_FILE'

Pelny log: $LOG"
  exit 1
}

# --- ktore wolanie jest tym wlasciwym ------------------------------------
if [ "$FORCE" != "--now" ]; then
  now_min=$(( 10#$(TZ=Europe/Warsaw date +%H) * 60 + 10#$(TZ=Europe/Warsaw date +%M) ))
  tgt_min=$(( 10#${TARGET:0:2} * 60 + 10#${TARGET:2:2} ))
  if [ "$now_min" -lt "$tgt_min" ] || [ "$now_min" -gt $(( tgt_min + GRACE_MIN )) ]; then
    echo "[$(stamp)] pomijam: warszawski $(TZ=Europe/Warsaw date +%H:%M) poza oknem ${TARGET:0:2}:${TARGET:2:2} +${GRACE_MIN}min" >> "$LOG"
    exit 0
  fi
  if [ -e "$LOCK" ]; then
    echo "[$(stamp)] pomijam: $ACC juz rozgrzane dzisiaj" >> "$LOG"
    exit 0
  fi
fi

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
  log "proba $i/$ATTEMPTS - ping $ACC ($OWNER)"
  HOME="$HOME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" \
    timeout "$PING_TIMEOUT" "$CLAUDE_BIN" -p "hi" --model haiku --no-session-persistence \
    >"$out_file" 2>&1
  status=$?
  head -c 2000 "$out_file" >> "$LOG"; echo >> "$LOG"

  if [ $status -eq 0 ]; then
    log "OK: $ACC ($OWNER) rozgrzane"
    [ "$FORCE" = "--now" ] || : > "$LOCK"
    exit 0
  fi

  # Limit uzycia oznacza, ze token dziala, a okno i tak zostalo dotkniete.
  if grep -Eiq "rate limit|session limit|usage limit" "$out_file"; then
    log "OK: limit uzycia - token dziala, traktuje jako sukces"
    [ "$FORCE" = "--now" ] || : > "$LOCK"
    exit 0
  fi

  # Zly token nie naprawi sie przez powtorzenie - konczymy od razu.
  if grep -Eiq "expired|unauthorized|invalid token|authentication|auth failed|login required|not logged in" "$out_file"; then
    fail "token niewazny albo wygasl (exit=$status)" "$(tail -c 1500 "$out_file")"
  fi

  [ "$i" -lt "$ATTEMPTS" ] && { log "blad przejsciowy (exit=$status), ponawiam za ${BACKOFF}s"; sleep "$BACKOFF"; }
done

fail "ping nie przeszedl po $ATTEMPTS probach (exit=$status)" "$(tail -c 1500 "$out_file")"
