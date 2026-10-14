# netf / blog

Personal site and blog. Built with [Astro](https://astro.build), served from Cloudflare Workers at
**https://netf.io**.

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
.github/workflows/   CI: type-check, build and validate the Cloudflare config
wrangler.jsonc       Cloudflare Workers config (static assets, netf.io custom domain)
```

## Deploy

The site is a static Astro build served as [Cloudflare Workers static assets](https://developers.cloudflare.com/workers/static-assets/).
**Workers Builds** (Cloudflare's Git integration) deploys it: every push to `main` runs
`npm run build` then `npx wrangler deploy`, and other branches get preview URLs. GitHub Actions only
runs a build check (`.github/workflows/ci.yml`).

- `wrangler.jsonc` serves `./dist`, uses `dist/404.html` for unknown paths, and attaches the apex
  domain `netf.io` as a custom domain. Other hostnames on the zone (for example `fire.netf.io`) are
  not touched.
- `public/_headers` sets long-lived caching for fingerprinted `/_astro/*` files and basic security
  headers.
- `.node-version` pins Node 22 for both Cloudflare and CI.

One-time setup in the Cloudflare dashboard:

1. **Workers & Pages > Create application > Import a repository**, and pick `netf/blog`.
2. Build command `npm run build`, deploy command `npx wrangler deploy`, production branch `main`.
3. If `netf.io` already has an `A`, `AAAA` or `CNAME` record at the apex, remove it first: the custom
   domain creates its own record, and the deploy fails if one exists.

Preview locally on the Workers runtime:

```bash
npm run build && npx wrangler dev
```

To build for another domain, set `SITE_URL` (the site always lives at the root path):

```bash
SITE_URL=https://staging.example.com npm run build
```
