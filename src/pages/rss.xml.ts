import rss from '@astrojs/rss';
import type { APIContext } from 'astro';
import { SITE_DESCRIPTION, SITE_TITLE, url } from '../consts';
import { getPosts } from '../lib/posts';

/**
 * A post's rendered HTML, made fit for feed readers: no copy buttons or empty heading anchors,
 * no theme-only colour variables, and every relative link made absolute.
 */
function feedHtml(html: string, postURL: URL): string {
	return html
		.replace(/<button[^>]*class="code-copy"[^>]*>.*?<\/button>/g, '')
		.replace(/<a class="anchor"[^>]*><\/a>/g, '')
		.replace(/ style="--shiki-[^"]*"/g, '')
		.replace(/ (href|src)="([^"]+)"/g, (_, attr: string, value: string) => {
			if (/^[a-z][a-z0-9+.-]*:/i.test(value)) return ` ${attr}="${value}"`;
			return ` ${attr}="${new URL(value, postURL).href}"`;
		});
}

export async function GET(context: APIContext) {
	const posts = await getPosts();
	return rss({
		title: SITE_TITLE,
		description: SITE_DESCRIPTION,
		site: new URL(url('/'), context.site).href,
		items: posts.map((post) => {
			const link = url(`/posts/${post.id}/`);
			const html = post.rendered?.html;
			return {
				title: post.data.title,
				description: post.data.description,
				pubDate: post.data.pubDate,
				categories: post.data.tags,
				link,
				content: html ? feedHtml(html, new URL(link, context.site)) : undefined,
			};
		}),
	});
}
