#!/usr/bin/perl

# $Id: ,v 1.0 2014/07/30 14:50 RyoIwahase Exp $

#******************************************************
# @desc     
#
# @access    public
# @author    RyoIwahase
# @create    2014/07/30
# @update    
# @version   1.0
#******************************************************
$| = 1;
use strict;
use POSIX 'strftime';

use Data::Dumper;

use constant DEBUG_MODE => 0;


my $url    = 'https://ssl.xxx.xxxx.xx.xx/dragonball_kai/dragonball-present.html';
my $time        ||= 60;# one hour
my $interval    ||= 5;

eval {
    local $SIG{ALRM} = sub { die "timeout" };
    alarm $time;
    my $closure;

    $closure = sub {
        my $response_code   = 0 < @_ ? $_[0] : undef;
        my $response        = `curl -LI https://ssl.xxx.xxxx.xx.xx/dragonball_kai/dragonball-present.html -o /dev/null -w '%{http_code}\n' -s`;
        $response != 200 ? send_mail() : sleep $interval;
        printf("status code %s\n", $response);
#        sleep $interval;
        $closure->();
    };

    $closure->();

    alarm 0;
};

if ($@) {
    timeout();
} else {
    ;
}



sub send_mail {
    my $mailfrom        = 'master@web.com';
    my @mailto            = qw(somename@domain.co.jp,eslename@docomo.ne.jp);
    my $send_mail_path    = `which sendmail`;
#my $send_mail_path    = '/usr/sbin/exim4';
    my $mail            = {
        subject     => "Subject: \n",
        from        => "From: \n",
        to          => "To: @mailto\n",
        content     => "Content-Type: text/plain;charset=ISO-2022-JP\n",
        body        => ' status not 200',
    };

    open(OUT,"| $send_mail_path -t -i") or die ( return (0) ); #'ERROR' . "\n";
    
    print OUT $mail->{$_} foreach (qw(subject from to content));
    print OUT "\n";
    print OUT $mail->{body};
    print OUT "\n";
    close(OUT);
    
    sleep 1;

}

sub timeout {
    printf("\n%s\n CONSTANT MODE FINISH\n%s\nTIME OUT AT : %s\n%s\n\n", '='x36, '-'x36, strftime( "%Y-%m-%d %H:%M:%S", localtime ), '='x36);
    exit 0;
}

exit();

__END__
