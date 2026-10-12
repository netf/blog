# netf / blog

Personal DevOps and platform engineering blog. Built with [Astro](https://astro.build), deployed to
GitHub Pages at **https://netf.github.io/blog/**.

- Dark greyscale theme (Inter + JetBrains Mono, greyscale syntax highlighting)
- Markdown / MDX posts with tags, reading time and a table of contents
- RSS feed (`/rss.xml`) and sitemap
- Zero client-side JavaScript

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
---

Post content goes here.
```

Site title, description and social links live in `src/consts.ts`. Colours are CSS variables at the
top of `src/styles/global.css`, and the code highlighting theme is `src/styles/greyscale.theme.json`.

## Project layout

```text
src/
  content/blog/      posts (Markdown / MDX)
  components/        header, footer, post list, tag pill
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
