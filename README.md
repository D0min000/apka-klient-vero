# Vero Studio – strona dla klientów i panel ekipy

- `index.html` – strona dla klientów (cennik, formularz zapytania).
- `panel/` – panel ekipy (logowanie Google, grafik, zapisy na role, wypłaty, zapytania, wysyłka wycen).
- `supabase/schema.sql` – baza danych i zabezpieczenia. `supabase/functions/send-quote/index.ts` – wysyłka maili z Gmaila studia.
- `config.js` – jedyny plik, który uzupełniasz po założeniu Supabase.

Nikt nie loguje się do Claude. Pracownicy wchodzą na `https://TWOJ-LOGIN.github.io/NAZWA-REPO/panel/`, klienci na `https://TWOJ-LOGIN.github.io/NAZWA-REPO/`.

## 1. GitHub (hosting strony)
1. Załóż konto na github.com. Kliknij **New repository**, nazwa np. `vero-studio`, widoczność **Public** (Pages w darmowym planie wymaga publicznego repo; w repo nie ma żadnych haseł).
2. **Add file → Upload files**: wrzuć całą zawartość tego folderu (razem z folderami `panel`, `assets`, `supabase`) i kliknij **Commit changes**.
3. **Settings → Pages**: Source = *Deploy from a branch*, Branch = `main`, folder `/ (root)`. Po minucie adres strony pojawi się na górze.

## 2. Supabase (baza i logowanie)
1. Załóż konto na supabase.com, **New project** (region: Frankfurt), ustaw hasło bazy i zapisz je.
2. **Project Settings → API**: skopiuj *Project URL* i klucz *anon / publishable*.
3. Otwórz `supabase/schema.sql`, w linii z `WPISZ_TU_SWOJ_ADRES@gmail.com` wpisz **swój adres Google, którym będziesz się logować jako właściciel**. Wklej cały plik w **SQL Editor** i kliknij **Run**.

## 3. Logowanie przez Google
1. console.cloud.google.com → nowy projekt → **APIs & Services → OAuth consent screen** (External, nazwa Vero Studio, Twój mail) → **Credentials → Create credentials → OAuth client ID → Web application**.
2. W *Authorized redirect URIs* wpisz `https://TWOJ-PROJEKT.supabase.co/auth/v1/callback` (adres projektu z kroku 2).
3. Skopiuj *Client ID* i *Client secret* do Supabase: **Authentication → Providers → Google** (włącz).
4. **Authentication → URL Configuration**: *Site URL* = `https://TWOJ-LOGIN.github.io/NAZWA-REPO/`, w *Redirect URLs* dodaj `https://TWOJ-LOGIN.github.io/NAZWA-REPO/panel/`.
5. **Authentication → Providers → Email**: wyłącz, żeby nikt nie zakładał kont hasłem.

## 4. Maile z Gmaila studia
1. Na koncie `vero.studiokontakt@gmail.com` włącz weryfikację dwuetapową, potem myaccount.google.com/apppasswords → utwórz hasło aplikacji (16 znaków).
2. Supabase → **Edge Functions → Secrets** dodaj: `GMAIL_USER` = `vero.studiokontakt@gmail.com`, `GMAIL_APP_PASSWORD` = to hasło. **Nie wpisuj go nigdzie indziej, ani do GitHuba.**
3. **Edge Functions → Deploy a new function → Via Editor**, nazwa dokładnie `send-quote`, wklej zawartość `supabase/functions/send-quote/index.ts`, wyłącz przełącznik *Verify JWT* (funkcja sama sprawdza, że pyta zalogowany właściciel) i kliknij **Deploy**.

## 5. Połączenie strony z bazą
Na GitHubie otwórz `config.js` (ikona ołówka) i wpisz *Project URL* oraz klucz anon. Zatwierdź zmianę. Nigdy nie wpisuj tu klucza `service_role`.

## 6. Test na żywo (zrób to razem z nami)
1. Wejdź na `/panel/` i zaloguj się swoim kontem Google: powinieneś zobaczyć panel właściciela z zakładką *Ekipa*.
2. Zaloguj kolegę z innego konta: zobaczy „Konto czeka na zatwierdzenie”. Zatwierdź go w zakładce *Ekipa*.
3. Dodaj sesję, zapisz się na rolę z konta kolegi.
4. Na stronie głównej wyślij testowe zapytanie na swój drugi adres e-mail. W panelu: *Zapytania* → wpisz ceny → *Zapisz wycenę* → *Wyślij mail do klienta*. Sprawdź skrzynkę i folder spamu.
5. *Klient potwierdził: utwórz sesję* – sesja z potrzebnymi rolami ma się pojawić w grafiku.

Panel odświeża dane co ok. 20 sekund (nie w czasie rzeczywistym).

## Testy automatyczne (dla programisty)
`tests/` zawiera testy bazy (87), funkcji maili (40) i całej aplikacji w przeglądarce (63). Uruchamiane lokalnie na atrapie Supabase.
