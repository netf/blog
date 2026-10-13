---
title: 'Your platform is a product, so treat it like one'
description: 'Internal platforms fail when they are built as a pile of tools instead of a product with users, a roadmap and a paved road.'
pubDate: 2026-10-05
tags: ['platform-engineering', 'developer-experience']
---

Here's the most common way I've seen platform teams fail, and it isn't technical. **They build a
platform nobody asked for, mandate it, and then wonder why teams route around it.**

The fix is to treat the platform like any other product: it has users, those users have problems,
and your job is to solve them. In practice, that comes down to three things.

## 1. Start with your users

Your users are the engineers shipping product. **Before you write a single Terraform module, find
out:**

1. How long does it take a new service to reach production today?
2. Where do teams wait on someone else (tickets, approvals, reviews)?
3. What do they copy and paste between repositories?

Those answers are your backlog.

## 2. Pave the road, don't build a wall

A golden path is the **easiest** way to do the right thing, not the **only** way. **If the paved
road is slower than the dirt track, people will take the dirt track.**

Here's how the three common approaches feel from the developer's side of the desk:

| Approach     | What it feels like to a developer   | Outcome                      |
| ------------ | ----------------------------------- | ---------------------------- |
| Gatekeeping  | "Open a ticket and wait a week"     | Shadow infrastructure        |
| Golden path  | "Run one command and get a service" | Consistency by default       |
| Free-for-all | "Do whatever you want"              | Snowflakes and pager fatigue |

Only one row gets you consistency without a fight.

## 3. Measure what your users feel

Track the things your users feel, not the things that are easy to count:

- **Time from `git init` to first production deploy**
- **Change lead time and change failure rate**
- **How often teams need to talk to the platform team to get something done**

That last one is the easiest to ignore and the most telling:

> If the platform team is in the critical path of every deploy, you have built a bottleneck, not a platform.

In a future post, I'll get into how to actually build the paved road.
