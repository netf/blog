import rss from '@astrojs/rss';
import type { APIContext } from 'astro';
import { SITE_DESCRIPTION, SITE_TITLE, url } from '../consts';
import { getPosts } from '../lib/posts';

export async function GET(context: APIContext) {
	const posts = await getPosts();
	return rss({
		title: SITE_TITLE,
		description: SITE_DESCRIPTION,
		site: new URL(url('/'), context.site).href,
		items: posts.map((post) => ({
			title: post.data.title,
			description: post.data.description,
			pubDate: post.data.pubDate,
			categories: post.data.tags,
			link: url(`/posts/${post.id}/`),
		})),
	});
}
