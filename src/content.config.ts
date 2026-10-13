import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const blog = defineCollection({
	loader: glob({ base: './src/content/blog', pattern: '**/*.{md,mdx}' }),
	schema: z.object({
		title: z.string(),
		description: z.string(),
		pubDate: z.coerce.date(),
		updatedDate: z.coerce.date().optional(),
		/** The pillar the post belongs to: platform, data or AI. */
		pillar: z.enum(['platform', 'data', 'ai']).default('platform'),
		tags: z.array(z.string()).default([]),
		draft: z.boolean().default(false),
		/** Lead the home page grid with this post instead of the newest one. */
		featured: z.boolean().default(false),
	}),
});

export const collections = { blog };
