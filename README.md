# Operation Windfall

A WWII air-combat game that runs in the browser. Take off from a carrier or an airstrip, fight enemy patrols,
bomb and strafe ground targets, and land again. Seven sorties across four theatres.

- Languages: English, Türkçe, Deutsch (chosen on the sortie board; the browser language is used on first visit)
- Controls: keyboard and mouse, touch, or a gamepad
- Installable: add it to the home screen on a phone, or install it from the address bar on desktop; it then runs full screen and offline

## Run it locally

No build step. Serve the folder with any static server:

```bash
python3 -m http.server 8080
```

Then open http://localhost:8080. The service worker only registers over HTTPS, so offline mode is active on the deployed site, not locally.

## Deploy

The project is a static site. On Vercel it deploys as-is (framework preset "Other", no build command); `vercel.json` sets the caching and security headers.

```bash
vercel --prod
```

When you release a new version, bump `VERSION` in `sw.js` so installed copies fetch the new files.

## Layout

| Path | What it is |
| --- | --- |
| `index.html` | The whole game: markup, styles and code |
| `vendor/three.min.js` | three.js r128 (MIT licence) |
| `manifest.webmanifest`, `icons/` | Web-app manifest and icons |
| `sw.js` | Service worker for offline play |
| `vercel.json` | Hosting headers |

## Adding a language

Text is written in English in the code and translated on its way to the page. In `index.html`, add an entry to `LANGS`,
then a column to every row of `DICT`, `RXT` and `BRIEFS`.

## Competition and shared sky (build 15)

The game runs offline as before until a Supabase project is wired in.

1. Create a Supabase project and run `supabase/migrations/0001_competition.sql` in it.
2. Enable **Anonymous sign-ins** (Authentication → Sign In / Providers).
3. Put the project URL and the publishable (anon) key into `NET.url` / `NET.key` in `index.html`.

Pilots then join with a name; points, upgrades and aircraft are kept on the server and changed only
through the SQL functions (`submit_score`, `buy_upgrade`, `buy_plane`). `tokens` is reserved for a
future purchased currency. Shared sky uses a Realtime broadcast channel per sortie and squadron code.
Scores are sanity-checked on the server (caps, rate limit) but are still reported by the client.
