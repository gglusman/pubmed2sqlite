# PubMed → SQLite

Downloads the daily update files from PubMed, extracts their content, maintains a
SQLite database (`PubMed.db`) of citations, and deploys it once it passes validation.
Assumes the annual baseline has already been downloaded — see
https://pubmed.ncbi.nlm.nih.gov/download/.

Created by Gwênlyn Glusman (Institute for Systems Biology), April 2025

## Running it

```
bin/updateAll.pl [--incremental | --full] [--no-deploy] [--skip-download]
                 [--refresh-idlist] [--integrity-check]
```

**`--incremental`** (default) copy-on-write clones the deployed database into the
staging area, applies only the sections extracted since that database was built,
validates, and swaps it back. The daily delta is one update file — roughly 23k
citations against 41M — so this takes minutes.

**`--full`** rebuilds everything from the section files, the way the pipeline
originally worked. Slower, but it is the ground truth: it re-derives `id.list.gz`,
re-applies the whole deleted-PMID list, and defragments the file. Run weekly.

The reflink clone is what makes the incremental mode cheap. `/ssd2` is XFS with
`reflink=1`, and the staging and deployment directories are on the same filesystem,
so cloning the 95 GB database is metadata-only: about a second, and no extra space
until pages diverge. Deployment remains an atomic `rename(2)`, so readers never see
a partially written database.

Cron:

```
0 23 * * 0-5 cd /15TB_1/users/gglusman/PubMed ; nice bin/updateAll.pl --incremental >> build.log 2>&1
0 23 * * 6   cd /15TB_1/users/gglusman/PubMed ; nice bin/updateAll.pl --full        >> build.log 2>&1
```

## Pipeline

| stage | script | notes |
|---|---|---|
| download | `wget` in `updateAll.pl` | mirrors `updatefiles/`; `-nc` skips what is already on disk |
| extract | `bin/extract_incremental_xml.py` | one `sections/NNNN/` directory of gzipped TSVs per source XML file; already incremental — a section is parsed exactly once |
| enumerate | `updateAll.pl` (`--full` only) | rebuilds `id.list.gz`: pmid → winning section → pmcid, minus deleted PMIDs |
| build / update | `bin/buildPubMedSqlite.py` or `bin/updatePubMedSqlite.py` | |
| validate | `bin/checkPubMedSqlite.py` | gate; non-zero exit means do not deploy |
| deploy | `updateAll.pl` | rollback snapshot, then `rename(2)` into `/ssd2/sqlite/` |

`bin/pubmed_tables.py` holds the table definitions and the row parsing that the full
and incremental paths share, so the two cannot drift apart in how they read a
section file.

## Revision and deletion semantics

For each PMID, **the highest-numbered section containing it wins**; rows from lower
sections are discarded. PMIDs in NCBI's cumulative `deleted.pmids.gz` are dropped
entirely.

Because every new section is numbered above every already-applied section, the
incremental path reproduces a full rebuild exactly: delete every row for the PMIDs
appearing in the new sections (plus any newly deleted PMIDs), then re-insert those
sections' rows under the winning-section rule. A PMID not mentioned in any new
section cannot have changed its winner, so its rows are provably still correct.

`<DeleteCitation>` blocks inside the update XML are **not** parsed. Deletions land
only when NCBI refreshes the cumulative list, which happens every few days.

Deleted-PMID bookkeeping:

- `deleted.pmids.gz` — the latest good download from NCBI.
- `deleted.pmids.applied.gz` — a copy of the list the *deployed* database reflects,
  written only after a successful deploy. The incremental run applies the difference
  between the two, so a failed run re-applies the same delta next time instead of
  losing it.
- `deleted.pmids.prev.gz` — obsolete, left over from the previous single-generation
  rotation. Nothing reads or writes it any more.

## Database

Five tables, no primary keys, implicit rowids: `info` (pmid, section, firstauthor,
year, journal, title, abstract), `acc`, `mesh`, `ids`, `type`, with eleven indexes.
`author-info.txt.gz` is extracted but not loaded.

Two bookkeeping tables travel inside the file so that a copy of the deployed database
knows what it contains:

- `applied_sections(section, applied_at, mode)`
- `build_state(key, value)` — `schema_version`, `mode`, `built_at`, `max_section`,
  `baseline_year`, and `row_counts`

`row_counts` is maintained arithmetically by the incremental path and re-anchored to
a true `count(*)` by each full rebuild; counting 404M `mesh` rows nightly would cost
more than the update itself.

## State and recovery

**Bootstrapping a database that predates this scheme.** An incremental run refuses to
touch a database with no `applied_sections`. Either wait for the next `--full` run, or
seed it:

```
python3 bin/extract_incremental_xml.py --backfill-markers   # certify existing sections
cp --reflink=always /ssd2/sqlite/PubMed.db /ssd2/gglusman/PubMed.db.seed
python3 bin/updatePubMedSqlite.py --db /ssd2/gglusman/PubMed.db.seed --seed --seed-count-rows
cp deleted.pmids.gz deleted.pmids.applied.gz
mv /ssd2/gglusman/PubMed.db.seed /ssd2/sqlite/PubMed.db
```

Seeding verifies itself: the newest sections' records must actually be present in
`info` under their own section number before the state is written.

**Rollback.** Each deploy first takes a reflink snapshot of the outgoing database in
`/ssd2/gglusman/PubMed.rollback/` (near-instant, costs only the blocks that later
diverge; pruned after 7 days). To revert:

```
mv /ssd2/gglusman/PubMed.rollback/PubMed.db.<stamp> /ssd2/sqlite/PubMed.db
```

**Failures.** `updateAll.pl` exits non-zero and deploys nothing. `updatePubMedSqlite.py`
exits 3 for "this cannot be done incrementally — rebuild instead";
`checkPubMedSqlite.py` exits 2 for "do not deploy". A rejected candidate is left in
`/ssd2/gglusman/` for inspection.

**Annual baseline turnover (each December) needs a manual reset.** NCBI restarts
section numbering at `0001` for the new year, which collides with the existing
`sections/NNNN` directories and breaks the "highest section wins" ordering. Both the
updater and the extractor will refuse or silently skip rather than corrupt the
database, but the fix is manual:

```
mv sections sections_<oldyear> && rm -f id.list.gz
# re-download the new baseline, then
bin/updateAll.pl --full
```

## Legacy

`bin/extract.pl`, `bin/extract-incremental-*.pl`, `bin/buildSqlite.pl`,
`bin/buildTableIDs.*`, `bin/collect*.pl`, `bin/enumerateIDs*.pl`, `bin/addPMC.pl`,
`bin/idtypes.pl`, `bin/updateAll-old.pl` and `bin/buildAbstractIndex.py` are earlier
versions or one-off tools, kept for reference. None are in the nightly path.
