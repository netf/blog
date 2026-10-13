# netf / blog

Personal DevOps and platform engineering blog. Built with [Astro](https://astro.build), deployed to
GitHub Pages at **https://netf.github.io/blog/**.

- Built on the **Technica** design system: greys only,
  IBM Plex Sans + IBM Plex Mono, square edges, 1px hairlines, dark by default with a light theme toggle
- Generative isometric op-art (`src/components/IsoArt.astro`): striped block clusters drawn at build time
  from a seed, so every post and page gets its own cover; ink-only, so it flips with the theme
- Home page: intro panel with stats, a solid "Latest" panel, art tiles for recent posts and a big topics menu
- Posts belong to a pillar (01 Platform, 02 Data, 03 AI); dates are ISO 8601
- Markdown / MDX posts with tags, reading time and a sticky table of contents that tracks your place
- Tables right-align their number columns automatically; headings get anchor links; code blocks get a copy button
- Search palette (⌘K / Ctrl+K or `/`) over titles, summaries, topics and section headings, from `/search.json`
- Social card images per post (`/og/<slug>.png`), built from the post's art and title with satori + sharp
- RSS feed (`/rss.xml`) with full post content, and a sitemap
- Long posts show reading time left in the contents rail
- Header hides while you scroll down and returns when you scroll up or stop; articles show a CSS-only
  reading-progress line; the footer holds GitHub, LinkedIn, RSS, back-to-top and the sun/moon theme switch
- A few lines of client-side JavaScript (header, theme switch, copy buttons, contents highlight);
  everything works without it

## Run locally

Requires Node.js 22.12 or newer.

```bash
npm ci
npm run dev       # http://localhost:4321/blog/
npm run build     # type-check with `astro check`, then build into ./dist
npm run preview   # serve ./dist locally
```

## Writing a post

Add a Markdown (`.md`) or MDX (`.mdx`) file to `src/content/blog/`. The filename becomes the URL
slug, so `src/content/blog/my-post.md` is served at `/blog/posts/my-post/`.

```md
---
title: 'My post'
description: 'One sentence shown in lists, RSS and social previews.'
pubDate: 2026-10-12
updatedDate: 2026-10-20 # optional
tags: ['kubernetes', 'terraform']
draft: true # optional; drafts only show up in `npm run dev`
pillar: platform # optional; platform (default), data or ai
featured: true # optional; lead the home page grid instead of the newest post
---

Post content goes here.
```

Site title, description and social links live in `src/consts.ts`. Design tokens (copied from Technica's
`tokens.json`) are CSS variables at the top of `src/styles/global.css`; the code highlighting themes are
`src/styles/shiki-light.theme.json` and `src/styles/shiki-dark.theme.json`, and the CodeBlock bar comes from
the Shiki transformer in `src/plugins/code-block.mjs`. Build-time tweaks to post HTML (tables, heading anchors) are in
`src/plugins/prose.mjs`.

## Project layout

```text
src/
  content/blog/      posts (Markdown / MDX)
  components/        site header, footer, IsoArt, panels (PageHead), post tiles, topic menu
  plugins/           Markdown (Sätteri) plugins for tables and heading anchors
  layouts/           base page shell and post layout
  pages/             routes: home, posts, tags, about, 404, rss.xml
  styles/            global CSS and the Shiki theme
.github/workflows/   GitHub Pages deploy workflow
```

## Deploy

Deploys run from `.github/workflows/deploy.yml`. Every push to `main` builds the site and publishes it
to GitHub Pages. Pull requests build the site as a check but do not deploy.

One-time setup:

1. In the repository go to **Settings > Pages**.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. Merge to `main` (or run the workflow manually from the **Actions** tab).

The workflow reads the site URL and base path from `actions/configure-pages`, so the site works at
`https://netf.github.io/blog/` without any config changes.

### Custom domain

1. Add the domain under **Settings > Pages > Custom domain** and create the DNS record GitHub asks for
   (a `CNAME` to `netf.github.io` for a subdomain).
2. Re-run the deploy workflow. The base path switches from `/blog` to `/` automatically.

To build locally for a custom domain, set the same variables the workflow uses:

```bash
SITE_URL=https://blog.example.com BASE_PATH= npm run build
```
