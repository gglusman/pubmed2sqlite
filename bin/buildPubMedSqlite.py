import os
import gzip
from sqlite_utils import Database

def readIDs(file):
	sectionmap = {}
	pmcidmap = {}
	print('reading identifiers', flush=True)
	with gzip.open(file, 'rt') as ids:
		for line in ids:
			pmid, section, *rest = line.strip().split('\t', -1)
			sectionmap[pmid] = section
			try: pmcidmap[pmid] = rest[0]
			except: pass
			#if pmcid:
			#	pmcidmap[pmid] = pmcid
	return sectionmap, pmcidmap

def tableExists(db, table):
	try:
		db[table].schema
		return 1
	except:
		return 0

def buildTable(db, table, sourcefile, fields, indexBy):
	if tableExists(db, table): return
	fnames = list(fields.keys())
	db[table].create(fields)
	for section in sections:
		print(table, section, sep='\t', flush=True)
		content = []
		with gzip.open('/'.join([dir, section, sourcefile]), 'rt') as source:
			for line in source:
				*values, = line.strip().split('\t')
				pmid = values[0]
				if not pmid: continue
				if pmid in sectionmap and section != sectionmap[pmid]: continue
				if table == 'ids': # table-specific code:
					seen = {}
					for alt in values[1:]:
						if not alt: continue
						if alt in seen: continue
						seen[alt] = 1
						content.append({'pmid': pmid, 'alt': alt})
				elif table == 'mesh':
					try: values.insert(1, pmcidmap[pmid])
					except: values.insert(1, '')
					content.append(dict(zip(fnames, values)))
				else: # general case
					content.append(dict(zip(fnames, values)))
		db[table].insert_all(content)

	### Index the table
	for field in indexBy:
		print("indexing", table, "by", field, sep=' ', flush=True)
		db[table].create_index([field])


### General definitions
idsfile = "id.list.gz"
dir = 'sections'
dbfile = "/ssd2/gglusman/PubMed.db"

### Preparation
db = Database(dbfile)#.enable_wal()
sectionmap, pmcidmap = readIDs(idsfile)
sections = os.listdir(dir)
sections = sorted(sections, reverse=True)

### Build the tables
buildTable(db, 'acc', 'pub-acc.txt.gz', {'pmid': int, 'acc': str}, ['pmid', 'acc'])

buildTable(db, 'mesh', 'pmid-mesh.txt.gz', {'pmid': int, 'pmcid': int, 'mesh': str, 'mesh_major': str, 'qual': str, 'qual_major': str}, ['pmid', 'pmcid', 'mesh', 'qual'])

buildTable(db, 'info', 'pub-info.txt.gz', {'pmid': int, 'section': int, 'firstauthor': str, 'year': int, 'journal': str, 'title': str}, ['pmid'])

buildTable(db, 'ids', 'pub-ids.txt.gz', {'pmid': int, 'alt': str}, ['pmid', 'alt'])

buildTable(db, 'type', 'pub-type.txt.gz', {'pmid': int, 'type': str}, ['pmid'])
