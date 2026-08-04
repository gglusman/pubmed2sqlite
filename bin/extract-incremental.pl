#!/bin/env perl
use strict;
$|=1;

my $meshFile = "mesh-terms.txt";
my $qualFile = "mesh-quals.txt";
my $meshAliasesFile = "mesh-term-aliases.txt";
my $qualAliasesFile = "mesh-qual-aliases.txt";
my $paperFile = "pmid-mesh.txt";
my $pubTypeFile = "pub-type.txt";
my $pubIdsFile = "pub-ids.txt";
my $authFile = "author-info.txt";
my $infoFile = "pub-info.txt";
my $accessionsFile = "pub-acc.txt";
my $isbFile = "isb-papers.txt";
my @idTypes = qw/pubmed pmc doi pii mid pmcid medline pmpid/;
my $dir = "sections";
mkdir $dir, 0755;
#print PT join("\t", qw/pmid pub_type/), "\n";
#print PI join("\t", @idTypes), "\n";
#print PF join("\t", qw/pmid mesh mesh_major qual qual_major/), "\n";
#print PN join("\t", qw/pmid year lastname forename initials affiliation/), "\n";
#print PII join("\t", qw/pmid section firstauthor year journal title abstract/), "\n";
my(%meshName, %qualName);
foreach my $file (shuffle(@ARGV)) {
	my($section) = $file =~ /n(\d+)\.xml/;
	next if -e "$dir/$section";
	print "$file\n";
	mkdir "$dir/$section", 0755;
	open PF, "| gzip -c > $dir/$section/$paperFile.gz";
	open PT, "| gzip -c > $dir/$section/$pubTypeFile.gz";
	open PI, "| gzip -c > $dir/$section/$pubIdsFile.gz";
	open PN, "| gzip -c > $dir/$section/$authFile.gz";
	open PII, "| gzip -c > $dir/$section/$infoFile.gz";
	open PAC, "| gzip -c > $dir/$section/$accessionsFile.gz";
	open ISB, ">$dir/$section/$isbFile";
	my(%art, %au, %date);
	open X, "gunzip -c $file |";
	while (<X>) {
		if (/^  <PubmedArticle>/) {
			%art = ();
			%date = ();
			%au = ();
		} elsif (/^      <PMID.*>(\d+)<\/PMID>/) {
			$art{'pubmed'} = $1;
		} elsif (/^\s*<PublicationType UI="(.+?)">/) {
			#<PublicationType UI="D016428">Journal Article</PublicationType>
			print PT join("\t", $art{'pubmed'}, $1), "\n";
		} elsif (/^\s*<AccessionNumber[^>]*>(.+?)<\/AccessionNumber/) {
			my $accs = $1;
			if ($accs =~ /NCT\d+/) {
				while ($accs =~ /(NCT\d+)(.*)/) {
					print PAC join("\t", $art{'pubmed'}, $1), "\n";
					$accs = $2;
				}
			} else {
				print PAC join("\t", $art{'pubmed'}, $accs), "\n";
			}
		} elsif (/^\s*<MeshHeading[^>]*>/) {
			$_ = <X>;
			#<DescriptorName UI="D016030" MajorTopicYN="Y">Kidney Transplantation</DescriptorName>
			my($mesh, $mmajor, $mname) = /<DescriptorName UI="(.+?)" MajorTopicYN="(.+?)"[^>]*>(.+?)<\/DescriptorName>/;
			next unless $mesh;
			#$meshName{$mesh}{$mname}++;
			$_ = <X>;
			#<QualifierName UI="Q000379" MajorTopicYN="N">methods</QualifierName>
			my($qual, $qmajor, $qname) = /<QualifierName UI="(.+?)" MajorTopicYN="(.+?)"[^>]*>(.+?)<\/QualifierName>/;
			#$qualName{$qual}{$qname}++ if $qname;
			print PF join("\t", $art{'pubmed'}, $mesh, $mmajor, $qual, $qmajor), "\n";
		} elsif (/^\s*<ArticleId IdType="(.+?)"[^>]*>(.+?)<\/ArticleId>/) {
			$art{$1} = $2 if $1 ne 'pubmed';
		} elsif (/^  <\/PubmedArticle>/) {
			print PI join("\t", map {$art{$_}} @idTypes), "\n";
			print PII join("\t", $art{'pubmed'}, $section, $art{'fau'}, $date{'year'}, $art{'journal'}, $art{'title'}, $art{'abstract'}), "\n";
		} elsif (/^\s*<LastName[^>]*>(.+?)<\/LastName>/) {
			$au{'last'} = $1;
			$art{'fau'} ||= $1;
		} elsif (/^\s*<ForeName[^>]*>(.+?)<\/ForeName>/) {
			$au{'fore'} = $1;
		} elsif (/^\s*<Initials[^>]*>(.+?)<\/Initials>/) {
			$au{'init'} = $1;
		} elsif (/^\s*<Affiliation[^>]*>(.+?)<\/Affiliation>/) {
			my $aff = $1;
			print PN join("\t", $art{'pubmed'}, $date{'year'}, $au{'last'}, $au{'fore'}, $au{'init'}, $aff), "\n";
			if ($aff =~ /systems? biology/i && $aff =~ /seattle/i && $aff !~ /Centre O3/) {
				print ISB join("\t", $art{'pubmed'}, $date{'year'}, $au{'last'}, $au{'fore'}, $au{'init'}, $aff), "\n";
			}
		} elsif (/^\s*<\/Author>/) {
			%au = ();
		} elsif (/^          <Title[^>]*>(.+)<\/Title>/) {
			$art{'journal'} = $1;
		} elsif (/^\s*<ArticleTitle[^>]*>(.+)/) {
			my $title = $1;
			while ($title !~ /<\/ArticleTitle>/) {
				$_ = <X>;
				chomp;
				s/^\s*//;
				$title .= $_;
			}
			$title =~ s/<\/ArticleTitle>.*//;
			$title =~ s/<.*?>//g;
			$art{'title'} = $title;
		} elsif (!$art{'title'} && /^\s*<VernacularTitle[^>]*>(.*)<\/VernacularTitle>/) {
			$art{'title'} = $1;
		} elsif (/^\s*<AbstractText[^>]*>(.*)<\/AbstractText>/) {
			$art{'abstract'} .= "$1 ";
		} elsif (/^\s*<(PubMed)?PubDate/i) {
			next if $date{'year'};
			while (<X>) {
				last if /^\s*<\/(PubMed)?PubDate>/i;
				if (/^\s*<Year[^>]*>(.+?)<\/Year>/i) {
					$date{'year'} = $1;
					#print PII join("\t", $art{'pubmed'}, $date{'year'}, $art{'title'}), "\n";
					last;
				}
			}
		}
	}
	close X;
	#dumpMesh();
	close ISB;
	close PAC;
	close PII;
	close PN;
	close PI;
	close PF;
	close PT;
}


sub dumpMesh {
	open MF, ">$dir/$meshFile";
	open MAF, ">$dir/$meshAliasesFile";
	foreach my $mesh (sort keys %meshName) {
		my $names = $meshName{$mesh};
		my($name, @aliases) = sort {$names->{$b} <=> $names->{$a}} keys %$names;
		print MF join("\t", $mesh, $names->{$name}, $name), "\n";
		print MAF join("\t", $mesh, $names->{$_}, $_), "\n" foreach @aliases;
	}
	close MF;
	close MAF;

	open QF, ">$dir/$qualFile";
	open QAF, ">$dir/$qualAliasesFile";
	foreach my $mesh (sort keys %qualName) {
		my $names = $qualName{$mesh};
		my($name, @aliases) = sort {$names->{$b} <=> $names->{$a}} keys %$names;
		print QF join("\t", $mesh, $names->{$name}, $name), "\n";
		print QAF join("\t", $mesh, $names->{$_}, $_), "\n" foreach @aliases;
	}
	close QF;
	close QAF;
}

sub shuffle {
	my(@v) = @_;
	my @s;

	while (@v) {
		my $pick = int(rand(scalar @v));
		push @s, $v[$pick];
		splice @v, $pick, 1;
	}
	return @s;
}