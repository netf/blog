---
title: 'Your platform is a product, so treat it like one'
description: 'Internal platforms fail when they are built as a pile of tools instead of a product with users, a roadmap and a paved road.'
pubDate: 2026-10-05
tags: ['platform-engineering', 'developer-experience']
---

The most common failure mode I see in platform teams is not technical. It is building a platform
nobody asked for, mandating it, and then wondering why teams route around it.

## Start with the users

Your users are the engineers shipping product. Before writing a single Terraform module, find out:

1. How long does it take a new service to reach production today?
2. Where do teams wait on someone else (tickets, approvals, reviews)?
3. What do they copy and paste between repositories?

Those answers are your backlog.

## Pave the road, do not build a wall

A golden path is the **easiest** way to do the right thing, not the **only** way. If the paved road
is slower than the dirt track, people will take the dirt track.

| Approach    | What it feels like to a developer   | Outcome                  |
| ----------- | ----------------------------------- | ------------------------ |
| Gatekeeping | "Open a ticket and wait a week"     | Shadow infrastructure    |
| Golden path | "Run one command and get a service" | Consistency by default   |
| Free-for-all | "Do whatever you want"             | Snowflakes and pager fatigue |

## Measure it

Track the things your users feel, not the things that are easy to count:

- Time from `git init` to first production deploy
- Change lead time and change failure rate
- How often teams need to talk to the platform team to get something done

> If the platform team is in the critical path of every deploy, you have built a bottleneck, not a platform.

More on how to actually build the paved road in a future post.
