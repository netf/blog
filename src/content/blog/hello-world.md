---
title: 'Hello, world: why this blog exists'
description: 'A short introduction to what I plan to write about: platform engineering, DevOps and running production systems.'
pubDate: 2026-10-12
tags: ['meta', 'platform-engineering']
---

Every platform team I have worked with ends up rediscovering the same lessons: golden paths beat
gatekeeping, boring technology wins, and the hardest problems are usually about people and
incentives rather than YAML.

This blog is where I write those lessons down.

## What to expect

- **Platform engineering**: internal developer platforms, golden paths and treating the platform as a product.
- **Kubernetes and GitOps**: cluster operations, upgrades, multi-tenancy and Argo CD / Flux patterns.
- **Infrastructure as code**: Terraform module design, state management and policy as code.
- **CI/CD**: fast, reproducible pipelines and progressive delivery.
- **Observability and reliability**: SLOs, alerting that does not page you for nothing, and incident reviews.

## How this site is built

It is a static [Astro](https://astro.build) site, written in Markdown, built by GitHub Actions and
served from GitHub Pages. The source is at [github.com/netf/blog](https://github.com/netf/blog).

```bash
git clone https://github.com/netf/blog && cd blog
npm ci
npm run dev
```

There is an RSS feed linked in the header if you want new posts in your reader.
