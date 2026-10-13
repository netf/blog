// The search index, built with the site and fetched by the search palette the first time it opens.
import { render } from 'astro:content';
import { url } from '../consts';
import { getPosts, pillarLabel, readingTime } from '../lib/posts';

export async function GET() {
	const posts = await getPosts();
	const entries = await Promise.all(
		posts.map(async (post) => {
			const { headings } = await render(post);
			return {
				title: post.data.title,
				description: post.data.description,
				url: url(`/posts/${post.id}/`),
				date: post.data.pubDate.toISOString().slice(0, 10),
				pillar: pillarLabel(post.data.pillar),
				readingTime: readingTime(post.body),
				tags: post.data.tags,
				sections: headings.filter((h) => h.depth <= 3).map((h) => ({ text: h.text, slug: h.slug })),
			};
		}),
	);
	return new Response(JSON.stringify(entries), { headers: { 'Content-Type': 'application/json' } });
}
