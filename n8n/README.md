# Warmup bez GitHuba - n8n + lokalne CLI

Ping rozgrzewajacy 5-godzinne okno robi teraz samo n8n na `87.106.130.91`
(usluga systemd, user `specodit`). GitHub Actions nie bierze w tym udzialu:
znika kolejka runnerow, bramka czasowa, dzienna blokada na cache i keepalive.

## Co gdzie lezy (VPS)

    /home/specodit/bin/claude-warmup          skrypt (zrodlo: n8n/claude-warmup.sh)
    /home/specodit/claude-warmup/tokens/      accN.token - jeden token na konto (chmod 600)
    /home/specodit/claude-warmup/homes/       osobny HOME kazdego konta
    /home/specodit/claude-warmup/logs/        accN.log
    /home/specodit/claude-warmup/smtp.env     dane SMTP do alertow (chmod 600)
    /home/specodit/.npm-global/bin/claude     CLI Claude Code

## Tokeny

Na Macu, osobno dla kazdego konta:

    HOME=~/claude-acc2 claude setup-token

Wynik wklej na VPS:

    ssh specodit@87.106.130.91 'umask 077; cat > /home/specodit/claude-warmup/tokens/acc2.token'

## Alert mailowy

Kazdy nieudany run wysyla mail na `wiktor@specodit.pl` (curl -> SMTP Gmail,
konto `biuro@specodit.pl`). Wczesniej sa 3 proby co 60 s, wiec jednorazowa
usterka sieci nie budzi alarmu. Niewazny token przerywa od razu - powtarzanie
go nie naprawi. Limit uzycia liczy sie jako sukces: token dziala, okno dotkniete.

## Reczne sprawdzenie

    ssh specodit@87.106.130.91 '/home/specodit/bin/claude-warmup acc1; echo exit=$?'
