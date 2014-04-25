#!/usr/bin/perl

# $Id: update_faketime.pl,v 1.0 2014/04/09 14:50 RyoIwahase Exp $

#******************************************************
# @desc     update faketime.txt in certain time 
#
# @access    public
# @author    RyoIwahase
# @create    2014/04/09
# @update    
# @version   1.0
#******************************************************
$| = 1;
use strict;
#use warnings;

use Getopt::Long;# qw(:config posix_default no_ignore_case gnu_compat);
use Pod::Usage;
use POSIX qw(mktime strftime);
#use POSIX::strptime qw(strptime);
use Data::Dumper;

use constant DEBUG_MODE => 0;

use constant USAGE => <<MSG;
	usage : update_faketime [-f] [-i] [-t] [-da] [-dt] [-h]
	options :
	 -f  OR --file		default faketime.txt 
	 -i  OR --interval	default 6second 
	 -t  OR --time		default 12second
	 -da OR --dateadd	default 1day
	 -dt OR --datetime	default now strtime(%Y%m%d %H:%M)
	 -h  OR --help	show this help

	 SAMPLE: update time in faketime to 2012/12/24 adding 1day every 2 seconds for 40 second 
	 update_faketime -f /home/faketime.txt -i 2 --time 40 -da 1 -dt 2012/12/24

MSG

my $help = 0;
my $file;
my $interval;
my $time;
my $dateadd;
my $datetime;

GetOptions (
	"help|?"			=> \$help,
	"f:s{,}"			=> \$file,
	"file:s{,}"			=> \$file,
	"i:s{,}"			=> \$interval,
	"intervval:s{,}"	=> \$interval,
	"t:s{,}"			=> \$time,
	"time:s{,}"			=> \$time,
	"dt:s{,}"			=> \$datetime,
	"datetime:s{,}"		=> \$datetime,
);

die USAGE if $help;

# set default values 
$file		||= 'faketime.txt';
$interval	||= 2;
$time		||= 12;
$dateadd	||= 1;
$datetime	||= strftime( "%Y-%m-%d %H:%M:%S", localtime );

die "File Not found" if !-e $file;

printf("%s\n UPDATE IN CONSTANT MODE\n%s\n", '='x36, '='x36);
printf("File:%s Interval:%dsec TotalTime:%dsec\n%s\n", $file, $interval, $time, '-'x36);
printf("TIME START AT : %s\n%s\n", strftime( "%Y-%m-%d %H:%M:%S", localtime ), '='x36);

eval {
	local $SIG{ALRM} = sub { die "timeout" };
	alarm $time;

	my $ref_function;

	$ref_function = sub {
		my $set_datetime =  0 < @_ ? $_[0] : undef;	

		print_file($file, $set_datetime, $dateadd);
		sleep $interval;

		$ref_function->();
	};
	$ref_function->($datetime);

	alarm 0;
};

if ($@) {
	timeout();	
} else {
	print "AAAA\n";
}


sub timeout {
	printf("\n%s\n CONSTANT MODE FINISH\n%s\nTIME OUT AT : %s\n%s\n\n", '='x36, '-'x36, strftime( "%Y-%m-%d %H:%M:%S", localtime ), '='x36);
	exit 0;
}

sub print_file {
	my $hash = {
					filename	=> shift,
					mode		=> 'rw',
					val			=> shift,
	};
	my $dateadd = shift;

	undef $hash->{val} unless $hash->{val};

	if (DEBUG_MODE) {
		print "UNDEF\n" if !defined $hash->{val};
		print "DEFINED\n" if defined $hash->{val};
		print Dumper($hash);
	}

	my $text = openFileIntoScalar($hash, $dateadd);
	printf("updated : [ %s >>>> %s ]\n", $text->{read_val}, $text->{write_val});
}


sub openFileIntoScalar {
    my $file	= shift;
	my $dateadd = shift;
    return "" if !defined $file->{filename};

    my $rv;

    local $/;
    local *F;
    if ( exists($file->{mode}) and 'rw' eq $file->{mode}) {
		open (F, "< $file->{filename}\0") or die "$!\n";
		$rv->{read_val} = <F>;
		close (F);

		$rv->{read_val} =~ s/,//;

		open (F, "> $file->{filename}\0");

		$rv->{write_val}	= 
			( exists($file->{val}) and defined $file->{val} )
			? $file->{val}
			: dateadd($rv->{read_val}, $dateadd)
			;

		print F $rv->{write_val} . ',';
		close (F);
	} else {
		open (F, "< $file->{filename}\0") || return;
		$rv->{read_val} = <F>;
		close (F);
	}

    return ($rv);
}


sub dateadd {
	my ($date2add, $numbers_of_date) = @_;

	$date2add =~ s!-!/!g;
	$date2add =~ s!,!!g;

	my $date2sec = strftime2unixtime($date2add);
	my $sec2date = sec2date(($date2sec + (60 * 60 * 24 * $numbers_of_date)));

	return($sec2date);
}


sub sec2date {
	my $second = shift || return;
	my ($sec, $min, $hour, $mday, $month, $year) = localtime($second);

	return (sprintf("%d/%d/%d %02d:%02d", ($year + 1900), ($month + 1), $mday, $hour, $min));
}


#*****************************************
# @desc		change date time to unixtime
# @arg		time
#*****************************************
sub strftime2unixtime {
	my $strftime	= shift;

	if (DEBUG_MODE) {
		use Carp;
		use Data::Dumper;
		croak(Dumper($strftime)) unless $strftime;
	}

	my ($ymd, $hms) = split(/ /, $strftime);
	my ($Y, $m, $d) = 
			$ymd =~ /-/  ? split(/-/, $ymd)  :
			$ymd =~ /\// ? split(/\//, $ymd) :
										undef;	
	
	my ($H, $M, $S) = $hms =~ /:/ ? split(/:/, $hms) : undef;

	return (mktime($S, $M, $H, $d, ($m - 1), ($Y - 1900), 0, 0));
}

__END__
