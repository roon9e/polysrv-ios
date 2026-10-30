#!/usr/bin/env python3
"""
bazel_action_stats.py - report a bazel build's cache reuse from its closing
process summary.

Bazel prints one line at the end of every build:

    INFO: 22105 processes: 21600 disk cache hit, 300 internal, 125 worker, 80 local.

and that line is the only cheap source of per-action cache state. Asking bazel
for --execution_log_json_file instead buffered one record per action in the
server's heap and OOMed a build that had already reported success, and it
withheld the log too, because the server died before flushing.

"internal" actions (symlinks, parameter files, ...) are never cacheable, so they
are excluded from the denominator: a cacheable MISS is a cacheable action that
actually ran. `misses` is the number the workflow acts on - the golden cache is
stale and wants re-seeding when a build misses a lot of it, exactly as the
desktop CI re-seeds its ccache when `ccache --print-stats` reports > 300 misses.

Usage:
    bazel_action_stats.py <bazel-log> [--summary <file>] [--warn-above N]

Exit code is always 0: a report must never fail a build that succeeded.
"""
import argparse
import re

PROCESSES = re.compile(r'^\S+ (\d+) processes: (.*)$')
ITEM = re.compile(r'^(\d+) (.*)$')

# Categories that mean an action was served instead of executing.
HIT_CATEGORIES = ("disk cache hit", "remote cache hit")
# Categories that are never cacheable, so they are not misses either.
UNCACHEABLE_CATEGORIES = ("internal",)

DEFAULT_WARN_ABOVE = 300


def parse(text):
    """The last process summary in `text` as (total, {category: count})."""
    match = None
    for candidate in text.splitlines():
        found = PROCESSES.match(candidate)
        if found is not None:
            match = found
    if match is None:
        return None

    total = int(match.group(1))
    body = match.group(2).strip()
    if body.endswith('.'):
        body = body[:-1]

    counts = {}
    for part in body.split(', '):
        item = ITEM.match(part.strip())
        if item is not None:
            counts[item.group(2).strip()] = int(item.group(1))
    return total, counts


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('log', help='the bazel build log to read')
    parser.add_argument('--summary', help='append a markdown table here (GITHUB_STEP_SUMMARY)')
    parser.add_argument('--warn-above', type=int, default=DEFAULT_WARN_ABOVE,
                        help='emit a ::warning:: when the cacheable miss count exceeds this (0 disables)')
    parser.add_argument('--label', default='Bazel compile breakdown')
    args = parser.parse_args(argv[1:])

    try:
        with open(args.log, 'r', errors='replace') as handle:
            text = handle.read()
    except OSError as error:
        print('no bazel log to read (%s); nothing to report' % error)
        return 0

    parsed = parse(text)
    if parsed is None:
        print('bazel never printed a process summary; nothing to report')
        return 0
    total, counts = parsed

    hits = sum(counts.get(name, 0) for name in HIT_CATEGORIES)
    uncacheable = sum(counts.get(name, 0) for name in UNCACHEABLE_CATEGORIES)
    cacheable = max(0, total - uncacheable)
    misses = max(0, cacheable - hits)
    reuse = (hits * 100 // cacheable) if cacheable else 100

    ordered = sorted(counts.items(), key=lambda item: -item[1])
    print('%d actions: %s' % (total, ', '.join('%d %s' % (count, name) for name, count in ordered)))
    print('cache reuse: %d/%d cacheable actions served (%d%%), %d misses' % (hits, cacheable, reuse, misses))

    if args.summary:
        rows = ['### %s' % args.label, '', '| | |', '|---|---|']
        for name, count in ordered:
            rows.append('| %s | %d |' % (name, count))
        rows.append('| **cacheable miss** | **%d** |' % misses)
        rows.append('| cache reuse | %d%% |' % reuse)
        with open(args.summary, 'a') as handle:
            handle.write('\n'.join(rows) + '\n')

    if args.warn_above > 0 and misses > args.warn_above:
        print('::warning::%d cacheable actions ran (over the %d threshold): the golden cache '
              'does not match this tree; dispatch this workflow with seed_cache to rebuild it'
              % (misses, args.warn_above))

    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main(sys.argv))
