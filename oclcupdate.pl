#!/s/sirsi/Unicorn/Bin/perl -w
########################################################################################
#
# Perl source file for project oclcupdate 
# Purpose: Update bib records from OCLC transaction reports.
# Method:  Parse OCLC batch load reports and update bib records with API
#          calalogmerge et al.
#
# Update bib records from OCLC transaction reports
#    Copyright (C) 2014  Andrew Nisbet
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# Author:  Andrew Nisbet, Edmonton Public Library
# Created: Wed Jul 9 11:34:55 MDT 2014
# Rev: 
#          0.4 - Output of TCNs that are not referenced in OCLC report directly to log. 
#          0.3 - Checked handling for TCNs that point to more than one cat key. 
#                Added more comments.
#          0.2 - Add parsing for TCNs from OCLC that start (Sirsi) since
#                the prefix will cause the selcatalog -iF to fail. 
#                Confirmed:  echo "(Sirsi) a728376" | selcatalog -iF fails
#                Confirmed:  echo "a728376" | selcatalog -iF succeeds
#          0.1 - Initial tested. 
#          0.0 - Dev. 
#
#########################################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;

# Environment setup required by cron to run script because its daemon runs
# without assuming any environment settings and we need to use sirsi's.
###############################################
# *** Edit these to suit your environment *** #
$ENV{'PATH'}  = qq{:/s/sirsi/Unicorn/Bincustom:/s/sirsi/Unicorn/Bin:/usr/bin:/usr/sbin};
$ENV{'UPATH'} = qq{/s/sirsi/Unicorn/Config/upath};
###############################################
my $VERSION                     = qq{0.4};
my $OCLC_DIR                    = qq{/s/sirsi/Unicorn/EPLwork/cronjobscripts/OCLC};
# my $OCLC_DIR                    = qq{/s/sirsi/Unicorn/EPLwork/anisbet};
my $LOG_DIR                     = $OCLC_DIR;
chomp( my $date                 = `transdate -d-0` );
my $LOG_FILE_NAME               = qq{$LOG_DIR/oclc$date.log};  # Name and location of the log file.
my $FLAT_MARC_OVERLAY_FILE_NAME = qq{$OCLC_DIR/overlay_records.flat};
chomp( my $TEMP_DIR             = `getpathname tmp` );

# Keep track of everything we do so we can do forensics later if need be.
open LOG, ">$LOG_FILE_NAME";

#
# Message about this program and how to use it.
#
sub usage()
{
    print STDERR << "EOF";

	usage: $0 [-xdU]
Updates bibrecords with missing OCLC numbers extracted from OCLC CrossRef Reports
produced by the batch load process. Example input file: D120913.R468704.XREFRPT.txt.

By default the script will go through the motions of what it is going to do including
all output, but will NOT update bib records. To do that use the '-U' flag. See below.

 -d : debug (keeps temp files etc.)        
 -U : Actually do the update.             
 -x: This (help) message.

example: $0 -x
Version: $VERSION
EOF
    exit;
}

# Fetch the valid Mixed reports - not Cancels and not summaries.
# param:  <none>
# return: list valid reports to parse out OCLC numbers.
# TODO:   fix so that it ftps reports from psw.oclc.org.
sub getMixedReports
{
	my @fileList = ();
	# Search the current directory for reports.
	logit( "checking $OCLC_DIR for reports" );
	my @tmp = <$OCLC_DIR/D[0-9][0-9][0-9][0-9][0-9][0-9]\.R*>;
	# my @tmp = <test.XREFRPT.txt>;
	while ( @tmp )
	{
		# separate the XREFRPT files.
		my $file = shift( @tmp );
		# TODO get files from the report site itself with wget --user=100313990 --password=some_password http://psw.oclc.org/download.aspx?setd=netbatch
		# returns a page requesting login.
		next if ( $file !~ m/XREFRPT/ );
		push( @fileList, $file );
	}
	logit( "found ".scalar( @fileList )." report(s)." );
	return @fileList;
}

#
# Trim function to remove whitespace from the start and end of the string.
# param:  string to trim.
# return: string without leading or trailing spaces.
sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

#
# Prints the argument message to stdout and log file.
# param:  message string.
# return: 
# side effect: writes message to log file.
sub logit( $ )
{
	my $msg = shift;
	chomp( my $timeStamp = `date` );
	print     "$timeStamp $msg\n";
	print LOG "$timeStamp $msg\n";
}

# Creates a reference table of the title control numbers and corresponding OCLC numbers from an OCLC report.
# param:  the name of the file to be read; must be a valid XRef file sent from OCLC like D120913.R468637.XREFRPT.txt.
# param:  the hash of all TCNs and OCLC numbers collected so far.
# return: hash reference of TCNs and correct OCLC numbers. Looks like $hash->{ TCN } = OCLC_Num
sub getXRefRecords( $$ )
{
	my $file = shift;
	my $hash = shift;
	open( REPORT, "<$file" ) or die "Error: unable to open '$file': $!\n";
	while (<REPORT>)
	{
		my $line = trim( $_ )."\n"; # Trim takes off the white space and newline.
		# skip blank lines and lines that don't start with numbers 
		next if ( $line !~ m/^\d/ ); # skip if the line doesn't start with a number.
		# lets split the line on the white space swap the values so the 001 (TCN) field is first.
		my @oclc001 = split( /\s{2,}/, $line );
		chomp( $oclc001[1] );
		# Strip off the leading '(Sirsi)' as per revision 0.2 notes.
		$oclc001[1] =~ s/\(Sirsi\)//;
		# We do this to remove the white space between the, now gone, '(Sirsi)' and the number.
		$oclc001[1] = trim( $oclc001[1] );
		# Looks like $hash->{ TCN } = OCLC_Num
		# Looks like $hash->{ a475180 } = 51296469
		$hash->{$oclc001[1]} = $oclc001[0];
	}
	close( REPORT );
	return $hash;
}

# Kicks off the setting of various switches.
# param:  <none>
# return: <none>
sub init
{
    my $opt_string = 'dUx';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ( $opt{'x'} );
}

init();

# Updating by cat key is more reliable.
# This flat MARC fragment works:
# -- snip --
# *** DOCUMENT BOUNDARY ***
# FORM=MARC
# .1003.   |a728376
# .035.   |a(OCoLC)12333333
# -- snip --
# then run it with this:
# cat oclc_test.flat | catalogmerge -aMARC -fd -if -t035 -r -un -bc -q
# -fd d use the accession number as is (3001). This should read 1003.
# -if flat ascii records will be read from standard input.
# -t035 which field to update.
# -r reorder record according to format.
# -u has multiple options: n no updates.
# -b is followed by one option to indicate how bib records will be matched for update.
#     c matches on the internal catalog key. (which is the accession number, or '(Sirsi) a<catkey>', as it may appear in the .035. record.)
# -q removes all pre-existing .035. records.
# RESULTS:
# bash-3.2$ cat oclc_test.flat | catalogmerge -aMARC -fd -if -t035 -r -un -bc -q
# Symphony $<catalog:u> $<merge:u> 3.4.1 $<started_on> $<wednesday:u>, $<july:u> 9, 2014, 10:09 AM
# $(11191) MARC.
# $(11403)
# $(11649)
# $(11187)
# $(11177)
# $(11297)035
# $(11298)
# $(11293)
# $(11201)
# **Entry ID not found in format MARC: 1003
# 728376|
  # 4 $(1401)
  # 1 $<catalog> $(1402)
  # 0 $<catalog> $(1403)
  # 1 $<catalog> $(1405)
# Symphony $<catalog:u> $<merge:u> $<finished_on> $<wednesday:u>, $<july:u> 9, 2014, 10:09 AM
# -- snip --
# Warnings like:
# **Entry ID not found in format MARC: 1003
# are produced because there is no entry for 1003 in MARC - Sirsi made it up and so it is proprietary.
# Valid MARC bib records only go up to .999.
### NOTE: The message is only a warning, the bib record will be updated. ###
# bash-3.00$ head D120906.R466902.XREFRPT.txt
#    OCLC XREF REPORT
#             
#    OCLC        Submitted
#    Control #   001 Field
#    51296469    a475180       # OCLC Number      TCN/Flex key                                                         
#    51042192    a475689                                                          
#    51868698    a475713                                                          
#    51282754    a475733                                                          
#    51276424    a475735                                                          

# find all the files that match the D120906.R466902.XREFRPT.txt file name.
logit( "===" );
my @fileList = getMixedReports();
my $oclcNumberHash = {};
while ( my $report = shift( @fileList ) )
{
	# my $report = shift( @fileList );
	logit( "reading '$report'" );
	# read each report and build master hash of tcn->OCLC_num
	## Looks like $hash->{ TCN } = OCLC_Num
	## Looks like $hash->{ a475180 } = 51296469
	getXRefRecords( $report, $oclcNumberHash );
}

## optimize selcatalog query: format hash keys into a file ready for pipeing into selcatalog -iF
open( TCN_FILE, ">$TEMP_DIR/tmp_a" ) or die "Couldn't open '$TEMP_DIR/tmp_a' to write: $!\n";
my $tcnCount = 0; 
for my $titleControlNumber ( keys %$oclcNumberHash )
{
	print TCN_FILE "$titleControlNumber\n";
	$tcnCount++;
}
close( TCN_FILE );
logit( "Total OCLC report entries: $tcnCount" );

# Quick trip to next report if the report contained no entries.
exit 0 if ( $tcnCount == 0 );
# otherwise use the TCN and selcatalog to get all the information we will need to build an overlay flat file.
my $recordsWithSirsi035     = 0;
my $recordsWithOCoLC035     = 0;
my $totalBibRecordsModified = 0;
my $selcatalogAPIResults    = `cat "$TEMP_DIR/tmp_a" | selcatalog -iF 2>/dev/null | prtmarc.pl -e"035" -oCFT`;
# Even though a single TCN can (in our catalogue) reference titles each will get updated with oclc number and 
# the appropriate '(Sirsi)' number.
my @selcatalogRecord        = split( '\n', $selcatalogAPIResults );
open( MARC_FLAT, ">$FLAT_MARC_OVERLAY_FILE_NAME" ) or die "Error: unable to write to '$FLAT_MARC_OVERLAY_FILE_NAME': $!\n";
logit( "opening '$FLAT_MARC_OVERLAY_FILE_NAME'" );
foreach my $line ( @selcatalogRecord )
{
	print LOG "$line\n"; # Keep the original for auditing.
	# Each line looks like:
	# cat key| TCN         | 035(1)          | 035(2)         |...| 035(n)           |
	# 728376|a728376       |\a(Sirsi) a728376|\a(CaAE) a728376|...|\a(OCoLC)123390892|
	my ( $catKey, $titleControlNumber, @tag035recordsList ) = split( '\|', $line );
	## Clean the title control number of extra white space for clean key reference.
	$titleControlNumber = trim( $titleControlNumber );
	my $oclcNumber = $oclcNumberHash->{ $titleControlNumber };
	# if we don't find a oclc number just ignore it.
	if ( ! defined $oclcNumber )
	{
		print LOG "*** failed to find '$titleControlNumber' match in report.\n";
		next;
	}
	## Now we need to create the flat MARC file for overlaying on the bib records.
	print MARC_FLAT "*** DOCUMENT BOUNDARY ***\n";
	print MARC_FLAT "FORM=MARC\n";
	print MARC_FLAT ".1003. |a$catKey\n";
	# The first record has to be the '(Sirsi) a<tcn>' number. We add it explicitely instead of relying
	# on any existing value because the .035. field is editable and thus prone to human accidents.
	# We replace it with a fresh new TCN each time.
	print MARC_FLAT ".035.   |a(Sirsi) $titleControlNumber\n";
	print MARC_FLAT ".035.   |a(OCoLC)$oclcNumber\n";
	# We are going to use the -q switch on mergecatalog which will blow away existing .035. records
	# we are going to replace them all here now.
	foreach my $tag035 ( @tag035recordsList ) 
	{
		if ( $tag035 =~ m/\(Sirsi\)/ )
		{
			$recordsWithSirsi035++;
			next; # We already put presine version in MARC.
		}
		if ( $tag035 =~ m/\(OCoLC\)/ )
		{
			$recordsWithOCoLC035++;
			next; # We already put presine version in MARC.
		}
		# Since prtmarc.pl outputs like: # 728376|a728376       |\a(Sirsi) a728376|\a(CaAE) a728376|\a(OCoLC)123390892|
		# remove the initial '\a'
		$tag035 =~ s/^\\a//;
		print MARC_FLAT ".035.   |a$tag035\n";
	}
	$totalBibRecordsModified++;
}
close( MARC_FLAT );
if ( $opt{ 'U' } )
{
	`cat $FLAT_MARC_OVERLAY_FILE_NAME | catalogmerge -aMARC -fd -if -t035 -r -un -bc -q 2>err.log` if ( not -z $FLAT_MARC_OVERLAY_FILE_NAME );
}
# Clean up the Temp TCN file if debug not selected.
unlink( "$TEMP_DIR/tmp_a" ) if ( ! $opt{'d'} );
logit( "\nTotal records reported by OCLC: $tcnCount\n  Records with Sirsi numbers: $recordsWithSirsi035\n  Records with OCLC numbers: $recordsWithOCoLC035\n  Total bib records examined: $totalBibRecordsModified" );
logit( "\n===" );
close( LOG );
# EOF
