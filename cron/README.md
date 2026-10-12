# Warmup bez GitHuba i bez n8n - cron na VPS

Ping rozgrzewajacy 5-godzinne okno robi cron uzytkownika `specodit` na
`87.106.130.91`. Ani GitHub Actions, ani n8n nie biora w tym udzialu.

Dlaczego nie n8n: od wersji 2.0 wylacza ono domyslnie wezel uruchamiajacy
polecenia systemowe, a jego odblokowanie dawaloby kazdemu, kto wejdzie do
panelu, prawo wykonywania polecen na maszynie, na ktorej stoja tez CRM
VetFactory i panel isp4trucks. Cron nie wymaga ani tego ustepstwa, ani
uprawnien administratora.

Dlaczego kazde konto ma DWA wpisy w cronie: serwer chodzi w UTC, a tutejszy
cron nie zna ustawienia strefy (Ubuntu 22.04 nie ma CRON_TZ). Wolania sa wiec
dwa - o godzinie zimowej i letniej - a skrypt wybiera to wlasciwe, porownujac
czas warszawski z godzina docelowa konta. Dzienna blokada pilnuje, zeby drugie
wolanie nie pingowalo po raz drugi.

## Ktore konto to ktory warmup

| warmup | konto              | katalog konfiguracji na Macu | godzina |
|--------|--------------------|------------------------------|---------|
| acc1   | wiktor@specodit.pl | `~/.claude-acc2`             | 06:30   |
| acc2   | g.handzlik@specodit.pl (Gabrysia) | `~/.claude-acc4` | 06:30   |
| acc3   | joanna@specodit.pl | `~/.claude-acc3`             | 06:30   |

Numeracja katalogow na Macu jest przesunieta wzgledem numeracji warmupow -
to nie pomylka, tylko historia zakladania profili. Zrodlem prawdy o tym,
ktory katalog nalezy do kogo, jest konfiguracja przelacznika kont
(`~/.claude-accounts/config.json`).

Slot 4 przelacznika (`~/.claude`) to **to samo konto co acc1**, wiec nie ma
osobnego warmupu - drugi ping nie dolozylby nic do tego samego okna.

## Co gdzie lezy (VPS)

    /home/specodit/bin/claude-warmup          skrypt (zrodlo: n8n/claude-warmup.sh)
    /home/specodit/claude-warmup/tokens/      accN.token - jeden token na konto (chmod 600)
    /home/specodit/claude-warmup/homes/       osobny HOME kazdego konta
    /home/specodit/claude-warmup/logs/        accN.log
    /home/specodit/claude-warmup/smtp.env     dane SMTP do alertow (chmod 600)
    /home/specodit/.npm-global/bin/claude     CLI Claude Code

## Tokeny

Logowanie interaktywne daje token wazny kilka godzin plus token odswiezajacy,
ktory rotuje przy kazdym uzyciu - skopiowany na serwer wywroci sie po
popoludniu i zacznie bic sie o sesje z Makiem. Dlatego serwer dostaje osobny,
dlugowieczny token. Generowanie go NIE wylogowuje Cie lokalnie.

Na Macu, osobno dla kazdego konta:

    CLAUDE_CONFIG_DIR=/Users/specodit/.claude-acc2 claude setup-token   # acc1, Wiktor
    CLAUDE_CONFIG_DIR=/Users/specodit/.claude-acc4 claude setup-token   # acc2, Gabrysia
    CLAUDE_CONFIG_DIR=/Users/specodit/.claude-acc3 claude setup-token   # acc3, Joanna

UWAGA: o tym, ktore konto dostanie token, decyduje ZALOGOWANIE W PRZEGLADARCE,
nie katalog konfiguracji. Przy drugim i trzecim koncie otworz okno prywatne albo
osobny profil przegladarki, inaczej dostaniesz kolejny token tego samego konta.

Wynik wklej na VPS (przyklad dla acc2):

    ssh specodit@87.106.130.91 'umask 077; cat > /home/specodit/claude-warmup/tokens/acc2.token'

## Alert mailowy

Kazdy nieudany run wysyla mail na `wiktor@specodit.pl` (curl -> SMTP Gmail,
konto `biuro@specodit.pl`). Wczesniej sa 3 proby co 60 s, wiec jednorazowa
usterka sieci nie budzi alarmu. Niewazny token przerywa od razu - powtarzanie
go nie naprawi. Limit uzycia liczy sie jako sukces: token dziala, okno dotkniete.

## Reczne sprawdzenie

    ssh specodit@87.106.130.91 '/home/specodit/bin/claude-warmup acc1 --now; echo exit=$?'

Bez `--now` skrypt o innej porze dnia grzecznie wyjdzie, nie pingujac.

## Stary sposob (n8n)

Historycznie mial to odpalac przeplyw w n8n przez wezel Execute Command.
Zostal porzucony - powody wyzej.

## n8n 2.x blokuje Execute Command

Od wersji 2.0 n8n wylacza domyslnie dwa wezly: Execute Command i wyzwalacz
plikowy. W edytorze objawia sie to komunikatem "Install this node to use it",
mimo ze wezel jest zainstalowany. Odblokowanie samego Execute Command:

    sudo install -m 644 /home/specodit/nodes-exclude.conf /etc/systemd/system/n8n.service.d/nodes-exclude.conf
    sudo systemctl daemon-reload && sudo systemctl restart n8n

Plik `nodes-exclude.conf` (kopia w tym katalogu) zostawia wyzwalacz plikowy
nadal wylaczony - odblokowuje wylacznie to, czego potrzebuje warmup.
