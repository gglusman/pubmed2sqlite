#!/bin/env perl
use strict;
$|=1;

my $dbfile = "/ssd2/gglusman/PubMed.db";
my $deployedfile = "/ssd2/sqlite/PubMed.db";

# Update downloads
doLog("Initiating update");
`wget -r -nc "ftp://ftp.ncbi.nlm.nih.gov/pubmed/updatefiles/"`;
rename "deleted.pmids.gz", "deleted.pmids.prev.gz";
`wget "https://ftp.ncbi.nlm.nih.gov/pubmed/deleted.pmids.gz"`;

# Extract new content from downloads
doLog("Extracting new content");
`bin/extract-incremental.pl baseline/*.gz updatefiles/*.gz >> extract-incremental.log`;

# Enumerate sections, ids, pmcids
doLog("Enumerating ids");
my $dir = "sections";
my @sections = reverse(sort(fulldirlist($dir)));

my %del;
open DEL, "gunzip -c deleted.pmids.gz |";
while (<DEL>) {
	chomp;
	$del{$_}++;
}
close DEL;

my %pmc;
my %section;
foreach my $section (@sections) {
	open IDS, "gunzip -c $dir/$section/pub-ids.txt.gz |";
	#$_ = <IDS>;
	while (<IDS>) {
		chomp;
		my($id, $pmcid) = split /\t/, $_, 3;
		next if $del{$id};
		next if $section{$id};
		$section{$id} = $section;
		next unless $pmcid;
		($pmcid) = $pmcid =~ /^PMC(\d+)/;
		$pmc{$id} = $pmcid;
	}
	close IDS;
}
open TODO, "| gzip -c >id.list.gz";
while (my($id, $section) = each %section) {
	print TODO join("\t", $id, $section, $pmc{$id}), "\n";
}
close TODO;

# Recreate sqlite db
doLog("Rebuilding db");
`python3 bin/buildPubMedSqlite.py > pybuildSqlite.log`;

my $prevsize = -s $deployedfile;
my $newsize  = -s $dbfile;
my $ratio = $newsize/$prevsize;
if ($ratio < 1.1 && $ratio > 0.9) {
	doLog("deploying $dbfile to $deployedfile");
	`mv $dbfile $deployedfile`;
	`chgrp www-data $deployedfile`;
	`chmod g+w $deployedfile`;
} else {
	doLog("size ratio $ratio outside range 0.9 - 1.1, not deploying");
}
doLog("done");


###
sub doLog {
	my $now = `date`;
	chomp $now;
	print join("\t", $now, @_), "\n";
}

sub fulldirlist {
	my($dir) = @_;
	opendir (DIR, $dir);
	my @files = grep /^[^.]/, readdir DIR;
	closedir DIR;
	return @files;
}
