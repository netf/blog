---
title: 'Hello, world: why this blog exists'
description: 'A short introduction to what I plan to write about: platform engineering, DevOps and running production systems.'
pubDate: 2026-10-12
tags: ['meta', 'platform-engineering']
---

Every platform team I've worked with ends up rediscovering the same handful of lessons. Golden
paths beat gatekeeping. Boring technology wins. And the hardest problems are usually about people
and incentives, not YAML.

**I got tired of relearning them, so this blog is where I write them down.**

## What I'll write about

Five areas, roughly in order of how often they've kept me up at night:

- **Platform engineering.** Internal developer platforms, golden paths, and treating the platform
  as a product.
- **Kubernetes and GitOps.** Cluster operations, upgrades, multi-tenancy, and Argo CD / Flux
  patterns.
- **Infrastructure as code.** Terraform module design, state management, and policy as code.
- **CI/CD.** Fast, reproducible pipelines and progressive delivery.
- **Observability and reliability.** SLOs, alerting that doesn't page you for nothing, and incident
  reviews.

## How this site is built

Nothing fancy, which is the point. It's a static [Astro](https://astro.build) site written in
Markdown, built by GitHub Actions and served from GitHub Pages.

The source is at [github.com/netf/blog](https://github.com/netf/blog), so you can run it locally in
three commands:

```bash
git clone https://github.com/netf/blog && cd blog
npm ci
npm run dev
```

**Want new posts in your reader?** There's an RSS feed linked in the footer.
