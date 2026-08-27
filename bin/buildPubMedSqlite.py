#!/usr/bin/env python3
"""Build PubMed.db from scratch out of the extracted section files.

This is the fallback / ground-truth path, run weekly. The nightly path is
updatePubMedSqlite.py, which patches a copy of the deployed database instead.

Output is identical to the previous sqlite_utils-based builder -- same schema,
same rows -- but it inserts through raw sqlite3 executemany in large batches
inside one transaction per table. sqlite_utils defaulted to batch_size=100 with
a commit per chunk, which meant roughly 5.8 million transactions over the ~580M
rows loaded here, each one a rollback-journal create plus fsync. That, not the
parsing, was where the 4.5-7.5 hours went.

The database is assembled under <db>.building and renamed into place only after
every table is loaded and indexed, so <db> never exists in a partial state. The
old builder instead relied on the caller having moved the previous file away,
and short-circuited on `if tableExists(table): return` -- which, combined with a
deploy that had been skipped, would silently freeze the pipeline forever.
"""

import argparse
import glob
import json
import os
import re
import sqlite3
import sys
import time
from itertools import islice

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pubmed_tables as pt

BATCH = 50000

_started = time.time()


def log(*args):
	elapsed = time.time() - _started
	print('[%s +%6.1fm]' % (time.strftime('%H:%M:%S'), elapsed / 60), *args, flush=True)


def batched(iterable, size):
	iterator = iter(iterable)
	while True:
		chunk = list(islice(iterator, size))
		if not chunk:
			return
		yield chunk


def build_table(conn, table, sections, sections_dir, sectionmap, pmcidmap):
	cols = pt.columns(table)
	sql = 'INSERT INTO [%s] (%s) VALUES (%s)' % (
		table, ', '.join('[%s]' % c for c in cols), ', '.join('?' * len(cols)))
	if pt.table_exists(conn, table):
		# Only reachable under --resume after a crash partway through this table;
		# the partial contents are useless, so start it over.
		log('%s: dropping partial table from an interrupted run' % table)
		conn.execute('DROP TABLE [%s]' % table)
	pt.create_table(conn, table)
	total = 0
	conn.execute('BEGIN')
	for section in sections:
		rows = pt.iter_rows(table, section, sections_dir, sectionmap, pmcidmap)
		n = 0
		for chunk in batched(rows, BATCH):
			conn.executemany(sql, chunk)
			n += len(chunk)
		total += n
		print('%s\t%s\t%d' % (table, section, n), flush=True)
	conn.commit()
	log('%s: %d rows loaded' % (table, total))
	pt.create_indexes(conn, table, log=log)
	conn.commit()
	log('%s: indexed' % table)
	return total


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--db', default='/ssd2/gglusman/PubMed.db',
	                    help='destination database (built at <db>.building, renamed on success)')
	parser.add_argument('--sections', default='sections', help='directory of extracted sections')
	parser.add_argument('--ids', default='id.list.gz', help='pmid -> winning section map')
	parser.add_argument('--source-glob', default='updatefiles/pubmed*.xml.gz',
	                    help='downloaded XML, used only to record the baseline year')
	parser.add_argument('--resume', action='store_true',
	                    help='keep an existing <db>.building and skip tables it already finished')
	args = parser.parse_args()

	building = args.db + '.building'
	if os.path.exists(building) and not args.resume:
		log('removing stale %s' % building)
		os.unlink(building)

	log('reading identifiers from %s' % args.ids)
	sectionmap, pmcidmap = pt.read_id_list(args.ids)
	log('%d live pmids, %d with pmcids' % (len(sectionmap), len(pmcidmap)))

	# Descending, matching the historical build order and pybuildSqlite.log.
	sections = sorted(pt.list_sections(args.sections), reverse=True)
	log('%d sections' % len(sections))

	conn = sqlite3.connect(building)
	conn.isolation_level = None  # explicit BEGIN/commit
	pt.tune(conn, journal='WAL', synchronous='OFF')
	pt.ensure_state_tables(conn)

	done = json.loads(pt.get_state(conn, 'tables_done', '[]')) if args.resume else []
	counts = pt.get_row_counts(conn) or {} if args.resume else {}

	for table in pt.TABLE_ORDER:
		if table in done:
			log('%s: already done, skipping (--resume)' % table)
			continue
		counts[table] = build_table(conn, table, sections, args.sections, sectionmap, pmcidmap)
		done.append(table)
		pt.set_state(conn, 'tables_done', done)
		pt.set_row_counts(conn, counts)

	conn.execute('DELETE FROM applied_sections')
	pt.record_sections(conn, sections, 'full')
	pt.set_state(conn, 'schema_version', str(pt.SCHEMA_VERSION))
	pt.set_state(conn, 'mode', 'full')
	pt.set_state(conn, 'built_at', time.strftime('%Y-%m-%dT%H:%M:%S'))
	pt.set_state(conn, 'max_section', sections[0] if sections else '')
	# Recorded so the incremental path can refuse to run across an annual
	# baseline turnover, when section numbers restart at 0001.
	years = set()
	for path in glob.glob(args.source_glob):
		m = re.search(r'pubmed(\d+)n\d+\.xml', os.path.basename(path))
		if m:
			years.add(m.group(1))
	if len(years) == 1:
		pt.set_state(conn, 'baseline_year', years.pop())
	else:
		log('WARNING: could not determine a single baseline year from %s (%s)'
		    % (args.source_glob, sorted(years)))
	pt.set_row_counts(conn, counts)
	pt.set_state(conn, 'tables_done', [])

	log('checkpointing and switching back to a rollback journal')
	pt.finalize_journal(conn)
	conn.close()

	os.replace(building, args.db)
	log('built %s (%d bytes)' % (args.db, os.path.getsize(args.db)))
	print(json.dumps({'mode': 'full', 'sections': len(sections), 'row_counts': counts}), flush=True)


if __name__ == '__main__':
	main()
