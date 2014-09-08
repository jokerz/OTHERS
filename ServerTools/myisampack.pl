#!/usr/bin/perl

# $Id: myisampack.pl,v 1.0 2011/01/06 14:10 RyoIwahase Exp $

#******************************************************
# @desc      run MySQL command "myisampack"
#            this program must be run by root (root user only)
#
# @access    public
# @author    RyoIwahase
# @create    2011/01/06
# @update    
# @version   1.0
#******************************************************

$|=1;
use strict;
use warnings;

use Data::Dumper;

use NKF;

use constant MYSQL_DATADIR_BINARYINSTALL   => '/usr/local/mysql/data';
use constant MYSQL_DATADIR_SOURCEINSTALL   => '/usr/local/mysql/var';
use constant MYSQL_DATADIR_RPMPKGINSTALL   => '/var/lib/mysql';

#*******************************
# 圧縮に必要なmysqlコマンド
#*******************************
my @required_cmd = (
    'myisampack',
    'myisamchk',
    'mysqladmin',
);

#*******************************
# myisamchkのオプション
#*******************************
my @myisamchk_opt = (
    '-rq',
    '--unpack',
);

#*******************************
# コマンド走査結果格納配列
# mysqltools[0] = myisampack
# mysqltools[1] = myisamchk
# mysqltools[2] = mysqladmin
#*******************************
my @mysqltools;

#*******************************
# 入力格納変数
#*******************************
my $INPUT;

#*******************************
# 圧縮/圧縮解除フラグ(DEFAULTは圧縮)
#*******************************
my $FLAG = 0;

#*******************************
# 圧縮対象テーブル
#*******************************
my @TARGET_TABLES;

#*******************************
# データベースユーザーとパスワード
#*******************************
my $DATABASE_USER = "";
my $DATABASE_PASSWORD = "";

#*******************************
# OSの日本語文字コード
#*******************************
open PS, "/bin/echo \$LANG |" or die "$!";
my $PS = <PS>;
close (PS);

my $CHARSET_FLAG = $PS =~ /euc/i ? '-e' : '-w';

# print nkf($CHARSET_FLAG, "");


#**********************************************
# 処理開始
#**********************************************
while (1) {

    print nkf($CHARSET_FLAG, "\nMySQLデータベースのデータ圧縮 / 圧縮解除 を行います。対象は拡張子がMYIのテーブルです。");
    print nkf($CHARSET_FLAG, "\nよろしいですか？ [ Y | N ] : ");

    $INPUT = <STDIN>;
    chomp $INPUT;
    unless ('Y' eq uc($INPUT)) {
        printEndingMessage();
        last;
    }

## step1) MySQLのデータディレクトリ
    print nkf($CHARSET_FLAG, "\nMySQLデータベースのデータディレクトリと必要情報収集を開始します。\n\n") if 'Y' eq uc($INPUT);

    #***********************************************
    # MySQLデータディレクトリのチェック 見つからない場合はundef
    #***********************************************
    my $mysql_datadir =
        ( -d MYSQL_DATADIR_BINARYINSTALL ) ? MYSQL_DATADIR_BINARYINSTALL :
        ( -d MYSQL_DATADIR_SOURCEINSTALL ) ? MYSQL_DATADIR_SOURCEINSTALL :
        ( -d MYSQL_DATADIR_RPMPKGINSTALL ) ? MYSQL_DATADIR_RPMPKGINSTALL :
                                                                   undef ;

    unless (defined($mysql_datadir)) {
        $mysql_datadir = find_mysql_datadir();
        if ('N' eq uc($mysql_datadir)) {
            printEndingMessage();
            last;
        }
    }

## step2) 圧縮コマンドの走査

    &progress;

    print nkf($CHARSET_FLAG, "\n\n==情報収集完了==");
    print nkf($CHARSET_FLAG, "\n\n  ==結果==\n");
    ## 圧縮コマンドの検索結果とMySQLのデータディレクトリを表示
    print nkf($CHARSET_FLAG, sprintf("You have myisampack at : [ %s ]\n", $mysqltools[0]));
    print nkf($CHARSET_FLAG, sprintf("You have myisamchk  at : [ %s ]\n", $mysqltools[1]));
    print nkf($CHARSET_FLAG, sprintf("You have mysqladmin at : [ %s ]\n", $mysqltools[2]));
    print nkf($CHARSET_FLAG, sprintf("Your MySQL DataDir  is : [ %s ]\n", $mysql_datadir));

    # コマンドが3つなければならない
    if ( scalar @required_cmd != map {
        my $grep = $_;
        grep (/$grep/, @mysqltools)
    } @required_cmd ) {
        print nkf($CHARSET_FLAG, "\n\n==FAIL==\n圧縮処理/圧縮解除に必要な全てのコマンドが見つかりません。");
        printEndingMessage();
        sleep 1;
        last;
    }

## step3) データベース名＋テーブル名の取得
    find_database_table($mysql_datadir);

## step4) 圧縮処理実行
    my @result = run_myisam_command();

    create_logfile(\@result);


}


#******************************************************
# @desc     check and confirm target tables
#           圧縮解除する場合はFLAGに1を代入する。
# @return   
#******************************************************
sub find_database_table {
    my $datadir = $_[0];

    print nkf($CHARSET_FLAG, "\n 圧縮を解除する場合は[ U ]を入力してください。");
    $INPUT = <STDIN>;
    chomp $INPUT;
    if ('U' eq uc($INPUT)) {
        $FLAG = 1; # $myisamchk_opt[$FLAG] -> --unpack option is set HERE
    }

    print nkf($CHARSET_FLAG, "\n [ DATABASENAME1.TABLENAME1 DATABASENAME2.TABLENAME2 ] を入力してください。終了する場合は [ N ]");
    $INPUT = <STDIN>;
    chomp $INPUT;
    if ('N' eq uc($INPUT)) {
        printEndingMessage();
        last;
    }

    $INPUT =~ s/\s+/ /g;
    my @database_tables = split(/ /, $INPUT);

    print nkf($CHARSET_FLAG, "\n テーブルが連番の場合は範囲を指定[ 201101..201112 ]、入力してください。終了する場合は [ N ]");

    $INPUT = <STDIN>;
    chomp $INPUT;
    if ('N' eq uc($INPUT)) {
        printEndingMessage();
        last;
    }

    @TARGET_TABLES = map {
                        my $table = $_;
                        $INPUT ?
                               map { sprintf("%s/%s/%s_%s", $datadir, split(/\./, $table), $_) } eval $INPUT
                               :
                               sprintf("%s/%s/%s", $datadir, split(/\./, $table))
                               ;
                     } @database_tables;

}


#******************************************************
# @desc     find mysql data directory
# @param    strings 
# @return   strings
#******************************************************
sub find_mysql_datadir {

    print nkf($CHARSET_FLAG, "\n MySQLのデータディレクトリが見つかりません。ディレクトリパスを入力してください。終了する場合は [ N ]");
    print nkf($CHARSET_FLAG, "\n MySQLディレクトリパス : ");

    my $input = <STDIN>;
    chomp $input;
    return $input if 'N' eq uc($input);

    if (!-d $input) {
        &find_mysql_datadir;
    }

    return $input;
}


#******************************************************
# @desc     myisampack, myisamchk, mysqladminのチェック
# @param    
# @param    
# @return   
#******************************************************
sub progress {
    my @find_things     = (
        '/usr/bin/find / -type f -name myisampack',
        '/usr/bin/find / -type f -name myisamchk',
        '/usr/bin/find / -type f -name mysqladmin',
    );

    my $cnt_find_things = scalar @find_things;

    require Term::ProgressBar;
    my $prog = Term::ProgressBar->new($cnt_find_things);
    my $cnt  = 0;
    foreach my $job (@find_things) {
#        sleep 1;
        $mysqltools[$cnt] = qx/$job/;
        chomp $mysqltools[$cnt];

        my $is_power = 0;
        for( my $i = 0; 2 ** $i <= $cnt; $i++) {
            #$is_power = 1 if 2 ** $i == $cnt;

            if (2 ** $i == $cnt) {
                $is_power = 1;
                $prog->message(sprintf "Found %8d to be 2 ** %2d", $cnt, $i);
            }

        }

        $cnt++;
        $prog->update($cnt);
    }
}


#******************************************************
# @desc     run myisampack and myisamchk and flush mysql tables
# @param    
# @return   
#******************************************************
sub run_myisam_command {

    mysql_user_password();

    my $cnt_target_tables = scalar @TARGET_TABLES;

    require Term::ProgressBar;
    my $prog = Term::ProgressBar->new($cnt_target_tables);
    my $cnt  = 0;
    my @result;

    foreach my $table (@TARGET_TABLES) {
#        sleep 1;
        # below should be modified
        $result[$cnt][0] = qx/$mysqltools[0] $table/ unless 1 == $FLAG;
        $result[$cnt][1] = qx/$mysqltools[1] $myisamchk_opt[$FLAG] $table/;

       ## check if it runs correctly (TEST)
=pod
        $result[$cnt][0] = sprintf("%s %s", $mysqltools[0], $table);
        $result[$cnt][1] = sprintf("%s -q %s", $mysqltools[1], $table);
=cut
        my $is_power = 0;
        for( my $i = 0; 2 ** $i <= $cnt; $i++) {
            $is_power = 1 if 2 ** $i == $cnt;

            if (2 ** $i == $cnt) {
                $is_power = 1;
                $prog->message(sprintf "Found %8d to be 2 ** %2d", $cnt, $i);
            }

        }
        $cnt++;

        #print qx/$mysqltools[2] -u$DATABASE_USER -p$DATABASE_PASSWORD flush-tables/ if $cnt == $cnt_target_tables;
        #if ( $cnt == $cnt_target_tables ) {
        #    $prog->message(sprintf "Now I am going run command : [ %s DATABASEUSER DATABASEPASSWORD flush-tables ] In Order To Flush tables", $mysqltools[2]);
        #    print qx/$mysqltools[2] -u$DATABASE_USER -p$DATABASE_PASSWORD flush-tables/;
        #}

        $prog->update($cnt);
    }

    ## check if it runs correctly (TEST)
    #$result[$cnt][0] =  sprintf("%s -u%s -p%s flush-tables", $mysqltools[2], $DATABASE_USER, $DATABASE_PASSWORD) if $cnt == $cnt_target_tables;
    #print qx/$mysqltools[2] -u$DATABASE_USER -p$DATABASE_PASSWORD flush-tables/;

    print nkf($CHARSET_FLAG, "\nALL Done\nNow I am going Flush tables\n");
    sleep 1;
    print qx/$mysqltools[2] -u$DATABASE_USER -p$DATABASE_PASSWORD flush-tables/;

    return @result;
}


#******************************************************
# @desc     ask database user and password
# @param    
# @return   
#******************************************************
sub mysql_user_password {
    print nkf($CHARSET_FLAG, "\n データベースユーザー名を入力 : ");

    $DATABASE_USER = <STDIN>;
    chomp $DATABASE_USER;

    print nkf($CHARSET_FLAG, "\n データベースユーザーパスワードを入力 : ");

    $DATABASE_PASSWORD = <STDIN>;
    chomp $DATABASE_PASSWORD;
}


#******************************************************
# @desc     writes out what has been done
# @param    
# @return   
#******************************************************
sub create_logfile {
    my $result_data = shift;
    require POSIX;
    POSIX->import(qw(strftime));
    $ENV{'TZ'} = "Japan";
    my $logdatetime = strftime("%Y%m%d%I%M%S", localtime);
    my $tmpfile = sprintf("./myisampack_%s.log", $logdatetime);

    open (FF,">>$tmpfile");
    print FF Dumper($result_data) . "\n";
    close (FF);
}


#******************************************************
# @desc     プログラム終了メッセージの出力
#******************************************************
sub printEndingMessage {
    print nkf($CHARSET_FLAG, "\nプログラムを終了します。\n\n");
}


exit();

__END__
