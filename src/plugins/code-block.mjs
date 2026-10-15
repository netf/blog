// @ts-check
// Shiki transformer that turns every highlighted listing into a Technica CodeBlock:
// a 40px file bar (language, or `~ $` for a shell session) with a Copy button, then the listing.
// One-line listings drop their line numbers. The Copy button starts hidden; the post script wires it.
// `mermaid` listings are not highlighted: they become a figure holding the raw source, which the post
// script renders to SVG in the browser (without JavaScript the source stays readable).

const SHELLS = new Set(['bash', 'sh', 'shell', 'zsh', 'console', 'shellsession']);
const PLAIN = new Set(['text', 'txt', 'plaintext', '']);

/** @type {import('shiki').ShikiTransformer} */
export const codeBlock = {
	name: 'technica-code-block',
	pre(node) {
		if (this.lines.length <= 1) this.addClassToHast(node, 'nolines');
	},
	root(root) {
		const pre = root.children.find((c) => c.type === 'element');
		if (!pre) return;
		const lang = this.options.lang ?? '';
		if (lang === 'mermaid') {
			root.children = [
				{
					type: 'element',
					tagName: 'figure',
					properties: { class: 'diagram' },
					children: [
						{
							type: 'element',
							tagName: 'pre',
							properties: { class: 'mermaid-src' },
							children: [{ type: 'text', value: this.source.trimEnd() }],
						},
					],
				},
			];
			return;
		}
		const label = SHELLS.has(lang) ? '~ $' : PLAIN.has(lang) ? 'output' : lang;
		root.children = [
			{
				type: 'element',
				tagName: 'div',
				properties: { class: 'code' },
				children: [
					{
						type: 'element',
						tagName: 'div',
						properties: { class: 'code-bar' },
						children: [
							{
								type: 'element',
								tagName: 'span',
								properties: { class: 'code-file' },
								children: [{ type: 'text', value: label }],
							},
							{
								type: 'element',
								tagName: 'button',
								properties: { type: 'button', class: 'code-copy', hidden: true },
								children: [{ type: 'text', value: 'Copy' }],
							},
						],
					},
					pre,
				],
			},
		];
	},
};
