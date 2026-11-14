# Fresh-clone reproduction

`make reproduce` from a fresh clone of this branch at commit b46096a, on the same VM,
2026-11-14, exit code 0, about 32 minutes. `summary.md` here is what that run produced. It was run
with worm v1.0.0, before the git-config behaviour was added to failure test 4.

Compared with the committed results: every attack outcome, failure-test outcome (tests 1, 2, 3, 5,
6), script-census line and native-binary control was identical. Overhead medians differed by
0.01x to 0.02x; summed cold overhead with the compile cache was 8.2% (bubblewrap) and 3.9%
(Landlock) here against 4.3% and 1.1% in the committed run.
