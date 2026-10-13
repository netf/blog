// Generative isometric op-art: a cluster of striped blocks, like racks or stacked containers.
// Deterministic per seed. Shared by the IsoArt component (site) and the social card images.
// Every drawing uses the same block size and stripe pitch, so all the art reads as one system.

export interface IsoOptions {
	seed: string;
	/** Footprint of the cluster in grid cells. */
	cols?: number;
	rows?: number;
	/** Tallest block, in cells. */
	height?: number;
}

export type Face = 'solid' | 'blank' | `p${number}`;

export interface IsoDrawing {
	/** Stable per seed; use it to namespace pattern ids. */
	key: string;
	viewBox: string;
	width: number;
	height: number;
	/** Stripe patterns: lines at an isometric angle, `gap` px apart. */
	patterns: { angle: number; gap: number }[];
	faces: { fill: Face; points: string }[];
}

/** Block edge in px. */
export const ISO_UNIT = 64;

export function drawIso({ seed, cols = 5, rows = 5, height = 4 }: IsoOptions): IsoDrawing {
	// FNV-1a hash of the seed into a small deterministic PRNG (mulberry32).
	let h = 2166136261;
	for (const ch of seed) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
	let state = h >>> 0;
	const rand = () => {
		state = (state + 0x6d2b79f5) >>> 0;
		let t = state;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
	const pick = <T>(items: T[]) => items[Math.floor(rand() * items.length)];

	// Isometric projection: x runs down-right, y down-left, z up.
	const S = ISO_UNIT;
	const C = Math.cos(Math.PI / 6);
	const project = (x: number, y: number, z: number): [number, number] => [
		(x - y) * C * S,
		((x + y) / 2 - z) * S,
	];
	const poly = (pts: [number, number, number][]) =>
		pts.map((p) => project(...p).map((n) => n.toFixed(1)).join(',')).join(' ');

	// Heights fall off from a focal cell, with noise, so the cluster reads as one structure.
	const fx = (cols - 1) / 2 + (rand() - 0.5);
	const fy = (rows - 1) / 2 + (rand() - 0.5);
	const maxD = Math.hypot(cols, rows) / 2;

	// Stripes at the angles of the isometric edges (30°, 150°) and vertical (90°), in two
	// densities. Each block face picks one, or a solid fill, or blank.
	const angles = [30, 150, 90];
	const gaps = [10, 16];
	const patterns = angles.flatMap((angle) => gaps.map((gap) => ({ angle, gap })));
	const pat = (angle: number): Face => {
		const gap = pick(gaps);
		return `p${patterns.findIndex((p) => p.angle === angle && p.gap === gap)}`;
	};

	const blocks: { x: number; y: number; z: number; h: number; top: Face; left: Face; right: Face }[] = [];
	for (let x = 0; x < cols; x++) {
		for (let y = 0; y < rows; y++) {
			const d = Math.hypot(x - fx, y - fy) / maxD;
			const tall = Math.round(height * (1 - d) + (rand() - 0.35) * 2);
			if (tall <= 0 || rand() < 0.18) continue;
			// Some columns are split into stacked blocks with a gap, like servers in a rack.
			let z = 0;
			while (z < tall) {
				const part = Math.min(tall - z, 1 + Math.floor(rand() * tall));
				blocks.push({
					x,
					y,
					z,
					h: part,
					top: pick<Face>(['solid', 'blank', pat(30), pat(150)]),
					left: pick<Face>([pat(30), pat(30), pat(90), 'solid', 'blank']),
					right: pick<Face>([pat(150), pat(150), pat(90), 'solid']),
				});
				z += part + (rand() < 0.25 ? 0.35 : 0);
			}
		}
	}
	// Painter's order: blocks further from the viewer (smaller x + y, lower z) first.
	blocks.sort((a, b) => a.x + a.y - (b.x + b.y) || a.z - b.z);

	const faces = blocks.flatMap(({ x, y, z, h: bh, top, left, right }) => {
		const t = z + bh;
		return [
			{ fill: left, points: poly([[x, y + 1, z], [x + 1, y + 1, z], [x + 1, y + 1, t], [x, y + 1, t]]) },
			{ fill: right, points: poly([[x + 1, y, z], [x + 1, y + 1, z], [x + 1, y + 1, t], [x + 1, y, t]]) },
			{ fill: top, points: poly([[x, y, t], [x + 1, y, t], [x + 1, y + 1, t], [x, y + 1, t]]) },
		];
	});

	// The view is the drawing's own bounds, drawn 1:1 in px.
	const xs = blocks.flatMap((b) => [project(b.x, b.y + 1, 0)[0], project(b.x + 1, b.y, 0)[0]]);
	const ys = blocks.flatMap((b) => [project(b.x, b.y, b.z + b.h)[1], project(b.x + 1, b.y + 1, b.z)[1]]);
	const pad = S * 0.5;
	const minX = Math.min(...xs) - pad;
	const minY = Math.min(...ys) - pad;
	const width = Math.max(...xs) + pad - minX;
	const height_ = Math.max(...ys) + pad - minY;

	return {
		key: (h >>> 0).toString(36),
		viewBox: `${minX.toFixed(1)} ${minY.toFixed(1)} ${width.toFixed(1)} ${height_.toFixed(1)}`,
		width: Math.round(width),
		height: Math.round(height_),
		patterns,
		faces,
	};
}

/** The drawing as a standalone SVG string in two fixed colours, for rasterising. */
export function isoSvg(drawing: IsoDrawing, ink: string, ground: string): string {
	const pid = (i: number) => `p${i}`;
	const fill = (f: Face) => (f === 'solid' ? ink : f === 'blank' ? ground : `url(#${pid(Number(f.slice(1)))})`);
	const defs = drawing.patterns
		.map(
			({ angle, gap }, i) =>
				`<pattern id="${pid(i)}" width="${gap}" height="${gap}" patternUnits="userSpaceOnUse" patternTransform="rotate(${angle})"><rect width="${gap}" height="${gap}" fill="${ground}"/><rect width="${gap}" height="${gap * 0.45}" fill="${ink}"/></pattern>`,
		)
		.join('');
	const polys = drawing.faces.map((f) => `<polygon points="${f.points}" fill="${fill(f.fill)}"/>`).join('');
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${drawing.viewBox}" width="${drawing.width}" height="${drawing.height}"><defs>${defs}</defs><g stroke="${ink}" stroke-width="2" stroke-linejoin="round">${polys}</g></svg>`;
}
