// @ts-check

import { satteri } from '@astrojs/markdown-satteri';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import { defineConfig, fontProviders } from 'astro/config';
import { codeBlock } from './src/plugins/code-block.mjs';
import { prosePlugins } from './src/plugins/prose.mjs';
import dark from './src/styles/shiki-dark.theme.json' with { type: 'json' };
import light from './src/styles/shiki-light.theme.json' with { type: 'json' };

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
		processor: satteri({ hastPlugins: prosePlugins }),
		shikiConfig: {
			// Technica syntax: told apart by weight, style and grey level, never hue.
			themes: {
				light: { ...light, type: /** @type {const} */ ('light') },
				dark: { ...dark, type: /** @type {const} */ ('dark') },
			},
			defaultColor: false,
			wrap: false,
			transformers: [codeBlock],
		},
	},
	fonts: [
		{
			provider: fontProviders.google(),
			name: 'IBM Plex Sans',
			cssVariable: '--font-sans',
			weights: [400, 500, 600],
			styles: ['normal', 'italic'],
			fallbacks: ['ui-sans-serif', 'system-ui', 'sans-serif'],
		},
		{
			provider: fontProviders.google(),
			name: 'IBM Plex Mono',
			cssVariable: '--font-mono',
			weights: [400, 500, 600],
			styles: ['normal', 'italic'],
			fallbacks: ['ui-monospace', 'SF Mono', 'Menlo', 'monospace'],
		},
	],
});
