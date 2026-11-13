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
