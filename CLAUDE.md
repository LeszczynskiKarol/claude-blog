# CLAUDE.md — projekt: blog matury-online.pl (auto-pisanie)

To jest projekt do generowania postów blogowych dla **matury-online.pl** —
jeden post per uruchomienie. Działasz w katalogu projektu (cwd to ten
folder). Stan trwa między sesjami przez `_index.json` (rejestr opublikowanych)
i `blog_topics.json` (plan / kolejka).

Output (gotowe pliki .md) zapisujesz do projektu Astro pod ścieżką
z `config.json`, **nie** do katalogu tego projektu.

## Trigger frazy

Gdy user pisze jedno z:

- `dalej`
- `kontynuuj`
- `pisz`
- `nowy post`
- `lec z blogiem`
- `status`
- `lista` (10 najwyżej priorytetowych pending)
- `dodaj temat <opis>` — append nowego topicu
- `pomiń <id>` — status pending → skipped
- `od nowa <id>` — wymaga POTWIERDZENIA; usuwa plik .md, status done → pending
- `audyt <id>` — pokaż frontmatter konkretnego posta

— wykonujesz workflow **bez dopytywania**. To są frazy operacyjne. Cron
odpala `claude -p "dalej"` codziennie — musisz działać autonomicznie.

## Struktura projektu

```
D:\claude-blog-matury-online\
├── CLAUDE.md             ← ten plik (auto-load przez Claude Code)
├── README.md             ← dla człowieka
├── config.json           ← ścieżka outputu + meta projektu (read-only z punktu CC)
├── _index.json           ← REJESTR opublikowanych (slug → meta, internal links)
├── blog_topics.json      ← PLAN: kolejka tematów + ukończone
├── .slack-webhook        ← (opcjonalny) URL webhooka — gitignored
├── scripts/
│   ├── run-daily.ps1     ← Task Scheduler trigger
│   ├── install-task.ps1  ← rejestracja zadania
│   ├── uninstall-task.ps1
│   └── notify-slack.ps1  ← dot-source z run-daily
└── logs/                 ← auto: run-YYYY-MM-DD.log
```

Output ląduje pod `<output_path>/<id>.md` gdzie `output_path` z `config.json`,
a `<id>` to slug z `blog_topics.json`. Pliki istnieją również tam — to one
są źródłem prawdy dla rzeczywistego stanu publikacji (CC powinien pre-flight
sprawdzić ich obecność).

## Tools których używasz

- **Read** — `config.json`, `_index.json`, `blog_topics.json`, frontmattery
  istniejących postów, ewentualnie pełne starsze posty jeśli chcesz dokładnie
  obejrzeć styl
- **Write** — całe pliki: nowy post .md, overwrite stanu (`_index.json`,
  `blog_topics.json`). Pliki stanu są małe (<200 KB) — overwrite OK.
- **Edit** — nie używaj na plikach stanu. Dopuszczalne tylko dla literówek
  w gotowym .md jeśli userownik o to prosi.
- **Glob** — `<output_path>/*.md` żeby zobaczyć listę już opublikowanych
  postów przed wyborem internal links.
- **Bash** — opcjonalnie do `dir`, `Get-Date`. Nie ruszaj git.

Nie używaj zewnętrznych MCP serverów. Wszystko ma być natywne CC tools.

## Stan: dwa pliki JSON

### `config.json` (read-only z punktu CC, ustawione raz)

```json
{
  "output_path": "D:\\matury-online.pl\\frontend\\src\\content\\blog",
  "site_base_url": "https://www.matury-online.pl",
  "default_author": "Matury Online",
  "post_count_marketing": "9 000+",
  "subject_count_marketing": "11",
  "platform_pricing_marketing": "49 zł/mies."
}
```

### `_index.json` — REJESTR opublikowanych postów

```json
{
  "last_published": "wzory-matematyczne-matura-pdf",
  "posts": {
    "wzory-matematyczne-matura-pdf": {
      "title": "Wzory matematyczne na maturze — pełna ściąga (PDF)",
      "cluster": "F",
      "category": "PORADNIK",
      "subjectSlug": "matematyka",
      "publishedAt": "2026-05-22",
      "wordCount": 2632,
      "filePath": "D:\\matury-online.pl\\frontend\\src\\content\\blog\\wzory-matematyczne-matura-pdf.md",
      "internalLinksOut": ["jak-przygotowac-sie-z-matematyki", "progi-punktacja"],
      "primaryKeyword": "wzory matematyczne matura"
    }
  }
}
```

`internalLinksOut` zapamiętuje, do których innych postów linkowałeś z tego
— pomaga w przyszłości znajdować kandydatów do *odwrotnego* linkowania
(jak będziesz pisał `progi-punktacja-2`, możesz wstecznie zalinkować
do `wzory-matematyczne-matura-pdf`).

### `blog_topics.json` — PLAN

Schema opisany jest w samym pliku (`_schema` na początku). Każdy element
w `topics[]` ma `status: "pending" | "done" | "skipped"`. Po napisaniu
posta:
- ustaw `status: "done"`
- dodaj pola: `completed_at` (ISO date), `output_path` (pełna ścieżka),
  `actual_word_count`, `internal_links_used` (lista slugów do których
  zalinkowałeś)

## Workflow — jeden post per uruchomienie

### 1. ZAWSZE: pre-flight read

Równolegle (jedna wiadomość, trzy Read'y):
- **Read** `config.json`
- **Read** `_index.json`
- **Read** `blog_topics.json`

Jeśli `_index.json` nie istnieje → **Write** `{"posts": {}}`.
Jeśli `config.json` nie istnieje → STOP, raportuj userowi.

### 2. Synchronizacja z fizycznym stanem

Tool: **Glob** `<output_path>/*.md`

Dla każdego pliku, którego slug NIE jest w `_index.json.posts`:
- **Read** jego frontmatter (limit 30 linijek wystarczy)
- Dodaj wpis do `_index.json.posts` z wnioskowanymi metadanymi
- Oznacz w `blog_topics.json` że ten topic jest już done (jeśli istnieje)

Jeśli `_index.json` zawiera slug, którego pliku NIE ma w fizycznej lokalizacji:
- usuń wpis z `_index.json` (lub oznacz jako `orphan: true`)
- raportuj userowi w outpucie

To Cię chroni przed double-publishingiem, gdy user ręcznie utworzył post.

### 3. Wybór tematu (gdy trigger to `dalej` / `pisz` / `nowy post`)

Z `blog_topics.json.topics`:
1. Filtruj `status == "pending"`
2. Sortuj po `priority` malejąco
3. Tie-breaker: po `cluster` (A→H, żeby równomiernie pokrywać klastry)
4. Tie-breaker 2: po `id` alfabetycznie
5. Wybierz pierwszy z listy → to jest twój `topic`

Specjalne triggery:
- `pisz <id>` → wymuś konkretny topic (musi być `pending`, inaczej STOP)
- `status` → wymień tabelę: cluster | done | pending | skipped; STOP
- `lista` → wymień 10 pending z najwyższym priority; STOP
- `dodaj temat <opis>` → ułóż nowy topic-record (zgodnie ze schemą),
  ustaw priority 6 default (chyba że user mówi inaczej), append do
  `topics[]`, **Write** `blog_topics.json`; STOP
- `pomiń <id>` → status pending → skipped, Write; STOP
- `od nowa <id>` → spytaj o potwierdzenie, po `tak` → usuń plik .md,
  status done → pending, Write; STOP
- `audyt <id>` → **Read** frontmatter pliku .md, wymień; STOP

### 4. Reverse research — co już mamy do linkowania

To jest **kluczowy krok jakościowy**. PRZED pisaniem chcesz wiedzieć,
do których z istniejących postów możesz zalinkować.

a) Z `_index.json` masz pełną listę opublikowanych slugów + ich tytułów
   i klastrów. To Twój *bank linków*.

b) Z `topic.internal_link_hints` masz *sugestie* od plannera. ALE niektóre
   z nich mogą jeszcze nie istnieć (są dopiero w kolejce). Zweryfikuj:
   dla każdego hinta sprawdź czy slug jest w `_index.json.posts` — używasz
   tylko tych co istnieją.

c) Jeśli mniej niż 3 linki z hintów istnieją, dobierz ekstra z `_index.json`:
   preferuj posty z tego samego `cluster` lub tego samego `subjectSlug`.

d) **Jeśli istniejących postów jest <5 w sumie** — link tylko do oryginalnych
   6 postów (te które były ręcznie napisane: `jak-zdac-mature-2026`,
   `harmonogram-2026`, `progi-punktacja`, `jak-wyglada-przebiega-matura`,
   `jak-przygotowac-sie-do-matury`, `wyniki-matur`) plus do strony
   produktowej `cta_target`. To naturalne na wczesnym etapie.

Cel: w gotowym poście chcesz 3-5 wewnętrznych linków do innych postów
+ 1 link do `cta_target` (strona produktowa).

### 5. Pisanie posta — generuj kompletny .md

Frontmatter (YAML) zgodny ze schematem `frontend/src/content/config.ts`
projektu Astro:

```markdown
---
title: "<topic.title>"
excerpt: "<2-3 zdania, ~150-200 znaków, MUSI zawierać primary_keyword>"
metaTitle: "<topic.title> | matury-online.pl"
metaDescription: "<150-160 znaków, MUSI zawierać primary_keyword>"
category: "<topic.category>"
tags: ["matura-2026", "<3-5 dodatkowych z topic.secondary_keywords + cluster>"]
subjectSlug: <topic.subjectSlug lub usunąć linijkę gdy null>
publishedAt: <ISO date dzisiejsza>
readTimeMinutes: <round(target_words / 220)>
authorName: "Matury Online"
---
```

Treść — patrz sekcje jakości niżej. Długość: `topic.target_words ± 20%`.

### 6. Zapis posta

**Write** do `<output_path>/<topic.id>.md` (pełna absolutna ścieżka
z `config.output_path`).

### 6.5. Dobór zdjęcia nagłówkowego — TWOIM wzrokiem (na subskrypcji, NIE API)

Każdy post dostaje zdjęcie z Pexels, które **sam wybierasz oglądając kandydatów**
(backend nie używa płatnego AI-vision). Wymaga env: `$MATURY_API_BASE`
(np. `https://www.matury-online.pl` lub `https://api.torweb.pl` na testy) i
`$MATURY_API_BEARER`. Jeśli env brak — pomiń ten krok (post zostaje bez zdjęcia).

1. Pobierz kandydatów (query: 2-4 ang. słowa wg przedmiotu/tematu — `chemia`→
   „chemistry laboratory", `polski`→„books reading", ogólny→„students studying"):

```bash
curl -s -G -H "Authorization: Bearer $MATURY_API_BEARER" \
  --data-urlencode "query=european students studying" --data-urlencode "max=8" \
  "$MATURY_API_BASE/api/internal/news-image-candidates"
```

2. **Obejrzyj `viewUrl` kandydatów** (`curl <viewUrl> -o /tmp/c.jpg`, potem **Read** `/tmp/c.jpg`).
3. Wybierz JEDNEGO: białi/europejscy nastolatkowie/młodzi dorośli ALBO sam obiekt
   (lab, książki, tablica). Odrzuć dzieci, osoby nieeuropejskie, słabą jakość.
4. Zapisz wybrane na S3 i odbierz stabilny URL:

```bash
curl -s -X POST -H "Authorization: Bearer $MATURY_API_BEARER" -H "Content-Type: application/json" \
  -d '{"slug":"<topic.id>","webpUrl":"<webpUrl wybranego>","author":"<author>","sourceUrl":"<sourceUrl>","photoId":<photoId>}' \
  "$MATURY_API_BASE/api/internal/store-blog-image"
```

Odpowiedź: `{heroImage, heroImageAuthor, heroImageLicense, heroImageLicenseUrl, heroImageSourceUrl}`.

5. **Dopisz te pola do frontmattera** posta (Edit/Write .md) — patrz §B. Gdy nic
   nie pasuje albo brak env → pomiń, zostaw bez `heroImage`.

### 7. Update stanu — OBIE listy

**Read** `blog_topics.json`, znajdź topic po `id`, zmień:
- `status: "done"`
- dodaj `completed_at: "<today ISO>"`
- dodaj `output_path: "<full path>"`
- dodaj `actual_word_count: <int>`
- dodaj `internal_links_used: [<slugs>]`

**Write** `blog_topics.json` (cały plik).

**Read** `_index.json`, dodaj wpis:
```json
{
  "<topic.id>": {
    "title": "<topic.title>",
    "cluster": "<topic.cluster>",
    "category": "<topic.category>",
    "subjectSlug": "<topic.subjectSlug>",
    "publishedAt": "<today>",
    "wordCount": <int>,
    "filePath": "<full path>",
    "internalLinksOut": [<slugs>],
    "primaryKeyword": "<topic.primary_keyword>"
  }
}
```

I ustaw `"last_published": "<topic.id>"`. **Write** `_index.json`.

### 8. Refleksja — czy w trakcie wpadł pomysł na nowy temat?

Po napisaniu posta przejrzyj go mentalnie. Czy w trakcie pisania
zauważyłeś:
- temat, do którego chciałeś zalinkować, ale go nie ma w `blog_topics`?
- lukę w klastrze (np. brakuje pillaru, do którego naturalnie wchodzą
  Twoje argumenty)?
- aktualny news / sezonowy hak, którego nikt nie wziął?

Jeśli tak — **dopisz nowy topic do `blog_topics.json.topics[]`**:
- ustaw `priority` realistycznie (5-7 dla "fajnie by było", 8 dla
  "to faktycznie luka")
- wypełnij wszystkie pola (id, cluster, category, subjectSlug, title,
  target_words, intent, primary_keyword, secondary_keywords, must_cover,
  internal_link_hints, cta_target, status: "pending")
- dopisz `"added_by_writer": "<id posta który spowodował"`
  i `"added_at": "<today>"` — to dla audytu

**Write** `blog_topics.json` ponownie.

Limit: max 2 nowe topiki per run, nie spamuj.

### 9. Raport końcowy

Krótko (5-8 linijek) do stdout:
- `OK <id>` — slug nowego posta
- `Plik: <path>`
- `Słów: <count>`
- `Klaster: <X> — <name>`
- `Linki wewnętrzne: <count>`
- `Pozostało pending: <count> (priority 10: <n>, 9: <n>, ...)`
- jeśli dodałeś nowy topic: `Nowy temat: <id>`

To pojawi się w logu i wyzwala Slack.

STOP. Jeden post na uruchomienie.

## Jakość posta — KRYTERIA UNIWERSALNE

### A. Trzymaj się `must_cover` (audyt OBOWIĄZKOWY przed Write)

Każdy punkt z `topic.must_cover` MUSI mieć faktyczne odbicie w treści.
Jeśli zauważysz, że nie pokryłeś któregoś — dopisz ten fragment lub
dorzuć osobny akapit. Tylko gdy faktycznie nie pasuje (np. user już
rozwinął temat gdzie indziej) — pomiń, ale zaznacz w raporcie końcowym.

Audyt: PRZED zapisem **mentalnie** przejdź listę `must_cover` i odhacz
każdy punkt. Wyłącznie potem **Write**.

### B. Frontmatter — sztywne wymogi

- `title` = `topic.title` 1:1 (nie ulepszaj — może być różnica między H1
  w treści a tytułem we frontmatter, ale dla SEO konsekwentnie używaj
  tego samego)
- `excerpt` MUSI zawierać `primary_keyword` (Google wyświetla excerpt
  jako fallback dla meta description)
- `metaDescription` MUSI zawierać `primary_keyword` w pierwszej połowie
- `metaTitle` MUSI zawierać `primary_keyword` lub jego mocną wariację
- `tags` mają być slugami kebab-case (matura-2026, wos, poradnik)
- `publishedAt` — dzisiejsza data ISO (lokalna)
- `readTimeMinutes` — `round(actual_word_count / 220)` (220 = średnie tempo
  czytania polskiego per minutę)
- `subjectSlug` — jeśli `topic.subjectSlug` to `null`, ZUPEŁNIE pomiń
  linijkę (nie wpisuj `null` — schema Astro/Zod może mieć z tym
  problem, lepiej `.optional()`)
- **`heroImage*`** (opcjonalne, z kroku §6.5) — jeśli dobrałeś zdjęcie, dopisz
  pola zwrócone przez `/api/internal/store-blog-image`, każde jako string w
  cudzysłowie:
  ```yaml
  heroImage: "https://...s3...blog/<slug>-....webp"
  heroImageAuthor: "Imię Nazwisko"
  heroImageLicense: "Pexels"
  heroImageLicenseUrl: "https://www.pexels.com/license/"
  heroImageSourceUrl: "https://www.pexels.com/photo/...-12345/"
  ```
  Gdy nie dobrałeś zdjęcia — pomiń wszystkie te linijki.

### C. Struktura treści

1. **Wstęp (1 akapit, 100-180 słów)** — bez nagłówka. MUSI:
   - zawierać `primary_keyword` w pierwszych 100 słowach
   - postawić problem (komu to potrzebne, co czytelnik znajdzie)
   - nie zaczynać od "Witaj", "Cześć", "Drogi maturzysto" — wprost
     do meritum

2. **H2 — główne sekcje (5-8 sztuk)**. Każda:
   - tytuł zawiera słowo-klucz wariantowo
   - 2-5 akapitów prozą
   - jeśli to lista 5+ rzeczy → tabela markdown (CKE-style: punktacja,
     terminy, porównania)

3. **H3 — podsekcje (opcjonalnie)** — używaj kiedy H2 robi się długie
   i potrzebuje sub-tematycznego podziału

4. **Blockquote `>` z `**Uwaga:**` lub `**Wskazówka:**`** — 1-2 sztuki
   w poście dla wizualnego rytmu (wzorem 6 istniejących postów)

5. **Tabele markdown** — wszędzie, gdzie chcesz pokazać porównanie,
   harmonogram, punktację, listę z 2+ kolumnami. Tabele dobrze rankują
   w Google's rich snippets.

6. **FAQ — opcjonalne H2 "Najczęstsze pytania o ..." z H3-pytaniami** —
   stosuj, gdy long-tail keywords sugerują pytania (jak w `progi-punktacja`).
   FAQ schema = większa szansa na rich snippet.

7. **Zakończenie / "Podsumowanie"** — H2 ostatnie. 1-2 akapity. Powtórz
   1× primary keyword. Link do platformy organicznie wpleciony (cta_target).

### D. Internal linking

- **3-5 linków do innych postów** rozsianych po treści (nie w
  zakończeniu kupą)
- każdy link jako `[anchor opisowy](/<slug>)` — np.
  `[Ile procent na maturze, żeby zdać?](/blog/progi-punktacja)`
- **NIE** linkuj generic "kliknij tutaj" — anchor MUSI zawierać słowa
  kluczowe linkowanego posta
- **1 link do `cta_target`** organicznie w treści (poza wbudowanym CTA
  z layoutu Astro). Przykład: jeśli `cta_target` to `/matematyka`,
  zlinkuj zdanie typu "ćwicz [zadania z matematyki](/matematyka)
  z natychmiastowym feedbackiem"

### E. SEO on-page

- `primary_keyword` w: H1 (frontmatter title), pierwszym akapicie,
  1-2 H2, meta description, excerpt
- `secondary_keywords` posypane naturalnie po treści (nie wymuszone)
- NIE keyword-stuff. Google to wykrywa i karze. Jak naturalnie wpadnie
  4-6 razy `primary_keyword` w treści 2500 słów — wystarczy.
- Pierwsza linia po H1 (excerpt → ale wbudowanym) musi semantycznie
  domykać query

### F. Ton i styl

- Polski, profesjonalny, **konkretny**. Bez wody. Bez "wiele osób się
  zastanawia".
- Per "ty" do czytelnika (jak w istniejących postach). Nie "Państwo".
- Liczby > ogólniki: "8 lipca 2026" zamiast "w lipcu", "180 minut"
  zamiast "trzy godziny".
- **Daty zawsze pełne**: "8 lipca 2026" nie "8.07".
- **Procenty**: "30%" nie "trzydzieści procent".
- **LaTeX/wzory matematyczne**: jeśli post jest o matematyce/fizyce/chemii
  i wymaga wzorów, używaj `$wzór$` (inline) lub `$$wzór$$` (block).
  Liczby z przecinkiem: `$1{,}5$` (z nawiasami klamrowymi, bo KaTeX
  inaczej traktuje przecinek jako separator). Chemia: `$\ce{H2SO4}$`
  (mhchem) — w stringu .md piszesz raz backslash, nie podwójnie.
- **Cytaty CKE**: traktuj jak źródło autorytatywne. Zawsze podawaj
  podstawę ("zgodnie z komunikatem dyrektora CKE z 20 sierpnia 2025 r.").
- Unikaj angielskich kalkek ("delivery", "feature", "experience")
  poza kontekstem branżowym (informatyka — OK).

### G. Marketingowa wzmianka platformy

Dokładnie **jeden akapit** w treści (gdzieś w drugiej połowie,
NIE w zakończeniu) wzmiankuje produktowo:

> Wzorzec: 1-2 zdania o tym jak platforma rozwiązuje problem o którym
> piszesz, z 1 organicznym linkiem do `cta_target`. Liczby z
> `config.json` (post_count_marketing, subject_count_marketing,
> platform_pricing_marketing) — używaj ich zamiast hardkodowanych.

Astro i tak doda na końcu duży gradient-CTA box. Twój inline
akapit ma być subtelniejszy, blisko meritum.

### H. Audyt PRZED Write

Listę:
1. Czy frontmatter ma wszystkie pola wymagane przez schema?
2. Czy `primary_keyword` jest w H1 + meta + pierwszym akapicie?
3. Czy każdy punkt `must_cover` ma odbicie w treści?
4. Czy 3-5 linków wewnętrznych jest wstawione?
5. Czy link do `cta_target` jest organiczny (nie zlepiony w PS)?
6. Czy długość mieści się w `target_words ± 20%`?
7. Czy są przynajmniej 2 tabele lub 1 tabela + 2 listy?
8. Czy nie ma "Witaj maturzysto", "Drogi czytelniku", "Mam nadzieję,
   że ten artykuł" — jeśli tak, **wyrzuć**

Jeśli "nie" na cokolwiek — **POPRAW** przed zapisem.

## Anti-patterns (NIGDY)

- **NIE** generuj postów z innego klastra niż blog_topics — używaj
  wyłącznie zaplanowanych tematów (z wyjątkiem `dodaj temat <opis>`)
- **NIE** pisz dwóch postów per uruchomienie — limit twardy 1 post
- **NIE** edytuj `_index.json` przez Edit (zawsze Read → modify → Write)
- **NIE** publikuj posta jeśli pominąłeś więcej niż 1 punkt z `must_cover`
  — STOP i raportuj userowi
- **NIE** zmyślaj statystyk ("85% maturzystów") — używaj liczb z
  istniejących postów albo dropuj, jeśli nie masz źródła
- **NIE** wstawiaj zdjęć ani nie linkuj zewnętrznie do nieoficjalnych
  źródeł. Zewnętrzne linki TYLKO do: cke.gov.pl, ckos.gov.pl,
  ziu.gov.pl, men.gov.pl, oke.[gdansk/warszawa/lodz/...].pl. Te
  domeny są bezpieczne i autorytetowe.
- **NIE** linkuj do nieistniejących slugów — zweryfikuj przed
  każdym `[anchor](/blog/<slug>)` że slug jest w `_index.json` LUB
  to jeden z 6 oryginalnych: `jak-zdac-mature-2026`,
  `harmonogram-2026`, `progi-punktacja`, `jak-wyglada-przebiega-matura`,
  `jak-przygotowac-sie-do-matury`, `wyniki-matur`
- **NIE** pisz wstępu typu "W tym artykule dowiesz się..." — Google
  nie lubi mety, czytelnik też. Wstęp = problem + obietnica.
- **NIE** dodawaj autora innego niż "Matury Online"
- **NIE** używaj emoji w treści posta (nawet jeśli ktoś prosi —
  emoji łamią rytm SEO i wyglądają nieprofesjonalnie). Wyjątek:
  jeśli post jest o emoji/Unicode (nie planowany)
- **NIE** dopisuj `<script>`, `<iframe>`, ani innych HTML poza standardem
  markdown
- **NIE** twórz kopii zapasowej `_index.json.bak` ani innych zaśmiecaczy

## Pierwszy run — przykład

User: `dalej` (albo cron odpala `claude -p "dalej"`)

Ty:
1. **Read** `config.json` + `_index.json` + `blog_topics.json`
   (równolegle, jedna wiadomość)
2. **Glob** `D:/matury-online.pl/frontend/src/content/blog/*.md`
3. Wnioskujesz: 6 istniejących postów, 0 w `_index.json` → sync
4. Dla każdego z 6 fizycznych: **Read** frontmatter (limit 25 linii) →
   ewentualnie 6 równoległych Read'ów (jedna wiadomość)
5. **Write** `_index.json` z 6 wpisami
6. Wybór: filtr `pending`, sort by priority desc → pierwszy to np.
   `jak-pisac-wypracowanie-maturalne` (priority 10)
7. Reverse-research: hintsy to `progi-punktacja`, `jak-przygotowac-sie-z-polskiego`,
   `konteksty-w-wypracowaniu`, `srodki-stylistyczne-polski`. Z tego
   istnieje 1 (`progi-punktacja`). Plus 6 oryginalnych zawsze
   dostępnych. Dobieram dodatkowo `jak-zdac-mature-2026` i
   `harmonogram-2026` z oryginalnych.
8. Piszę post (3500 słów, target). Audyt 8 punktów.
9. **Write** `<output_path>/jak-pisac-wypracowanie-maturalne.md`
10. **Read** `blog_topics.json` → modyfikuję topic → **Write**
11. **Read** `_index.json` → dodaję wpis → **Write**
12. Refleksja: w trakcie pisania zauważyłem brak posta typu
    "Najczęstsze błędy ortograficzne na maturze z polskiego" —
    dopisuję topic z priority 6
13. **Write** `blog_topics.json` ponownie
14. Raport końcowy → log → Slack

## Druga sesja — kontynuacja

User otwiera nowy chat w CC w tym katalogu. Pisze `dalej`.

Ty:
1. **Read** `config.json` + `_index.json` + `blog_topics.json`
   (równolegle)
2. **Glob** outputu — 7 plików (6 oryginalnych + 1 z poprzedniego runu)
3. Sync: `_index.json` ma już 7 wpisów, nic nowego do dodania
4. Wybór: kolejny pending priority 10, np. `wzory-matematyczne-matura-pdf`
5. Reverse-research → tym razem masz już 7 do wyboru → lepsze
   linkowanie
6. Piszesz, zapisujesz, updateujesz stan. STOP.

## Recovery po przerwaniu

Jeśli `_index.json` i `blog_topics.json` rozjadą się (np. zapisałeś
status done, ale plik .md się nie utworzył):

1. Glob outputu → fizyczna prawda
2. Dla każdego topica ze `status: done` ale BRAK pliku:
   - status `done` → `pending`
   - usuń pola `completed_at`, `output_path`, `actual_word_count`
3. Dla każdego pliku BEZ wpisu w `_index.json`:
   - Read frontmatter → dodaj wpis
4. Powiedz userowi co naprawiłeś, dopiero potem kontynuuj `dalej`.

## Wskazówki techniczne

### Polskie znaki
Read/Write/Edit operują w UTF-8 natywnie. Nie kombinuj z code page.

### Trust the write
Po Write NIE czytaj pliku "dla weryfikacji" — tool zwrócił sukces =
zapisane. Idź dalej.

### Long content w jednym Write
Post ~3000 słów to ~25 KB. Write radzi sobie z tym bez problemu.
Generuj cały plik raz, nie składaj częściami.

### Data dzisiejsza
Jeśli potrzebujesz dzisiejszej daty ISO, użyj **Bash**
`Get-Date -Format "yyyy-MM-dd"` (PowerShell) lub `date +%Y-%m-%d`
(bash). Nie zgaduj.

### Słowa w pliku
Po Write żeby policzyć `actual_word_count`, użyj **Bash**:
```powershell
(Get-Content '<path>' -Raw -Encoding UTF8 -split '\s+' |
  Where-Object { $_ -ne '' }).Count
```
Lub policzyć w głowie (z dokładnością ±5%) i tyle. Liczba ma znaczenie
głównie do `readTimeMinutes`.
