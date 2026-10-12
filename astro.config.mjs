// @ts-check

import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import { defineConfig, fontProviders } from 'astro/config';
import greyscale from './src/styles/greyscale.theme.json' with { type: 'json' };

// The Pages workflow passes SITE_URL and BASE_PATH from `actions/configure-pages`.
// BASE_PATH is empty when a custom domain is configured, so it must not fall back to '/blog'.
const site = process.env.SITE_URL || 'https://netf.github.io';
const base = process.env.SITE_URL ? process.env.BASE_PATH || '/' : '/blog';

// https://astro.build/config
export default defineConfig({
	site,
	base,
	trailingSlash: 'ignore',
	integrations: [mdx(), sitemap()],
	markdown: {
		shikiConfig: {
			theme: { ...greyscale, type: /** @type {const} */ ('dark') },
			wrap: false,
		},
	},
	fonts: [
		{
			provider: fontProviders.google(),
			name: 'Inter',
			cssVariable: '--font-sans',
			weights: [400, 500, 600, 700],
			fallbacks: ['system-ui', 'sans-serif'],
		},
		{
			provider: fontProviders.google(),
			name: 'JetBrains Mono',
			cssVariable: '--font-mono',
			weights: [400, 500, 700],
			fallbacks: ['ui-monospace', 'monospace'],
		},
	],
});
