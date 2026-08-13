#!/usr/bin/env python3
# Streaming, proper-XML-parser replacement for extract-incremental.pl.
# Reads PubMed baseline/updatefiles .xml.gz files and writes the same
# tab-delimited gzip section files as the Perl pipeline, sourced from
# lxml element trees instead of line-oriented regexes.

import gzip
import re
import sys

from lxml import etree

ID_TYPES = ["pubmed", "pmc", "doi", "pii", "mid", "pmcid", "medline", "pmpid"]

SECTION_FILES = {
	"mesh": "pmid-mesh.txt",
	"type": "pub-type.txt",
	"ids": "pub-ids.txt",
	"author": "author-info.txt",
	"info": "pub-info.txt",
	"acc": "pub-acc.txt",
}

WS_RE = re.compile(r"\s+")
NCT_RE = re.compile(r"NCT\d+")


def clean_text(elem):
	if elem is None:
		return ""
	text = "".join(elem.itertext())
	return WS_RE.sub(" ", text).strip()


def find_text(elem, path):
	found = elem.find(path)
	return clean_text(found) if found is not None else ""


def extract_year(article, pubmed_data):
	year = find_text(article, "Journal/JournalIssue/PubDate/Year")
	if year:
		return year
	medline_date = find_text(article, "Journal/JournalIssue/PubDate/MedlineDate")
	m = re.search(r"\d{4}", medline_date)
	if m:
		return m.group(0)
	for pubdate in pubmed_data.findall("History/PubMedPubDate"):
		y = find_text(pubdate, "Year")
		if y:
			return y
	return ""


def extract_accessions(article):
	accs = []
	seen_elems = []  # keep element refs alive: lxml proxies aren't stable across findall calls

	def add(bank, acc_elem):
		seen_elems.append(acc_elem)
		text = clean_text(acc_elem)
		if not text:
			return
		ncts = NCT_RE.findall(text)
		if ncts:
			accs.extend((bank, nct) for nct in ncts)
		else:
			accs.append((bank, text))

	for data_bank in article.findall("DataBankList/DataBank"):
		bank = find_text(data_bank, "DataBankName")
		for acc_elem in data_bank.findall("AccessionNumberList/AccessionNumber"):
			add(bank, acc_elem)

	# fallback: accessions found outside the expected DataBank structure
	for acc_elem in article.findall(".//AccessionNumber"):
		if not any(acc_elem is seen for seen in seen_elems):
			add("", acc_elem)

	return accs


def process_article(pubmed_article, pmid, section, writers):
	citation = pubmed_article.find("MedlineCitation")
	pubmed_data = pubmed_article.find("PubmedData")
	article = citation.find("Article") if citation is not None else None
	if article is None:
		return

	journal = find_text(article, "Journal/Title")

	title_elem = article.find("ArticleTitle")
	title = clean_text(title_elem)
	if not title:
		title = find_text(article, "VernacularTitle")

	abstract_parts = []
	for abstract_text in article.findall("Abstract/AbstractText"):
		text = clean_text(abstract_text)
		if text:
			abstract_parts.append(text)
	abstract = " ".join(abstract_parts)

	year = extract_year(article, pubmed_data) if pubmed_data is not None else ""

	first_author_last = ""
	for author in article.findall("AuthorList/Author"):
		last = find_text(author, "LastName")
		fore = find_text(author, "ForeName")
		init = find_text(author, "Initials")
		affiliation = find_text(author, "AffiliationInfo/Affiliation")
		if last and not first_author_last:
			first_author_last = last
		if affiliation:
			writers["author"].write("\t".join([pmid, year, last, fore, init, affiliation]) + "\n")

	for pub_type in article.findall("PublicationTypeList/PublicationType"):
		ui = pub_type.get("UI", "")
		if ui:
			writers["type"].write("\t".join([pmid, ui]) + "\n")

	for mesh_heading in (citation.findall("MeshHeadingList/MeshHeading") if citation is not None else []):
		descriptor = mesh_heading.find("DescriptorName")
		if descriptor is None:
			continue
		mesh_ui = descriptor.get("UI", "")
		mesh_major = descriptor.get("MajorTopicYN", "")
		qualifiers = mesh_heading.findall("QualifierName")
		if qualifiers:
			for qualifier in qualifiers:
				qual_ui = qualifier.get("UI", "")
				qual_major = qualifier.get("MajorTopicYN", "")
				writers["mesh"].write("\t".join([pmid, mesh_ui, mesh_major, qual_ui, qual_major]) + "\n")
		else:
			writers["mesh"].write("\t".join([pmid, mesh_ui, mesh_major, "", ""]) + "\n")

	for bank, accession in extract_accessions(article):
		writers["acc"].write("\t".join([pmid, bank, accession]) + "\n")

	ids = {"pubmed": pmid}
	if pubmed_data is not None:
		for article_id in pubmed_data.findall("ArticleIdList/ArticleId"):
			id_type = article_id.get("IdType", "")
			if id_type and id_type != "pubmed":
				ids[id_type] = clean_text(article_id)
	writers["ids"].write("\t".join(ids.get(t, "") for t in ID_TYPES) + "\n")

	writers["info"].write("\t".join([pmid, section, first_author_last, year, journal, title, abstract]) + "\n")


def extract_file(path, out_dir):
	m = re.search(r"n(\d+)\.xml", path)
	if not m:
		print(f"skip (no section number found): {path}", file=sys.stderr)
		return
	section = m.group(1)
	section_dir = out_dir / section
	if section_dir.exists():
		return

	print(path)
	section_dir.mkdir(parents=True, exist_ok=True)
	writers = {
		key: gzip.open(section_dir / f"{name}.gz", "wt")
		for key, name in SECTION_FILES.items()
	}

	try:
		with gzip.open(path, "rb") as fh:
			context = etree.iterparse(fh, events=("end",), tag="PubmedArticle")
			for _, pubmed_article in context:
				pmid_elem = pubmed_article.find("MedlineCitation/PMID")
				pmid = clean_text(pmid_elem)
				if pmid:
					process_article(pubmed_article, pmid, section, writers)
				pubmed_article.clear()
				while pubmed_article.getprevious() is not None:
					del pubmed_article.getparent()[0]
	finally:
		for writer in writers.values():
			writer.close()


def _extract_one(args):
	path, out_dir = args
	extract_file(path, out_dir)


def main():
	import os
	from concurrent.futures import ProcessPoolExecutor
	from pathlib import Path

	args = sys.argv[1:]
	out_dir = Path("sections")
	workers = min(32, os.cpu_count() or 1)
	while args and args[0].startswith("--"):
		if args[0].startswith("--outdir="):
			out_dir = Path(args[0].split("=", 1)[1])
		elif args[0].startswith("--workers="):
			workers = int(args[0].split("=", 1)[1])
		args = args[1:]

	if not args:
		print(f"usage: {sys.argv[0]} [--outdir=DIR] [--workers=N] <file.xml.gz> [file.xml.gz ...]", file=sys.stderr)
		sys.exit(1)

	out_dir.mkdir(exist_ok=True, parents=True)

	with ProcessPoolExecutor(max_workers=workers) as pool:
		list(pool.map(_extract_one, [(path, out_dir) for path in args]))


if __name__ == "__main__":
	main()
