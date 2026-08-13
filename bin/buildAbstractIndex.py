import gzip
import glob
import os
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET

baselineDir = "/15TB_1/users/gglusman/PubMed/baseline"
updateDir = "/15TB_1/users/gglusman/PubMed/updatefiles"
dbFile = "/ssd2/gglusman/PubMedAbstracts.db"

BATCH_SIZE = 50000


def articleFiles():
	baseline = sorted(glob.glob(os.path.join(baselineDir, "pubmed*n*.xml.gz")))
	updates = sorted(glob.glob(os.path.join(updateDir, "pubmed*n*.xml.gz")))
	return baseline + updates


def extractAbstract(articleElem):
	parts = []
	for abstractText in articleElem.findall('.//Abstract/AbstractText'):
		label = abstractText.get('Label')
		text = ''.join(abstractText.itertext()).strip()
		if not text:
			continue
		if label:
			parts.append(f"{label}: {text}")
		else:
			parts.append(text)
	return ' '.join(parts)


def parseFile(path):
	"""Yield (pmid, abstract) for every PubmedArticle in the file, and
	(pmid, None) for every DeleteCitation PMID (so callers can choose to
	drop stale entries -- kept simple here: we don't delete, a superseding
	update record would already overwrite via INSERT OR REPLACE, and NLM
	deletions are rare/edge-case for this reusable general-purpose index)."""
	opener = gzip.open if path.endswith('.gz') else open
	with opener(path, 'rb') as f:
		context = ET.iterparse(f, events=('end',))
		for event, elem in context:
			if elem.tag == 'PubmedArticle':
				pmidElem = elem.find('./MedlineCitation/PMID')
				if pmidElem is not None and pmidElem.text:
					pmid = int(pmidElem.text)
					abstract = extractAbstract(elem)
					if abstract:
						yield (pmid, abstract)
				elem.clear()


def main():
	os.makedirs(os.path.dirname(dbFile), exist_ok=True)
	conn = sqlite3.connect(dbFile)
	conn.execute("pragma journal_mode=WAL")
	conn.execute("pragma synchronous=OFF")
	conn.execute("create table if not exists abstracts (pmid integer primary key, abstract text)")

	files = articleFiles()
	startIndex = int(sys.argv[1]) if len(sys.argv) > 1 else 0
	print(f"# {len(files)} files to process, starting at index {startIndex}", file=sys.stderr)

	totalRows = 0
	t0 = time.time()
	for fi, path in enumerate(files):
		if fi < startIndex:
			continue
		batch = []
		fileRows = 0
		try:
			for pmid, abstract in parseFile(path):
				batch.append((pmid, abstract))
				fileRows += 1
				if len(batch) >= BATCH_SIZE:
					conn.executemany("insert or replace into abstracts values (?,?)", batch)
					conn.commit()
					batch = []
			if batch:
				conn.executemany("insert or replace into abstracts values (?,?)", batch)
				conn.commit()
		except ET.ParseError as e:
			print(f"# WARNING: skipping unparseable file {path}: {e} "
				f"(size={os.path.getsize(path)} bytes)", file=sys.stderr, flush=True)
			continue
		totalRows += fileRows
		elapsed = time.time() - t0
		print(f"# [{fi+1}/{len(files)}] {os.path.basename(path)}: {fileRows} abstracts "
			f"(total {totalRows}, {elapsed:.0f}s elapsed)", file=sys.stderr, flush=True)

	print("# building index...", file=sys.stderr)
	conn.commit()
	conn.close()
	print(f"# done: {totalRows} total abstracts indexed", file=sys.stderr)


if __name__ == '__main__':
	main()
