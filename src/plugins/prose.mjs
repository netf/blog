// @ts-check
// Build-time touches for post content, run as Sätteri hast plugins:
// - tables get a scroll wrapper, and columns of numbers are marked so they right-align
// - h2/h3 get an id (same slugger Astro uses) and a hover anchor link
// (Code blocks are wrapped by the Shiki transformer in ./code-block.mjs.)

import Slugger from 'github-slugger';

/** @typedef {import('hast').Element} Element */
/** @typedef {import('hast').ElementContent} ElementContent */

// "0.23", "~28 MiB", "+1.40 ms", "3.6x", "41,000", "**1.55%**" all count as numbers.
const NUMERIC = /^[~≈+\-−]?\s*[\d.,]+\s*(%|ms|s|µs|MiB|GiB|KiB|MB|GB|x|×)?$/;

/** @param {any} node */
function text(node) {
	if (node.type === 'text') return node.value;
	return (node.children ?? []).map(text).join('');
}

/** @param {any} node @returns {any} */
function clone(node) {
	if (!node || typeof node !== 'object') return node;
	/** @type {any} */
	const copy = { type: node.type };
	if ('tagName' in node) copy.tagName = node.tagName;
	if ('value' in node) copy.value = node.value;
	if ('properties' in node) copy.properties = { ...node.properties };
	if ('children' in node) copy.children = node.children.map(clone);
	return copy;
}

/** @param {Element} el @param {string} tag @returns {Element[]} */
const childEls = (el, tag) =>
	/** @type {Element[]} */ (el.children.filter((c) => c.type === 'element' && c.tagName === tag));

/** @param {Element} cell @param {string} cls */
function addClass(cell, cls) {
	const current = cell.properties.className;
	const list = Array.isArray(current) ? current : current ? [String(current)] : [];
	cell.properties.className = [...list, cls];
}

const tables = {
	name: 'prose-tables',
	element: {
		filter: ['table'],
		/** @param {Element} node @param {any} ctx */
		visit(node, ctx) {
			const table = clone(node);
			const rows = [...childEls(table, 'thead'), ...childEls(table, 'tbody')].flatMap((g) =>
				childEls(g, 'tr'),
			);
			const bodyRows = childEls(table, 'tbody').flatMap((g) => childEls(g, 'tr'));
			const width = Math.max(0, ...rows.map((r) => r.children.length));
			for (let col = 0; col < width; col++) {
				const cells = bodyRows.map((r) => childEls(r, 'td')[col]).filter(Boolean);
				const numeric =
					cells.length > 0 && cells.every((c) => NUMERIC.test(text(c).trim().replace(/\*/g, '')));
				if (!numeric) continue;
				for (const row of rows) {
					const cell = /** @type {Element | undefined} */ (
						row.children.filter((c) => c.type === 'element')[col]
					);
					if (cell) addClass(cell, 'num');
				}
			}
			ctx.replaceNode(node, {
				type: 'element',
				tagName: 'div',
				properties: { className: ['table-wrap'], tabIndex: 0, role: 'region', ariaLabel: 'Table' },
				children: [table],
			});
		},
	},
};

/** One slugger per document, so ids match the ones Astro records for the table of contents. */
function headings() {
	const slugger = new Slugger();
	return {
		name: 'prose-headings',
		element: {
			filter: ['h2', 'h3'],
			/** @param {Element} node @param {any} ctx */
			visit(node, ctx) {
				const existing = node.properties?.id;
				const id = typeof existing === 'string' ? existing : slugger.slug(ctx.textContent(node));
				ctx.setProperty(node, 'id', id);
				// The anchor has no text node, so it doesn't leak into heading text or the TOC.
				ctx.appendChild(node, {
					type: 'element',
					tagName: 'a',
					properties: { className: ['anchor'], href: `#${id}`, ariaLabel: 'Link to this section' },
					children: [],
				});
			},
		},
	};
}

export const prosePlugins = [tables, headings];
