// Social card images (1200×630), built once per post plus one for the site, at build time.
// Left: wordmark, pillar, title and meta on the dark ground. Right: the post's own art,
// black on a white panel, like the home page's Latest panel.
// Text goes through satori (which turns glyphs into paths, so no system fonts are needed),
// then sharp rasterises and composites everything into a PNG.

import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { APIContext, GetStaticPaths } from 'astro';
import satori from 'satori';
import sharp from 'sharp';
import { drawIso, isoSvg } from '../../lib/iso';
import { getPosts, type Post, pillarLabel, readingTime } from '../../lib/posts';

const W = 1200;
const H = 630;
const ART_W = 520;
const INK = '#0a0a0b';
const PAPER = '#ffffff';
const MUTED = '#9ea2a8';

export const getStaticPaths = (async () => {
	const posts = await getPosts();
	return [
		{ params: { slug: 'site' }, props: { post: undefined } },
		...posts.map((post) => ({ params: { slug: post.id }, props: { post } })),
	];
}) satisfies GetStaticPaths;

const font = (pkg: string, file: string) =>
	readFile(join(process.cwd(), 'node_modules/@fontsource', pkg, 'files', file));

let fonts: Promise<Parameters<typeof satori>[1]['fonts']> | undefined;
const loadFonts = () =>
	(fonts ??= Promise.all([
		font('ibm-plex-sans', 'ibm-plex-sans-latin-600-normal.woff'),
		font('ibm-plex-mono', 'ibm-plex-mono-latin-500-normal.woff'),
		font('ibm-plex-mono', 'ibm-plex-mono-latin-600-normal.woff'),
	]).then(([sans, mono, monoBold]) => [
		{ name: 'Plex Sans', data: sans, weight: 600, style: 'normal' },
		{ name: 'Plex Mono', data: mono, weight: 500, style: 'normal' },
		{ name: 'Plex Mono', data: monoBold, weight: 600, style: 'normal' },
	]));

// satori takes React-shaped element objects; this keeps the tree readable without JSX.
type Node = { type: string; props: Record<string, unknown> };
const el = (type: string, style: Record<string, unknown>, ...children: (Node | string)[]): Node => ({
	type,
	// satori treats a one-item array as several children, so pass a lone child as itself.
	props: { style: { display: 'flex', ...style }, children: children.length === 1 ? children[0] : children },
});

function card(post: Post | undefined, address: string): Node {
	const title = post?.data.title ?? 'Notes from the blast radius';
	const kicker = post ? [pillarLabel(post.data.pillar).toUpperCase()] : ['01 / PLATFORM', '02 / DATA', '03 / AI'];
	const meta = post
		? `${post.data.pubDate.toISOString().slice(0, 10)}  ·  ${readingTime(post.body)}`
		: 'Days making production boring. Nights finding out it wasn\'t.';
	const size = title.length > 70 ? 48 : title.length > 40 ? 56 : 64;
	const mono = { fontFamily: 'Plex Mono', fontWeight: 500 };

	return el(
		'div',
		{
			width: W - ART_W,
			height: H,
			display: 'flex',
			flexDirection: 'column',
			justifyContent: 'space-between',
			padding: 64,
			background: INK,
			color: PAPER,
		},
		el(
			'div',
			{ display: 'flex', alignItems: 'center', ...mono, fontWeight: 600, fontSize: 30 },
			'netf',
			el('div', { width: 15, height: 30, marginLeft: 4, background: PAPER }),
		),
		el(
			'div',
			{ display: 'flex', flexDirection: 'column' },
			el('div', { ...mono, fontSize: 18, letterSpacing: 2, color: MUTED, gap: 28 }, ...kicker.map((k) => el('div', {}, k))),
			el(
				'div',
				{ fontFamily: 'Plex Sans', fontWeight: 600, fontSize: size, lineHeight: 1.08, letterSpacing: -1.5, marginTop: 20 },
				title,
			),
			el('div', { ...mono, fontSize: 20, color: MUTED, marginTop: 28 }, meta),
		),
		el('div', { ...mono, fontSize: 18, color: MUTED }, address),
	);
}

export async function GET({ props, site }: APIContext<{ post?: Post }>) {
	const { post } = props;
	// The site's address as people would type it: host plus base path, no scheme or trailing slash.
	const address = new URL(import.meta.env.BASE_URL, site).href.replace(/^https?:\/\//, '').replace(/\/$/, '');

	// Art: drawn black on white at the site's fixed scale, then cropped to the right panel.
	const drawing = drawIso({ seed: post?.id ?? 'netf-field-notes', cols: 7, rows: 6, height: 5 });
	const art = sharp(Buffer.from(isoSvg(drawing, INK, PAPER)));
	const { width = 0, height = 0 } = await art.metadata();
	const crop = {
		left: Math.max(0, Math.round((width - ART_W) / 2)),
		top: Math.max(0, Math.round((height - H) / 2)),
		width: Math.min(ART_W, width),
		height: Math.min(H, height),
	};
	const artPng = await art.extract(crop).png().toBuffer();

	const textSvg = await satori(card(post, address) as never, { width: W - ART_W, height: H, fonts: await loadFonts() });

	const png = await sharp({ create: { width: W, height: H, channels: 3, background: PAPER } })
		.composite([
			{ input: Buffer.from(textSvg), left: 0, top: 0 },
			{
				input: artPng,
				left: W - ART_W + Math.round((ART_W - crop.width) / 2),
				top: Math.round((H - crop.height) / 2),
			},
		])
		.png()
		.toBuffer();

	return new Response(new Uint8Array(png), { headers: { 'Content-Type': 'image/png' } });
}
