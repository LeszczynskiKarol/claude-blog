# claude-blog

Posty na blog **matury-online.pl** generowane przez **Claude Code**
(subskrypcja, nie API) — **lokalnie**, codziennie, jeden post per
uruchomienie. Output ląduje bezpośrednio w katalogu Astro projektu
(`frontend/src/content/blog/*.md`). Stan trwa między sesjami przez
`_index.json` + `blog_topics.json`. Opcjonalne powiadomienia Slack.

Wzorowane na bliźniaczym projekcie `D:\claude-streszczenia\`.

## Setup

Wymagania:
- Claude Code CLI (`claude` w terminalu)
- PowerShell 5.1+
- Działający, zalogowany `claude` (token cached — odpal raz `claude`
  ręcznie i autoryzuj)

### 1. Sprawdź ścieżkę outputu

`config.json` ma `output_path` ustawione na
`D:\matury-online.pl\frontend\src\content\blog`. Jeśli projekt Astro
masz gdzie indziej — popraw.

### 2. (Opcjonalnie) Slack webhook

Stwórz `.slack-webhook` w korzeniu (jedna linia z URL):
```
https://hooks.slack.com/services/XXXX/YYYY/ZZZZ
```
Wzór: `.slack-webhook.example`. Plik jest w `.gitignore`.

Bez webhooka — notifications są no-op (cisza, OK).

### 3. Test interaktywny

```powershell
cd D:\claude-blog
claude
```

Wpisz `dalej`. CC sam:
- odczyta plan z `blog_topics.json`
- zsynchronizuje rejestr z istniejącymi postami w katalogu Astro
- wybierze najwyższy priority pending
- napisze post, zapisze .md do katalogu Astro
- zaktualizuje `_index.json` i `blog_topics.json`
- (opcjonalnie) wyśle Slacka

### 4. Automatyzacja codzienna

Jednorazowo:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-task.ps1
```

Co to robi:
- Rejestruje task **MaturyBlog-Daily** w Windows Task Scheduler
- Trigger: codziennie o **06:00** (zmień w `install-task.ps1` jeśli
  chcesz inną godzinę → odpal ponownie)
- Akcja: `scripts\run-daily.ps1` → `claude -p "dalej"` + log + Slack

Test od razu:
```powershell
Start-ScheduledTask -TaskName 'MaturyBlog-Daily'
type logs\run-2026-05-21.log
```

Status:
```powershell
Get-ScheduledTask -TaskName 'MaturyBlog-Daily' | Get-ScheduledTaskInfo
```

Usunięcie:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall-task.ps1
```

**Wymaga zalogowanej sesji Windows o 06:00** — task odpala się w
kontekście użytkownika. `claude` potrzebuje twojego auth.

## Polecenia w Claude Code

| Co piszę | Co robi |
|---|---|
| `dalej` / `kontynuuj` / `pisz` / `nowy post` / `lec z blogiem` | bierze topic z najwyższym priority spośród pending, pisze, zapisuje, aktualizuje stan |
| `pisz <id>` | wymusza konkretny topic (musi być pending) |
| `status` | tabela: cluster × (done/pending/skipped) |
| `lista` | top 10 pending posortowanych po priority |
| `dodaj temat <opis>` | tworzy nowy topic-record z priority 6, appenduje do `blog_topics.topics` |
| `pomiń <id>` | status pending → skipped |
| `od nowa <id>` | wymaga potwierdzenia. Usuwa plik .md i wraca status do pending |
| `audyt <id>` | pokaż frontmatter zapisanego .md |

## Co dostaniesz na Slack

**Nowy post** (zwiększenie liczby wpisów w `_index.json.posts`):
- Tytuł, slug, klaster, kategoria, przedmiot
- Liczba słów, liczba linków wewnętrznych
- Ścieżka do pliku .md
- URL publiczny po deploy (https://www.matury-online.pl/blog/<slug>)
- Stan kolejki: ile pending łącznie, ile z priority ≥9

**Błąd**:
- Host, czas, opis błędu, ścieżka do logu

**Cisza = OK ale nic nowego** (np. nie był pending, lub plan pusty).

## Struktura

```
D:\claude-blog\
├── CLAUDE.md                # auto-load przez CC, główny prompt-skill
├── README.md                # ten plik
├── config.json              # ścieżka outputu + meta marketing
├── _index.json              # rejestr opublikowanych postów
├── blog_topics.json         # plan / kolejka tematów
├── .slack-webhook           # webhook URL (gitignored, opcjonalny)
├── .slack-webhook.example   # wzór
├── .gitignore
├── scripts/
│   ├── run-daily.ps1        # odpalany przez Task Scheduler
│   ├── install-task.ps1     # rejestruje zadanie
│   ├── uninstall-task.ps1   # usuwa zadanie
│   └── notify-slack.ps1     # funkcje Slack (dot-source)
└── logs/                    # auto: run-YYYY-MM-DD.log
```

## Jak rozszerzać plan

Plan w `blog_topics.json` jest **żywy**:
- możesz dopisać nowe topiki ręcznie (kopiuj schema z `_schema` na początku pliku, dorzucaj do `topics[]`)
- możesz polecić CC dopisać przez `dodaj temat <opis>`
- CC **sam** może dopisać do 2 topików per uruchomienie (po
  napisaniu posta robi refleksję — jeśli zauważył lukę, append)

Topiki dodane przez CC mają pole `added_by_writer: "<slug posta>"`
i `added_at: "<date>"` — łatwo je odsiać w audycie.

## Co NIE dzieje się automatycznie

- **Brak commitu git, brak pusha, brak deploy.** Po wygenerowaniu
  pliku .md, post czeka w katalogu Astro do twojego ręcznego review
  + commit + deploy. Tak jest celowo — chcesz przejrzeć każdy post
  zanim trafi do produkcji.

- **Brak upload na VPS-a.** Wszystko lokalnie. Po review możesz
  zrobić `git push` z projektu `matury-online.pl` i CI/CD postawi.

- **Brak modyfikacji istniejących postów.** CC tworzy nowe pliki.
  Jeśli chcesz przepisać istniejący — `od nowa <slug>` (wymaga
  potwierdzenia, usuwa plik i wraca status na pending).

## Diagnostyka

Task nie odpala się o 06:00:
1. Komputer włączony i zalogowany sesją Windows?
2. Log `logs\run-YYYY-MM-DD.log` — brak = task nie odpalił
3. `Get-ScheduledTask -TaskName 'MaturyBlog-Daily' | Get-ScheduledTaskInfo`
   — `LastTaskResult` 0 = OK
4. Ręczny test: `Start-ScheduledTask -TaskName 'MaturyBlog-Daily'`

`claude` pisze w logu "auth required":
- odpal `claude` ręcznie z dowolnego katalogu, autoryzuj. Token cached.

CC nie znajduje katalogu outputu:
- sprawdź `config.json` → `output_path` (powinno wskazywać na
  istniejący katalog `frontend/src/content/blog/` w projekcie Astro)
- ścieżka MUSI mieć podwójne backslashe (`D:\\...`) w JSON-ie

Slack nie dostaje:
- `Test-Path .slack-webhook` powinno zwrócić True
- log powinien mieć linijkę `Sending Slack new-post notification for: <slug>`
- test ręczny:
  ```powershell
  . scripts\notify-slack.ps1
  Send-SlackMessage -Text 'test' -ProjectDir (Get-Location).Path
  ```
