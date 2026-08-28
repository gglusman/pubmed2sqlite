#!/bin/env perl

# Nightly PubMed pipeline: download, extract, update the sqlite database, deploy.
#
# Two modes:
#
#   --incremental (default, Sun-Fri)
#       Reflink-copy the deployed database into the staging area, apply just the
#       sections extracted since it was built, validate, and swap it back. The
#       daily delta is one update file -- ~23k citations against 41M -- so this
#       runs in minutes.
#
#   --full (Saturdays)
#       Rebuild everything from the section files, as the pipeline always did.
#       Slower, but it is the ground truth: it re-derives id.list.gz, re-applies
#       the whole deleted-pmid list, and defragments the file.
#
# The reflink copy is what makes the incremental mode cheap. /ssd2 is XFS with
# reflink=1, and staging and deployment live on the same filesystem, so copying
# the 95GB database is a copy-on-write clone: metadata only, about a second, and
# no extra space until pages actually diverge. The deploy stays an atomic
# rename(2), exactly as before -- readers never observe a partial database.

use strict;
use warnings;
$|=1;

my $stagedir     = "/ssd2/gglusman";
my $deployedfile = "/ssd2/sqlite/PubMed.db";
my $builtfile    = "$stagedir/PubMed.db";       # what a full rebuild produces
my $candidate    = "$stagedir/PubMed.db.new";   # what an incremental run patches
my $summaryfile  = "$stagedir/PubMed.update.json";
my $rollbackdir  = "$stagedir/PubMed.rollback";
my $rollbackdays = 7;

my $deleted      = "deleted.pmids.gz";          # latest downloaded from NCBI
my $applied      = "deleted.pmids.applied.gz";  # the copy the deployed db reflects
my $deletedurl   = "https://ftp.ncbi.nlm.nih.gov/pubmed/deleted.pmids.gz";

my $mode = 'incremental';
my($nodeploy, $skipdownload, $refreshidlist, $integritycheck) = (0, 0, 0, 0);
foreach my $arg (@ARGV) {
	if    ($arg eq '--full')            { $mode = 'full' }
	elsif ($arg eq '--incremental')     { $mode = 'incremental' }
	elsif ($arg eq '--no-deploy')       { $nodeploy = 1 }
	elsif ($arg eq '--skip-download')   { $skipdownload = 1 }
	elsif ($arg eq '--refresh-idlist')  { $refreshidlist = 1 }
	elsif ($arg eq '--integrity-check') { $integritycheck = 1 }
	else { die "usage: $0 [--full|--incremental] [--no-deploy] [--skip-download] [--refresh-idlist] [--integrity-check]\n" }
}

# Set when a candidate database is worth keeping for inspection rather than
# being cleaned up by the error handler.
my $keepcandidate = 0;

my $rc = eval { main(); 1 };
unless ($rc) {
	my $error = $@ || 'unknown error';
	chomp $error;
	doLog("FAILED: $error");
	unlink $candidate if $mode eq 'incremental' and !$keepcandidate;
	exit 1;
}
exit 0;


###
sub main {
	doLog("Initiating update (mode: $mode)");
	unless ($skipdownload) {
		run("wget -q -r -nc 'ftp://ftp.ncbi.nlm.nih.gov/pubmed/updatefiles/'", allow_failure => 1);
		refreshDeletedList();
	}

	doLog("Extracting new content");
	run("python3 bin/extract_incremental_xml.py baseline/*.gz updatefiles/*.gz >> extract-incremental.log");

	if ($mode eq 'full' or $refreshidlist) {
		doLog("Enumerating ids");
		enumerateIds();
	}

	$mode eq 'full' ? runFull() : runIncremental();
}

sub runFull {
	doLog("Rebuilding db from scratch");
	unlink $builtfile;
	run("python3 bin/buildPubMedSqlite.py --db $builtfile > pybuildSqlite.log");
	-s $builtfile or die "buildPubMedSqlite.py did not produce $builtfile";

	doLog("Validating");
	validate($builtfile, 'full', undef) or do {
		doLog("validation failed; not deploying. Candidate left at $builtfile");
		die "validation failed";
	};
	deploy($builtfile);
}

sub runIncremental {
	-e $deployedfile or die "no deployed database at $deployedfile; run with --full first";

	doLog("Staging a copy-on-write clone of $deployedfile");
	unlink $candidate;
	unless (reflink($deployedfile, $candidate)) {
		die "cp --reflink=always failed. Without reflink support this would be a 95GB "
		  . "byte copy every night; run with --full instead, or check that $stagedir and "
		  . "$deployedfile are on the same reflink-capable filesystem";
	}
	doLog(sprintf("Staged %s (%.1f GB)", $candidate, (-s $candidate)/1e9));

	doLog("Applying new sections");
	unlink $summaryfile;
	my $status = run("python3 bin/updatePubMedSqlite.py --db $candidate"
	               . " --deleted $deleted --prev-deleted $applied"
	               . " --json $summaryfile > /dev/null", allow_failure => 1);
	if ($status == 3) {
		die "the database cannot be updated incrementally (see the error above); "
		  . "re-run with --full";
	} elsif ($status != 0) {
		die "updatePubMedSqlite.py exited $status";
	}

	if (noop($summaryfile)) {
		doLog("No new sections and no new deletions; nothing to deploy");
		unlink $candidate;
		return;
	}

	doLog("Validating");
	validate($candidate, 'incremental', $summaryfile) or do {
		$keepcandidate = 1;
		doLog("validation failed; not deploying. Candidate left at $candidate for inspection");
		die "validation failed";
	};
	deploy($candidate);
}

sub validate {
	my($file, $vmode, $summary) = @_;
	my $cmd = "python3 bin/checkPubMedSqlite.py --db $file --deployed $deployedfile"
	        . " --mode $vmode --deleted $deleted";
	$cmd .= " --summary $summary" if $summary;
	$cmd .= " --integrity-check"  if $integritycheck;
	return run($cmd, allow_failure => 1) == 0;
}

sub deploy {
	my($file) = @_;
	if ($nodeploy) {
		doLog("--no-deploy: validated candidate left at $file");
		return;
	}
	snapshot();
	doLog("deploying $file to $deployedfile");
	rename $file, $deployedfile or die "rename $file -> $deployedfile: $!";
	run("chgrp www-data $deployedfile", allow_failure => 1);
	run("chmod g+w $deployedfile", allow_failure => 1);

	# Left behind by readers that once opened the previous file in WAL mode.
	# They describe a database that is no longer at this path.
	foreach my $sidecar ("$deployedfile-shm", "$deployedfile-wal") {
		next unless -e $sidecar;
		doLog("removing stale $sidecar");
		unlink $sidecar;
	}

	# Record which deleted-pmid list the deployed database now reflects. Only
	# updated on success, so a failed run re-applies the same delta next time
	# instead of losing it.
	run("cp $deleted $applied");
	`cd /15TB_2/gglusman/datasets/trials-papers && ./bin/run_update.sh pubmed &`;
	doLog("done");
}

sub snapshot {
	# Reflink clone of the outgoing database: near-instant, and it costs only the
	# blocks that later diverge. Restore with:
	#   mv /ssd2/gglusman/PubMed.rollback/PubMed.db.<stamp> /ssd2/sqlite/PubMed.db
	return unless -e $deployedfile;
	mkdir $rollbackdir unless -d $rollbackdir;
	my @t = localtime;
	my $stamp = sprintf("%04d%02d%02d-%02d%02d", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1]);
	my $snap = "$rollbackdir/PubMed.db.$stamp";
	if (reflink($deployedfile, $snap)) {
		doLog("rollback snapshot: $snap");
	} else {
		doLog("WARNING: could not snapshot $deployedfile; deploying without a rollback copy");
	}
	foreach my $old (glob "$rollbackdir/PubMed.db.*") {
		next unless -M $old > $rollbackdays;
		doLog("pruning old snapshot $old");
		unlink $old;
	}
}

sub reflink {
	my($src, $dst) = @_;
	return system("cp", "--reflink=always", $src, $dst) == 0;
}

sub noop {
	my($file) = @_;
	open my $fh, '<', $file or return 0;
	local $/;
	my $json = <$fh>;
	close $fh;
	return $json =~ /"noop":\s*true/ ? 1 : 0;
}

sub refreshDeletedList {
	# NCBI publishes one cumulative list of deleted PMIDs, refreshed every few
	# days. Download to a scratch name first: the previous code renamed the live
	# file out of the way before fetching, so a failed download left the pipeline
	# with no list at all and every deleted PMID silently reinstated.
	my $tmp = "$deleted.download";
	unlink $tmp;
	run("wget -q -O $tmp '$deletedurl'", allow_failure => 1);
	unless (-s $tmp and run("gzip -t $tmp", allow_failure => 1) == 0) {
		unlink $tmp;
		-s $deleted or die "could not download $deletedurl and no usable $deleted on disk";
		doLog("WARNING: could not refresh $deleted; keeping the existing copy");
		return;
	}
	if (-e $deleted and run("cmp -s $tmp $deleted", allow_failure => 1) == 0) {
		unlink $tmp;
		doLog("$deleted unchanged");
		return;
	}
	rename $tmp, $deleted or die "rename $tmp -> $deleted: $!";
	doLog("$deleted refreshed");
}

sub enumerateIds {
	# Rebuild id.list.gz: pmid -> winning section -> pmcid, excluding deleted
	# pmids. Input to the full rebuild only; the incremental path derives the
	# same mapping for just the new sections, so between weekly rebuilds this
	# file lags by up to six days. Force it with --refresh-idlist.
	my $dir = "sections";
	my @sections = reverse(sort(fulldirlist($dir)));

	my %del;
	open DEL, "gunzip -c $deleted |" or die "cannot read $deleted: $!";
	while (<DEL>) {
		chomp;
		$del{$_}++;
	}
	close DEL;
	keys %del or die "$deleted yielded no pmids";

	my %pmc;
	my %section;
	foreach my $section (@sections) {
		open IDS, "gunzip -c $dir/$section/pub-ids.txt.gz |" or die "cannot read $dir/$section: $!";
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
	open TODO, "| gzip -c >id.list.gz.new" or die "cannot write id.list.gz.new: $!";
	while (my($id, $section) = each %section) {
		print TODO join("\t", $id, $section, $pmc{$id}), "\n";
	}
	close TODO or die "failed writing id.list.gz.new";
	rename "id.list.gz.new", "id.list.gz" or die "rename id.list.gz.new: $!";
	doLog(sprintf("id.list.gz: %d live pmids across %d sections", scalar keys %section, scalar @sections));
}

sub run {
	my($cmd, %opt) = @_;
	my $status = system($cmd);
	if ($status == -1) {
		die "failed to run: $cmd";
	}
	my $exit = $status >> 8;
	if ($exit and !$opt{allow_failure}) {
		die "command exited $exit: $cmd";
	}
	return $exit;
}

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
