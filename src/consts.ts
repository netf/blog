export const SITE_TITLE = 'netf';
export const SITE_DESCRIPTION =
	'Notes on DevOps, platform engineering, Kubernetes, infrastructure as code and the craft of running production systems.';
export const SITE_AUTHOR = 'netf';
export const PROMPT = 'netf@platform:~$';

export const SOCIALS = {
	github: 'https://github.com/netf',
};

const base = import.meta.env.BASE_URL.replace(/\/$/, '');

/** Prefix an absolute site path with the configured `base`. */
export function url(path = '/'): string {
	return `${base}${path.startsWith('/') ? path : `/${path}`}`;
}
