#******************************************************
# @desc		194964SNS日記API基底クラス
# @package	SNS
# @access	public
# @author	Iwahase Ryo
# @create	2012/11/30
# @version	1.00
# @update
#******************************************************
package SNS;

our $VERSION = '1.00';

use strict;
use warnings;
no warnings 'redefine';

use CoreBasic;
use GenerateXML;
use classMasterDataAccess;
use classDBAccess;
use classDBAccess::Plus;
use SNS::Util qw(create_hash cipher serialize_object);
use MyPage::Image::Method; # get image url for sns diary
use Emoji;

#******************************************************
# @access   public
# @desc		コンストラクタ
# @param
# @return
#******************************************************
sub new {
    my ( $class, $cfg ) = @_;
    my $self = {};
    bless( $self, $class );

    map { $self->{$_} = $cfg->{$_} } keys %{$cfg};

    $self->{dbhFTSR}    = classDBAccess::Plus->new(); # DBServerSNSDiaryFullTextSearch
    $self->{dbhR}       = classDBAccess::Plus->new();
    $self->{dbhW}       = classDBAccess::Plus->new();
    $self->{dbhImageR}  = classDBAccess::Plus->new();
    $self->{dbhImageW}  = classDBAccess::Plus->new();
    $self->{dbhFTSR}->connect( 'DBServerSNSDiaryFullTextSearch', 'READ' );
    $self->{dbhR}->connect( 'DBServerSNSDiary', 'READ' );
    $self->{dbhW}->connect( 'DBServerSNSDiary', 'WRITE' );
    $self->{dbhImageR}->connect( 'DBServerIMG', 'READ' );
    $self->{dbhImageW}->connect( 'DBServerIMG', 'WRITE' );

    $self->{appid}  = $cfg->{cgi}->param('appid');# appid
    $self->{sid}    = $self->{cgi}->param('sid');# sid
    #$self->{sid}    = $self->cgi->param('sid');# sid

    return ($self);
}

#******************************************************
# @desc	  必須パラメータチェック
#			sid, appid
# @return	int / undef	c_member_id
#******************************************************
sub run {
    my $self = shift;
    my $err_response_code;

    return 'HTTP_CUSTOM_REPONSE_CODE_9012' unless $self->{sid};

    my $resData         = CoreBasic::checkBasicParamValid( $self->appid, $self->{sid} );
    $err_response_code  = ( 0 < $resData->{code} ) ? sprintf("HTTP_CUSTOM_REPONSE_CODE_%d", $resData->{code}) : undef;

    $self->check_device;

    return ( defined ($err_response_code) ? $err_response_code : undef );
}

#******************************************************
# @desc	 	Create Accessors
# @desc		：
#            self_data
#            sns_member_data
#            sid
#            appid
#            cfg
#            cgi
#            sns_memcached
#            db
#******************************************************
for my $name (qw/self_data sns_member_data sid appid cfg cgi sns_memcached sns_memcached_write db/)
{
    no strict 'refs';
    *{$name} = sub {
        return shift->{$name};
    }
}

#******************************************************
# @access   private
# @desc	 	会員の基本情報をデータベースから取得
# @param	int memNo
# @return   hash object
#******************************************************
sub __base_member_data_by_memno {
	my ( $self, $memno, $areaid ) = @_;
	return if !$memno;

    my $obj;
    my $c_member_table      = $self->cfg->param('SNS_MYSQL_TABLE_MEMBER');
    my $ikuyo_profile_table = $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_PROFILE');

    my $sql = sprintf(
        "SELECT
        M.ikuyo_area_id         AS areaid,
        M.ikuyo_memno           AS memno,
        M.c_member_id           AS sns_member_id,
        M.nickname              AS name,
        M.ikuyo_area_code       AS pref_code,
        M.is_receive_ktai_mail  AS receipt_mail_flag,
        IK.gender               AS sex,
        IK.age                  AS age,
        IK.play_city            AS playCity
        FROM %s IK LEFT JOIN %s M
        ON IK.c_member_id = M.c_member_id
        ", $ikuyo_profile_table, $c_member_table
    );

    $self->dbhR->setEncodeFrom('utf8');
    $self->dbhR->setEncodeTo('utf8');

    if (
        $obj = $self->dbhR->executeReadPlus(
            'DBServerSNSDiary',
            'stage194master',
            $c_member_table,
            $areaid, $memno, $sql, undef,
            {
                whereSQL    => "M.ikuyo_memno= ? AND M.ikuyo_area_id = ?",
                #placeholder => [$memno],
                #whereSQL	=> "IK.ikuyo_profile_id = ? AND IK.ikuyo_area_id = ?",
                placeholder => [ $memno, $areaid ],
            },
        )
      )
    {
        return $obj;
    }
    return undef;
}

#******************************************************
# @desc	  日記IDからc_member_idを取得
#
# @param	int	c_diary_id
# @return	int / undef	c_member_id
#******************************************************
sub c_memberid_of_diary {
    my ( $self, $target_diary_id ) = @_;
    return undef if !$target_diary_id;

    return (
        $self->dbhR->executeReadPlus_with_row_or_col(
            {
                dbi_method  => 'row',
                condition   => {
                    table       => $self->CONFIGURATION_VALUE("SNS_MYSQL_TABLE_DIARY"),
                    column      => 'c_member_id',
                    whereSQL    => 'c_diary_id = ?',
                    placeholder => [$target_diary_id],
                }
            }
        )
    );
}

#******************************************************
# @desc	 sidをキーにmemecachedから会員基本情報を取得する
# @desc	 cacheがない場合はikuyo_memnoをキーをc_meber テーブルからデータを取得
# @desc	 データへのアクセスは self_dataメソッドからアクセス
#
# @param	int memNo
# @return   hash object { }
#		   areaId エリア番号
#		   memNo  共通会員番号
#		   name   ニックネーム
#		   prefCode
#		   bbsMemberId 会員番号(BBS)
#		   snsMemberId 会員番号(SNS)
#		   reMemberId  会員番号(re_ikuyo)
#		   point
#		   receiptMailFlag メール受信フラグ
#		   mushi			 無視リスト更新時間
#		   bbsBlack		  掲示板ブラックリスト更新時間
#******************************************************
sub set_self_data_by_sid {
    my $self    = shift;
    my $sid     = $self->sid();
    my $memno   = $self->cgi->param('memNo')  || shift;
    my $areaid  = $self->cgi->param('areaId') || 99;

    my ($result, $obj) = CoreBasic::getMemberData($sid);
    if ( 'NG' eq $result->{value} or 'ON' eq $obj->{maintenance} ) {
        my $status_code = sprintf("HTTP_CUSTOM_REPONSE_CODE_%d",
                                ( 'NG' eq $result->{value} ? $result->{status} : 'ON' eq $obj->{maintenance} ? 9004 : 9999 )
                          );
        $self->error_response($status_code);
        return;# 'HTTP_CUSTOM_REPONSE_CODE_9014';
    }

    my $api_parameter_name = {
        areaid              => 'areaId',
        memno               => 'memNo',
        name                => 'name',
        pref_code           => 'prefCode',
        bbs_member_id       => 'bbMemberId',
        sns_member_id       => 'snsMemberId',
        re_member_id        => 'reMemberId',
        dmm_id              => 'dmmId',
        point               => 'point',
        point_g             => 'piontG',
        age                 => 'age',
        sex                 => 'sex',
        style               => 'style',
        receipt_mail_flag   => 'receiptMailFlag',
        mushi               => 'mushi',
        bbsblack            => 'bbsBlack',
    };

    map {
        exists( $api_parameter_name->{$_} ) ? $self->{self_data}->{ $api_parameter_name->{$_} } = $obj->{$_} : $self->{self_data}->{$_} = $obj->{$_}
    } keys %{ $obj };

    if ( $self->cfg->param('DEBUG_MODE') ) {
        $obj->{__DEBUG__SelfDataFromMemcached} =
          ( defined( $obj->{__DEBUG__SelfDataNotFromMemcached} ) && 1 == $obj->{__DEBUG__SelfDataNotFromMemcached} ) ? 0 : 1;
        $obj->{__DEBUG__SelfDataNotFromMemcached} =
          !exists( $obj->{__DEBUG__SelfDataNotFromMemcached} )
          && 1 == $obj->{__DEBUG__SelfDataFromMemcached}
          ? 0
          : $obj->{__DEBUG__SelfDataNotFromMemcached};
        serialize_object(
            {
                file =>
                  sprintf( "%s/SNS/tmp/%s.obj", $self->cfg->param('ST_IKUYO_COREAPI_CORE_DIR'), $self->sid() ),
                obj => $obj
            }
        );
    }

    serialize_object(
        {
            file =>
              sprintf( "%s/SNS/tmp/%s.obj", $self->cfg->param('ST_IKUYO_COREAPI_CORE_DIR'), $self->sid() ),
            obj => $obj
        }
    ) if $self->cfg->param('DO_SERIALIZE') && !$self->cfg->param('DEBUG_MODE');

    return $self;
}

#******************************************************
# @desc		SNS独自処理
# @desc	 memnoをキーにmemecachedから会員基本情報を取得する
# @desc	 cacheがない場合はikuyo_memnoをキーをc_meber テーブルからデータを取得
#
# @desc	 データへのアクセスは self_dataメソッドからアクセス
# @param	int memno
# @return   hash object { }
#		   areaid エリア番号
#		   memno  共通会員番号
#		   name   ニックネーム
#		   pref_code
#		   bbs_member_id 会員番号(BBS)
#		   sns_member_id 会員番号(SNS)
#		   re_member_id  会員番号(re_ikuyo)
#		   point
#		   receipt_mail_flag メール受信フラグ
#		   mushi			 無視リスト更新時間
#		   bbsblack		  掲示板ブラックリスト更新時間
#******************************************************
sub sns_member_data_by_memno {
    my $self = shift;

    return unless @_;

    my $target_memno   = shift;
    my $target_area_id = shift;
    my $memcached_key  = sprintf( "%s%d", $self->cfg->param('MEMCACHED_KEY4_SNS_MEMBER_DATA'), $target_memno );

    my $obj = $self->sns_memcached->get($memcached_key);

    if ( !$obj ) {
        return if !$target_memno; # キャッシュがなくてmemnoが無い場合は会員情報を取得できない。

        if (
            $obj = $self->__base_member_data_by_memno(
                $target_memno, $target_area_id
            )
          )
        {
            #$self->sns_memcached->add( $memcached_key, $obj, 360 );
            $self->sns_memcached_write->add( $memcached_key, $obj, 360 );
            $obj->[0]->{__DEBUG__SNSMemberDataNotFromMemcached} = 1 if $self->cfg->param('DEBUG_MODE');
            $obj->[0]->{SNSMemberDataFromCache} = 0;
        }
        else { return $self->custom_error('HTTP_CUSTOM_REPONSE_CODE_9015'); }
    }

    $obj->[0]->{SNSMemberDataMemcachedKey} = $memcached_key;

    if ( $self->cfg->param('DEBUG_MODE') ) {
        $obj->[0]->{__DEBUG__SNSMemberDataFromMemcached} = $obj->[0]->{__DEBUG__SNSMemberDataNotFromMemcached} && 1 == $obj->[0]->{__DEBUG__SNSMemberDataNotFromMemcached} ? 0 : 1;
        $obj->[0]->{__DEBUG__SNSMemberDataNotFromMemcached} =
          !exists( $obj->[0]->{__DEBUG__SSNSMemberDataNotFromMemcached} )
          && 1 == $obj->[0]->{__DEBUG__SNSMemberDataFromMemcached}
          ? 0
          : $obj->[0]->{__DEBUG__SNSMemberDataNotFromMemcached};
    }

    map { $self->{sns_member_data}->{$_} = $obj->[0]->{$_} } keys %{ $obj->[0] };

    return $self;
}


#******************************************************
# @desc     check if friend each other by c_member_id
# @param    
# @param    
# @return   
#******************************************************
sub is_friend {
    my ( $self, $target_c_member_id ) = @_;

    my $c_member_id = $self->self_data->{snsMemberId};
    my $sql         = sprintf("SELECT 1 FROM %s WHERE (c_member_id_from = ? AND c_member_id_to = ?) OR (c_member_id_from = ? AND c_member_id_to = ?)", $self->cfg->param('SNS_MYSQL_TABLE_FRIEND'));

    !$self->dbhR->{DBHandle}->selectrow_array($sql, undef, $c_member_id, $target_c_member_id, $target_c_member_id, $c_member_id) ? $self->error_response('SNS_CODE_3006') : return;

}


#******************************************************
# @desc     自分がむしされているか
# @param    target_c_member_id
# @param    SQLのtarget_c_member_id=<自分のc_member_id> c_member_id=<target_c_member_id>
# @return   
#******************************************************
sub is_ignored {
    my ( $self, $target_c_member_id ) = @_;

    my $c_member_id = $self->self_data->{snsMemberId};
    my $sql         = sprintf("SELECT 1 FROM %s WHERE target_c_member_id = ? AND c_member_id = ?;", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
    return $self->dbhR->{DBHandle}->selectrow_array($sql, undef, $c_member_id, $target_c_member_id);
}

#******************************************************
# @desc     self->diary_list({})
# @param    Hash { whereSQL => '', placeholder => [], limit => base_limit => [depends]}
# @param    scalar diaryId2Next
#******************************************************
sub diary_list {
    my ( $self, $whereSQL_placeholder, $last_diary_id ) = @_;

    my $retlist;
    my $ref_function;

    my $c_member_id     = $self->self_data->{snsMemberId};
    my $limit           = $whereSQL_placeholder->{base_limit};
    my $max             = $whereSQL_placeholder->{limit} - 1;
    my $max_condition   = $whereSQL_placeholder->{limit};
    my $maxrec          = 0;
    my $counter         = 0;
    my $sql_ignore;
    my $retobj;
    my $diaryId2Next;
    my $sql_total_record        = sprintf("SELECT COUNT(c_diary_id) FROM %s;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'));
    my $total_record            = $self->dbhR->{DBHandle}->selectrow_array($sql_total_record);
    ## 開始すべき日記の日付
    my $sql_date_to_begin       = sprintf("SELECT u_datetime FROM %s WHERE c_diary_id = ?;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'));


#    $sql_ignore                 = sprintf("SELECT target_c_member_id AS my_ignore_c_member_id FROM %s WHERE c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
#    $retobj->{ignore_list}      = $self->dbhR->{DBHandle}->selectcol_arrayref($sql_ignore, undef, $c_member_id);
#    $sql_ignore                 = sprintf("SELECT c_member_id AS your_ignore_c_member_id FROM %s WHERE target_c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
#    $retobj->{ignore_from_list} = $self->dbhR->{DBHandle}->selectcol_arrayref($sql_ignore, undef, $c_member_id);
#
    ## 無視してる、されてる会員のリスト
#    my $ignore_from;
    #map { $ignore_from->{$_} = 1; } @{ $retobj->{ignore_list} };
#    map { $ignore_from->{$_} = 1; } @{ $retobj->{ignore_from_list} };

    $sql_ignore = sprintf("SELECT CASE
 WHEN target_c_member_id = ? THEN c_member_id
 WHEN c_member_id = ? THEN target_c_member_id
 ELSE 0
 END AS ignore_c_member_id
 FROM %s
 WHERE target_c_member_id= ? OR c_member_id= ?",$self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));

    $retobj->{ignore_list}      = $self->dbhR->{DBHandle}->selectcol_arrayref($sql_ignore, undef, $c_member_id, $c_member_id, $c_member_id, $c_member_id );

    ## 無視してる、されてる会員のリスト
    my $ignore_from;
    map { $ignore_from->{$_} = 1; } @{ $retobj->{ignore_list} };


    $ref_function = sub {

        my $diary_id_to_begin   = shift || $last_diary_id;

    ## Modified 2013/10/09 diary list must be sort by u_datetime
        #my $whereSQL            = 0 < $diary_id_to_begin ? sprintf("WHERE c_diary_id < %d ",$diary_id_to_begin) : '';
        #my $sql_ids = sprintf("SELECT c_diary_id, c_member_id FROM %s %s ORDER BY c_diary_id DESC LIMIT %d;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'), $whereSQL, $limit);

        my $diary_u_datetime_to_begin   = $self->dbhR->{DBHandle}->selectrow_array($sql_date_to_begin, undef, $diary_id_to_begin);
        my $whereSQL                    = 0 < $diary_id_to_begin ? sprintf("WHERE u_datetime < '%s' ", $diary_u_datetime_to_begin) : '';
        my $sql_ids                     = sprintf("SELECT c_diary_id, c_member_id FROM %s %s ORDER BY u_datetime DESC LIMIT %d;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'), $whereSQL, $limit);
        my $aryref                      = $self->dbhR->{DBHandle}->selectall_arrayref( $sql_ids, { Columns => {} } );

        # exit if no record
        return if 1 > scalar @{ $aryref } or !defined $aryref;

        my @diaryIds;
        my @ignoreDiaryIds; #デバッグ用にとりあえず
        map {
            push (@diaryIds, $aryref->[$_]->{c_diary_id}) if  !$ignore_from->{$aryref->[$_]->{c_member_id}}; 
            #push (@ignoreDiaryIds, $aryref->[$_]->{c_diary_id}) if  $ignore_from->{$aryref->[$_]->{c_member_id}};  #デバッグ用にとりあえず
        } 0..$#{ $aryref };

        my $sql_base = $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 });

        my $sql = sprintf("%s WHERE D.c_diary_id IN(%s) AND (D.is_suspend = 0 AND M.is_suspend = 0)", $sql_base, join(',', @diaryIds));
        $sql .= ' AND ' . $whereSQL_placeholder->{whereSQL} if '' ne $whereSQL_placeholder->{whereSQL};
    ## Modified 2013/10/09 diary list must be sort by u_datetime
        #$sql .= sprintf(" ORDER BY D.c_diary_id DESC LIMIT %d;", $max_condition);
        $sql .= sprintf(" ORDER BY D.u_datetime DESC LIMIT %d;", $max_condition);

        $aryref         = $self->dbhR->{DBHandle}->selectall_arrayref($sql, { Columns => {} }, @{ $whereSQL_placeholder->{placeholder} });
        $diaryId2Next   = $max <  scalar @{ $aryref } ? $aryref->[-1]->{diaryId} : $diaryIds[-1];

        if ( 0 == $maxrec ) {
            $maxrec = scalar @{ $aryref };
            $retlist->{SNSDiaryList} = $aryref;
        }
        else {
            $maxrec = scalar @{ $retlist->{SNSDiaryList} };
            if ( $max > $maxrec ) {
                my $addcount = $max - $maxrec;
                map { push(@{ $retlist->{SNSDiaryList} }, $aryref->[$_]) } 0..( scalar @{ $aryref } > $addcount ? $addcount : $#{ $aryref } );
                $maxrec = scalar @{ $retlist->{SNSDiaryList} };
            }
        }

        $counter++;

        if ( $max_condition == scalar @{ $retlist->{SNSDiaryList} } ) {
            $retlist->{diaryId2Next} = $diaryId2Next;
        }
        elsif ( $max_condition > scalar @{ $retlist->{SNSDiaryList} } ) {
            if ( $total_record > ($counter * $limit ) ) {
                $ref_function->($diaryId2Next)
            }
        }

    };

    $ref_function->();

    return $retlist;

=pod
    my ( $self, $whereSQL_placeholder ) = @_;

    my $retlist;
    my $ref_function;

        my $c_member_id = $self->self_data->{snsMemberId};
        my $limit       = 100;
        my $max         = $whereSQL_placeholder->{limit};
        my $maxrec      = 0;
        my $sql_ignore;
        my $retobj;
        my $diaryId2Next;

        $sql_ignore                 = sprintf("SELECT target_c_member_id AS my_ignore_c_member_id FROM %s WHERE c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
        $retobj->{ignore_list}      = $self->dbhR->{DBHandle}->selectcol_arrayref($sql_ignore, undef, $c_member_id);
        $sql_ignore                 = sprintf("SELECT c_member_id AS your_ignore_c_member_id FROM %s WHERE target_c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
        $retobj->{ignore_from_list} = $self->dbhR->{DBHandle}->selectcol_arrayref($sql_ignore, undef, $c_member_id);

        ## 無視されてる会員のリスト
        my $ignore_from;
        map { $ignore_from->{$_} = 1; } @{ $retobj->{ignore_from_list} };

        $ref_function = sub {
            my $diary_id_to_begin   = shift || 0;
            my $whereSQL            = 0 < $diary_id_to_begin ? sprintf("WHERE c_diary_id < %d ",$diary_id_to_begin) : '';
            my $sql;

            $sql = sprintf("SELECT c_diary_id, c_member_id FROM %s %s ORDER BY c_diary_id DESC LIMIT %d;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'), $whereSQL, $limit);

            my $aryref = $self->dbhR->{DBHandle}->selectall_arrayref( $sql, { Columns => {} } );

            my @diaryIds;
            my @ignoreDiaryIds; #デバッグ用にとりあえず
            map {
                push (@diaryIds, $aryref->[$_]->{c_diary_id}) if  !$ignore_from->{$aryref->[$_]->{c_member_id}}; 
                push (@ignoreDiaryIds, $aryref->[$_]->{c_diary_id}) if  $ignore_from->{$aryref->[$_]->{c_member_id}};  #デバッグ用にとりあえず
            } 0..$#{ $aryref };

            my $sql_base = $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 });

            $sql = sprintf("%s WHERE D.c_diary_id IN(%s) AND (D.is_suspend = 0 AND M.is_suspend = 0)", $sql_base, join(',', @diaryIds));
            $sql .= ' AND ' . $whereSQL_placeholder->{whereSQL} if '' ne $whereSQL_placeholder->{whereSQL};
            $sql .= sprintf(" ORDER BY D.c_diary_id DESC LIMIT %d;", $max);

            $aryref = $self->dbhR->{DBHandle}->selectall_arrayref($sql, { Columns => {} }, @{ $whereSQL_placeholder->{placeholder} });

#            $diaryId2Next = scalar @{ $aryref } > $max ? $aryref->[$max - 1] : $aryref->[-1]->{diaryId};
            $diaryId2Next = $aryref->[-1]->{diaryId};
            if ( 0 == $maxrec ) {
                $maxrec = scalar @{ $aryref };
                $retlist = $aryref;
            }
            elsif ( $max > $maxrec ) {
                my $addcount = $max - $maxrec;

                map { push(@{ $retlist }, $aryref->[$_]) } 0..($addcount - 1);
                $maxrec = scalar @{ $retlist };
            }
#            $diaryId2Next = $retlist->[-1]->{diaryId};
            $ref_function->($diaryId2Next) if $max > $maxrec;
        };
    
    $ref_function->();
 
    return $retlist;
=cut
}

#******************************************************
# @access   public
# @desc     check device
#******************************************************
sub check_device {
    my $self = shift;

    $self->cfg->param('ANDROID_APPID') eq $self->appid  ? $self->{is_Android}   = 1:
    $self->cfg->param('IOS_APPID') eq $self->appid      ? $self->{is_iOS}       = 1:
    return;
}

#******************************************************
# @access   public
# @desc     type of device
#******************************************************
sub is_Android {
    return shift->{is_Android};
}

#******************************************************
# @access   public
# @desc     type of device
#******************************************************
sub is_iOS {
    return shift->{is_iOS};
}

#******************************************************
# @desc     get your own ignore list and ignored by other
# @param   if any value is sent make list from both you and target
# @param    
# @return   hash { ignore_list =>[], ignore_from_list => [] }
#******************************************************
sub ignore_list {
    my $self = shift;
    my $all  = shift;

    my $sql;
    my $retobj;
    my $c_member_id = $self->self_data->{snsMemberId};

    if ($all) {
        $sql = sprintf("SELECT CASE
 WHEN target_c_member_id = ? THEN c_member_id
  WHEN c_member_id = ? THEN target_c_member_id
   ELSE 0
   END AS ignore_c_member_id
  FROM %s
  WHERE target_c_member_id= ? OR c_member_id= ?",$self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));

        $retobj->{ignore_list}  = $self->dbhR->{DBHandle}->selectcol_arrayref($sql, undef, $c_member_id, $c_member_id, $c_member_id, $c_member_id );
    }
    else {
        $sql                        = sprintf("SELECT target_c_member_id AS my_ignore_c_member_id FROM %s WHERE c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
        $retobj->{ignore_list}      = $self->dbhR->{DBHandle}->selectcol_arrayref($sql, undef, $c_member_id);
        $sql                        = sprintf("SELECT c_member_id AS your_ignore_c_member_id FROM %s WHERE target_c_member_id = ?", $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_IGNORE'));
        $retobj->{ignore_from_list} = $self->dbhR->{DBHandle}->selectcol_arrayref($sql, undef, $c_member_id);
    }
    return $retobj;
}

#******************************************************
# @access   public
# @desc	 just build the begining of base sql for diary/diary list
# @update 2013/09/20 add param
# @update 2013/10/04 add columns to get openAreasAsCode (0+public_flag) stings to integer 
# @param  hash { NO194PROFILE => 1 } param NO194PROFILE SQL will be created without JOINING ikuyo_profile
# @update 2013/10/05  add extra arg to create SQL
# @param  hash { NOBODYNO194PROFILE => 1 } param NOBODYNO194PROFILE SQL will be created without  c_diary.body and JOINING ikuyo_profile
# @return   text sql
#******************************************************
sub build_base_diary_SQL {
	#my $self = shift;
    my ( $self, $hashobj ) = @_;

    my $c_member_table          = $self->cfg->param('SNS_MYSQL_TABLE_MEMBER');
    my $c_diary_table           = $self->cfg->param('SNS_MYSQL_TABLE_DIARY');
    my $c_diary_comment_table   = $self->cfg->param('SNS_MYSQL_TABLE_DIARY_COMMENT');
    my $ikuyo_profile_table     = $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_PROFILE');

    # Build base SQL for both Diary and Diary list
    my $sql = 
        exists( $hashobj->{NO194PROFILE} )
        ?
        sprintf("SELECT
 M.nickname          AS targetName
, M.ikuyo_area_id    AS targetAreaId
, M.ikuyo_memno      AS targetMemNo
, M.ikuyo_area_code  AS targetPrefCode
, M.is_age_verified  AS isAgeVerified
, D.c_member_id      AS snsMemberId
, D.c_diary_id       AS diaryId
, D.subject          AS diaryTitle
, D.body             AS diary
, D.category         AS adultFlag
, D.pv_count         AS pageViewCount
, D.r_datetime       AS createdDateTime
, D.r_date           AS createdDate
, D.image_filename_1 AS imageFileName1
, D.image_filename_2 AS imageFileName2
, D.image_filename_3 AS imageFileName3
, D.is_checked       AS isChecked
, D.public_flag      AS openAreas
, (0+D.public_flag)  AS openAreasAsCode
, D.comment_settings AS commentAllowed
, D.is_enable_trial  AS isEnableTrial
, D.u_datetime       AS upDatedTime
, D.is_suspend       AS isSuspend
  FROM %s D 
    LEFT JOIN %s M ON M.c_member_id = D.c_member_id", $c_diary_table, $c_member_table)
        :
        exists( $hashobj->{NOBODYNO194PROFILE} )
        ?
        sprintf("SELECT
 M.nickname          AS targetName
, M.ikuyo_area_id    AS targetAreaId
, M.ikuyo_memno      AS targetMemNo
, M.ikuyo_area_code  AS targetPrefCode
, M.is_age_verified  AS isAgeVerified
, D.c_member_id      AS snsMemberId
, D.c_diary_id       AS diaryId
, D.subject          AS diaryTitle
, D.pv_count         AS pageViewCount
, D.r_datetime       AS createdDateTime
, D.r_date           AS createdDate
, D.image_filename_1 AS imageFileName1
, D.image_filename_2 AS imageFileName2
, D.image_filename_3 AS imageFileName3
, D.is_checked       AS isChecked
, D.public_flag      AS openAreas
, (0+D.public_flag)  AS openAreasAsCode
, D.u_datetime       AS upDatedTime
, D.is_suspend       AS isSuspend
  FROM %s D 
    LEFT JOIN %s M ON M.c_member_id = D.c_member_id", $c_diary_table, $c_member_table)
    :
    sprintf(
        "SELECT
 M.nickname          AS targetName
, M.ikuyo_area_id    AS targetAreaId
, M.ikuyo_memno      AS targetMemNo
, M.ikuyo_area_code  AS targetPrefCode
, M.is_age_verified  AS isAgeVerified
, IK.gender          AS targetSex
, IK.age             AS targetAge
, IK.play_city       AS targetPlayCity
, D.c_member_id      AS snsMemberId
, D.c_diary_id       AS diaryId
, D.subject          AS diaryTitle
, D.body             AS diary
, D.category         AS adultFlag
, D.pv_count         AS pageViewCount
, D.r_datetime       AS createdDateTime
, D.r_date           AS createdDate
, D.image_filename_1 AS imageFileName1
, D.image_filename_2 AS imageFileName2
, D.image_filename_3 AS imageFileName3
, D.is_checked       AS isChecked
, D.public_flag      AS openAreas
, (0+D.public_flag)  AS openAreasAsCode
, D.comment_settings AS commentAllowed
, D.is_enable_trial  AS isEnableTrial
, D.u_datetime       AS upDatedTime
, D.is_suspend       AS isSuspend
  FROM %s D 
    LEFT JOIN %s M ON M.c_member_id = D.c_member_id
        LEFT JOIN (
            SELECT
             c_member_id
            ,gender
            ,age
            ,play_city
                FROM %s ) AS IK
            ON (M.c_member_id = IK.c_member_id)", $c_diary_table,
       $c_member_table, $ikuyo_profile_table )
    ;

    return $sql;
}

#******************************************************
# @desc     get image id from filename
# @param    arrayref  filenames
# @param    
# @return   
#******************************************************
sub fetch_image_id_from_filename {
    my ($self, $param) = @_;

    my $image_table = $self->CONFIGURATION_VALUE("SNS_MYSQL_TABLE_IMAGE");

    my $sql = sprintf("SELECT c_image_id FROM %s WHERE filename IN (?%s)", $image_table, ',?' x $#{ $param });

    my $aryref = $self->dbhR->{DBHandle}->selectcol_arrayref($sql, undef, @{ $param });

    return ($aryref);
}

#******************************************************
# @desc	 会員のアイコンデータを取得します。
# @param
#			sessiondata
#			memno
#			areaid
#			distanceOff
# @param
# @return
#******************************************************
sub fetch_member_icon_data {
	my ( $self, $param ) = @_;

	unless ($param) {
		return;
	}

	my $obj = CoreBasic::getIconData(
		$param->{sessiondata}, $param->{memno},
		$param->{areaid},	  $param->{distanceOff}
	);

	return $obj;
}

sub fetch_member_icon_data_distance {
	my ( $self, $param ) = @_;

	my $obj = CoreBasic::getIconDataAndDistance(
				$param->{sessiondata},
				$param->{memno},
				$param->{areaid},
				$param->{distanceOff},
				$self->dbhReIkuyoR,
				$self->dbhR,
				$self->dbhIkuyoBbsR,
				$self->dbhGeoR
			);
	return $obj;
}

#******************************************************
# @access   public
# @desc     go get image urls for sns diary if images are posted by diary_id
# @param    hash   
#					{
#						member_data => {
#									    	memno =>  1260919,
#									    	areaid => 15,
#									    	sns_member_id => 7400,
#									    },
#						type		=> 3,						# type for 1->プロフ,2->写メ,3->日記
#						id_for_type	=> $diaryId,				# id for the type above
#						flag		=> 0,						# 0/1 0 for all 1 for selected image
#					}
#
#
# @return   arrayref   [ { image_url, mosaic_url, selected_flg } ] image url
#******************************************************
sub get_getImageUrl {
	my ( $self, $hashobj ) = @_;

	$hashobj->{type} ||= 3; # set default value to 3 (SNS)
	$hashobj->{flag} ||= 0; # set default value to 0 (get all)
	$hashobj->{size} ||= 1; # set default value to 1 (get all)
	my @retobj = MyPage::Image::Method->new->getImageUrl( $hashobj->{member_data}, $hashobj->{type}, $hashobj->{id_for_type}, $hashobj->{flag}, $hashobj->{size} );

	return (\@retobj);
}

#******************************************************
# @access   public
# @desc     delete image posted for diary by diary_id
# @param    hash   
#					{
#						member_data			=> {
#												memno =>  1260919,
#												areaid => 15,
#												sns_member_id => 7400,
#												sns_member_id => 7400,
#										    },
#						id_for_type			=> $diaryId,				# id for the type above
#						image_file_number	=> 1-3,						# 1-3 the end of number columname image_filename 1-3
#					}
# @return   boolean  1 on success
#******************************************************
sub remove_delDiaryPicture {
	my ( $self, $hashobj ) = @_;

	return (MyPage::Image::Method->new->delDiaryPicture( $hashobj->{member_data}, $hashobj->{id_for_type}, $hashobj->{image_file_number} ) );
}

#******************************************************
# {
#    memno               => $memno
#    areaid              => $area_id
#    sns_member_id       => $sns_member_id,
#    image_file_names    => {
#                            imageFileName1  => $imageFileName1,
#                            imageFileName2  => $imageFileName2,
#                            imageFileName3  => $imageFileName3,
#                       }
#    image_file_name_is_suspend  => {
#                imageFileName1IsSuspend => $imageFileName1IsSuspend,
#                imageFileName2IsSuspend => $imageFileName2IsSuspend,
#                imageFileName3IsSuspend => $imageFileName3IsSuspend,
#    }
# }
# 
# 
#******************************************************
sub get_getSuspendOfDiaryImageFile {
    my ( $self, $hashobj ) = @_;

    my $objImage = MyPage::Image::Method->new();

#    my $ret = {
#        memno           => $hashobj->{memno},
#        areaid          => $hashobj->{areaid},
#        sns_member_id   => $hashobj->{sns_member_id},
#    };

    my $ret = {
        imageFileName1IsSuspend => exists $hashobj->{imageFileName1} ? $objImage->getSuspendOfDiaryImageFile(
            {
                memno           => $hashobj->{memno},
                areaid          => $hashobj->{areaid},
                sns_member_id   => $hashobj->{sns_member_id}
            }, $hashobj->{imageFileName1} ) : '',
        imageFileName2IsSuspend => exists $hashobj->{imageFileName1} ? $objImage->getSuspendOfDiaryImageFile(
            {
                memno           => $hashobj->{memno},
                areaid          => $hashobj->{areaid},
                sns_member_id   => $hashobj->{sns_member_id}
            }, $hashobj->{imageFileName2} ) : '',
        imageFileName3IsSuspend => exists $hashobj->{imageFileName1} ? $objImage->getSuspendOfDiaryImageFile(
            {
                memno           => $hashobj->{memno},
                areaid          => $hashobj->{areaid},
                sns_member_id   => $hashobj->{sns_member_id}
            }, $hashobj->{imageFileName3} ) : '',
    };
    return $ret;
}

#******************************************************
# @desc     set connections to database server and return its database handles
#           $self->set_db_server_connection( qw/SERVER_PREFIX_IKUYOBBS SERVER_PREFIX_REIKUYO SERVER_PREFIX_GEO/ );
#
# @param    array server prefix
#			[
#            { dbhandle_name => SERVER_PREFIX },
#            { dbhandle_name => SERVER_PREFIX },
#            { dbhandle_name => SERVER_PREFIX },
#            ]
# @return   WITH NO ARGUMENT RETURNS UNDEF
#******************************************************
sub set_db_server_connection {
	my $self = shift;

	return undef if 1 > @_;

	my $DBHANDLE = {
		SERVER_PREFIX_IKUYOBBS	=> 'dbhIkuyoBbsR',
		SERVER_PREFIX_REIKUYO	=> 'dbhReIkuyoR',
		SERVER_PREFIX_GEO		=> 'dbhGeoR',
		SERVER_PREFIX_SNS		=> 'dbhR',
	};

	1 == @_ 
	? (
        $self->{$DBHANDLE->{ $_[0] } } = exists( $DBHANDLE->{ $_[0] } ) ? classDBAccess->new : undef,
        $self->{$DBHANDLE->{ $_[0] } }->connect($self->cfg->param( $_[0] ), 'READ')
       )
    : (
        map {
            $self->{$DBHANDLE->{ $_ } } = exists( $DBHANDLE->{ $_ } ) ? classDBAccess->new : undef;
            $self->{$DBHANDLE->{ $_ } }->connect($self->cfg->param($_), 'READ');
        } @_
    );
    return $self;
}

=pod

#******************************************************
# @desc     disconnect all database server connections
# @desc     Servers are ReIkuyo, IkuyoBBS, RGeo
# @desc     And Only Slave Servers ( no update, insert action with SNS )
# @param    
# @param    
# @return   
#******************************************************
sub disconnect_db_server_connections {
	my $self = shift;

	#my $server_connections = $self->set_db_server_connection( qw// );

	$self->dbhReIkuyoR->{DBHandle}->disconnect();
	$self->dbhIkuyoBbsR->{DBHandle}->disconnect();
	$self->dbhGeoR->{DBHandle}->disconnect();

	return $self;
}

#******************************************************
# @desc     disconnect SNS database server connection
# @param	hash { READ , WRITE, BOTH }
# 
#******************************************************
sub disconnect_dbh {
	my $self = shift;
	#return if 1 > @_;
	my $arg = shift || return; # no action if no arguments

	$arg->{BOTH}
	? $self->dbhR->{DBHandle}->disconnect(), && $self->dbhW->{DBHandle}->disconnect()
	: $arg->{READ} 
	? $self->dbhR->{DBHandle}->disconnect()
	: $arg->{WRITE} 
	? $self->dbhW->{DBHandle}->disconnect()
	: ;;;;

	return $self;
 }

=cut

#******************************************************
# @desc		Accessor
# @desc		databseハンドル SQLを直接実行するときなど
# @return
#********************************************
=pod
# no more in use 2012/03/15
sub dbh {
	my $self  = shift;
	my $level = $self->cfg->param('MYSQL_TRACE_LOG');
	return $self->{dbh};
}
=cut
#******************************************************
# @desc		Accessor
# @desc		読み込み用データベースハンドル
# @return
#******************************************************
sub dbhR {
    my $self  = shift;
    my $level = $self->cfg->param('MYSQL_TRACE_LOG');
    $self->{dbhR}->{DBHandle}->trace( $level,
        sprintf("%s/SNS/tmp/DBITrace_classDBAccessRead_SNS.log", $self->cfg->param('ST_IKUYO_COREAPI_CORE_DIR')));
     $self->{dbhR}->{DBHandle}->do('set names utf8');
    return $self->{dbhR};
}

#******************************************************
# @desc	  Accessor
# @desc	  書き込み用データベースハンドル
# @return
#******************************************************
sub dbhW {
    my $self  = shift;
    my $level = $self->cfg->param('MYSQL_TRACE_LOG');
    $self->{dbhW}->{DBHandle}->trace( $level,
        sprintf("%s/SNS/tmp/DBITrace_classDBAccessWrite_SNS.log", $self->cfg->param('ST_IKUYO_COREAPI_CORE_DIR')));
     $self->{dbhW}->{DBHandle}->do('set names utf8');
    return $self->{dbhW};
}

#******************************************************
# @desc     Accessor
# @desc     読み込み用データベースハンドル(SNS全文検索専用)
# @return
#******************************************************
sub dbhFTSR {
    my $self  = shift;
    my $level = $self->cfg->param('MYSQL_TRACE_LOG');
    $self->{dbhFTSR}->{DBHandle}->trace( $level,
        sprintf("%s/SNS/tmp/DBITrace_classDBAccessRead_SNSFullTextSearch.log", $self->cfg->param('ST_IKUYO_COREAPI_CORE_DIR')));
     $self->{dbhFTSR}->{DBHandle}->do('set names utf8');
    return $self->{dbhFTSR};
}

#******************************************************
# @desc	  Accessor
# @desc	  書き込み読み込み用データベースハンドル
# @return
#******************************************************
sub dbhImageR {
    return shift->{dbhImageR};
}
sub dbhImageW {
    return shift->{dbhImageW};
}

#******************************************************
# @desc     Accessor
# @desc     Database handle of ReIkuyo
# @return   DatabaseHandle
#******************************************************
sub dbhReIkuyoR {
	return shift->{dbhReIkuyoR};
}

#******************************************************
# @desc     Accessor
# @desc     Database handle of IkuyoBBS
# @return   DatabaseHandle
#******************************************************
sub dbhIkuyoBbsR {
	return shift->{dbhIkuyoBbsR};
}

#******************************************************
# @desc     Accessor
# @desc     Database handle of Geo
# @return   DatabaseHandle
#******************************************************
sub dbhGeoR {
	return shift->{dbhGeoR};
}

#******************************************************
# @access	public
# @desc	  Transactionの開始 コミットは$self->dbh->commit();
# @param
# @return
#******************************************************
sub transactInit {
	my $self = shift;

	$self->{attr_ref}->{RaiseError} = $self->dbh->{RaiseError};
	$self->{attr_ref}->{PrintError} = $self->dbh->{PrintError};
	$self->{attr_ref}->{AutoCommit} = $self->dbh->{AutoCommit};
	$self->dbh->{RaiseError}		= 1;
	$self->dbh->{PrintError}		= 0;
	$self->dbh->{AutoCommit}		= 0;

	return $self;
}

#******************************************************
# @access	public
# @desc	  Transactionの終了
# @desc	プログラム側で$self->dbh->rollback() を実行しても$self->transactFin($@);としてもよい
# @desc	このファンクションでrollbackでもOK
# @return
#******************************************************
sub transactFin {
	my ( $self, $error ) = @_;

	if ($error) {
		## 開発時にエラー内容の出力するときはコメントを外す
		#print "トランザクションROLLBACK \nエラー：\n $error \n";
		#warn "トランザクションROLLBACK \nエラー：\n $error \n";
		eval { $self->dbh->rollback(); };
	}

	#####@もとの状態に戻す
	$self->dbh->{AutoCommit} = $self->{attr_ref}->{AutoCommit};
	$self->dbh->{PrintError} = $self->{attr_ref}->{PrintError};
	$self->dbh->{RaiseError} = $self->{attr_ref}->{RaiseError};

	return $self;
}

sub sns_ignore_list {
	my $self = shift;

	# member_id値がない場合(処理未確定)
	return if 0 > @_;

	my $member_id = shift;

	my $sql = sprintf(
		"SELECT CASE
 WHEN target_c_member_id = ? THEN c_member_id
 WHEN c_member_id = ? THEN target_c_member_id
 ELSE 0 END AS ignore_c_member_id
  FROM ikuyo_sns_ignore
   WHERE target_c_member_id= ? OR c_member_id= ?;
", $member_id
	);
}

#******************************************************
# @access
# @desc	 xml出力
# @param	string
# @param	hash object
# @return   hash object
#******************************************************
sub sns_outputXML {
	my $self = shift;
	my ( $api_name, $dataobject ) = @_;

	$self->{sns_outputXML} = GenerateXML::xmlHeader();
	$self->{sns_outputXML} .= GenerateXML::write2XML( $api_name, $dataobject );

	return ( $self->{sns_outputXML} );
}
=pod
sub getResult {
	my $self	   = shift;
	my $dataobject = shift;

	if (!exists( $dataobject->{api_name} ) ||
			!exists( $dataobject->{dataobject} ) ) {
		return [500, [], ["go to error routine"]];
	} else {
		return [ 200, [ GenerateXML::xmlHeader2() ], [ $dataobject->{dataobject} ] ];
	}
}

#******************************************************
# @access
# @desc	 xml出力
# @param	string
# @param	hash object
# @return
#******************************************************
sub outputXML {
	my $self	   = shift;
	my $dataobject = shift;

	my $ret			= $self->getResult($dataobject);
	my $httpStatus	= $ret->[0];
	my %headers		= @{ $ret->[1] };
	my $body		= $ret->[2]->[0];

	if ($httpStatus == 200) {
		print map { $_ . ": " . $headers{$_} . "\n" } grep { length } keys %headers;
		print "\n";
		print GenerateXML::write2XML($dataobject->{api_name}, $body);
	} else {
		print GenerateXML::xmlHeader();
		print $body;
	}
}
=cut
sub getResult {
	my $self	   = shift;
	my $dataobject = shift;

	if (!exists( $dataobject->{api_name} ) ||
			!exists( $dataobject->{dataobject} ) ) {
		return [500, [], ["go to error routine"]];
	} else {
		return [ 200, [ GenerateXML::xmlHeader2() ], [ $dataobject->{dataobject} ] ];
	}
}

#******************************************************
# @access
# @desc	 xml出力
# @param	string
# @param	hash object
# @return
#******************************************************
sub outputXML {
	my $self	   = shift;
	my $dataobject = shift;

	my $ret			= $self->getResult($dataobject);
	my $httpStatus	= $ret->[0];
	my %headers		= @{ $ret->[1] };
	my $body		= $ret->[2]->[0];

	if ($httpStatus == 200) {
		print map { $_ . ": " . $headers{$_} . "\n" } grep { length } keys %headers;
		if ($body->{custom_code}){
			printf("Ikuyo-Status: %d \n\n", $body->{custom_code});
	   	}
		else {
			print "\n";
		}
		print GenerateXML::write2XML($dataobject->{api_name}, $body);
	} else {
		print GenerateXML::xmlHeader();
		print $body;
	}
}

#******************************************************
# @desc     Setter Getter for error response code
# @param    
# @param    
# @return   
#******************************************************
sub error_response {
	my $self = shift;
	$self->{error_response} = shift if @_;
	$self->{error_response};
}

#******************************************************
# @desc	 エラー時の失敗レスポンス
# @param
# @param
# @return
#******************************************************
sub custom_error {
	my ( $self, $ERR_KEY ) = @_;

	my $http_status_code =
	  $self->CONFIGURATION_VALUE('HTTP_CUSTOM_RESPONSE_CODE');
	my @http_custom_code = $self->fetchArrayValuesFromConf($ERR_KEY);

	return(
		{
			api_name			=> $self->_myCallerMethodName->{sub_class_name},
			dataobject			=> {
				http_status_code 	=> $http_status_code,
				custom_code			=> $http_custom_code[0],
				message				=> $http_custom_code[1],
			},
		}
	);
#CoreBasic::displayHttpStatus( $http_status_code, $http_custom_code[1], $http_custom_code[0] );
}

#******************************************************
# @desc	 エラーハンドリング
#******************************************************
sub error {
	my $class = shift;
	my $msg = $_[0] || '';
	$msg .= "\n" if ( $msg ne '' ) && ( $msg !~ /\n$/ );
	if ( ref($class) ) {
		$class->{_errstr} = $msg;
	}
	else {
		#$ERROR = $msg;
		#ref($_[0]) ? $_[0]->{_errstr} : $msg;
	}
	return;
}

#sub errstr { ref($_[0]) ? $_[0]->{_errstr} : $ERROR }
#******************************************************
# @desc	 成功レスポンス時のhtmlheader
#			設定ファイルのSEND_NO_HTML_HEADERが設定されてるときは
#			ヘッダー送信をしない。デバッグ時専用
# @return
#******************************************************
sub send_html_header {
	my $self = shift;

	return ( $self->cfg->param('SEND_NO_HTML_HEADER')
		? ""
		: CoreBasic::displayHtmlHeader() );
}

#******************************************************
# @access   public
# @desc		ログキュー
# @param	string LEVEL [ALERT, INFO, DEBUG]
# @param	string METHOD NAME
# @param	HASH REF
#			{
#				LEVEL,
#				EXTRA
#			}
# @return
#******************************************************
sub set_setLog {
	my $self = shift;
	my $option = shift;
	my $caller = $self->_myCallerMethodName;

	return (
		CoreBasic::setLog(
			( exists($option->{LEVEL}) ? $option->{LEVEL} : 'INFO' ), $caller->{package}, $option->{EXTRA}
		)
	);
}

#******************************************************
# @access   public
# @desc		メムログ
# @desc		setMemLog引数 LEVEL, METHOD, AREA_ID, MEMNO, POINT, KEY1, KEY2, 
# @param	string LEVEL [INFO, ALERT, INFO, POINT, G, DEBUG]
#			{
#				LEVEL,
#				METHOD,
#				AREAID,
#				MEMNO,
#				POINT,
#			}
# @return
#******************************************************
sub set_setMemLog {
	my $self = shift;
	my $option = shift;

	return (
		CoreBasic::setMemLog(
			( exists($option->{LEVEL}) ? $option->{LEVEL} : 'INFO' ), $self->_myCallerMethodName->{package}, $option->{AREAID}, $option->{MEMNO}, undef, undef, undef, $option->{VALUE1}, $option->{VALUE2}
		)
	);
}

#******************************************************
# @access   public
# @desc	 メール送信テンプレートタイプ
#		   管理画面で設定したメールテンプレートを元に送信
#		   送信種別 mail:メールのみ / push プッシュのみ / auto 自動
#
# area_memno2mailTemp(
#	areaid,
#	memno,
#	mailfrom(number),
#	return_address,
#	mail_type,
#	[ debug_emailaddress|undef ],
#	hashtags
# )
#
#
# @param	hash
#			{
#				areaId				     # エリアID
#				memNo				     # memno
#				mail_push_from_number    # メールfrom番号 (master.xml->MailFrom->番号 省略時は1を入れる)
#				mail_push_return_address # リターンアドレス 必須ではない
#				mail_push_type		     # メールタイプ番号
#				mail_push_send_4debug    # debug用に送りたい場合のメールアドレス
#				mail_push_tags		{}   # 置換タグ
#			}
#
# @return
#******************************************************
sub area_memno2mailTemp {
	my ( $self, $mailsetting ) = @_;

	return (
		CoreBasic::area_memno2mailTemp(
			$mailsetting->{areaId},
			$mailsetting->{memNo},
			$mailsetting->{mail_push_from_number},
			$mailsetting->{mail_push_return_address},
			$mailsetting->{mail_push_type},
			( $self->cfg->param('DEBUG_MODE') && !defined( $mailsetting->{mail_send_4debug} ) ? $self->cfg->param('ST_SNS_MAIL_PUSH_4DEBUG_MAILADDRESS') : $mailsetting->{mail_send_4debug} ),
			$mailsetting->{member_data},
			%{ $mailsetting->{mail_push_tags} }
		)
	);
}

#******************************************************
# @access   public
# @desc     get area name by area id
# @param    none
# @return   string area name
#******************************************************
sub area_name_from_area_id {
	my $self = shift;

	my $area_name = classMasterDataAccess->new->getAreaNameList( $self->self_data->{areaId} )->{ $self->self_data->{areaId} };

	return $area_name;
}

#******************************************************
# @access   public
# @desc     convert app emojicode to domoco emoji code
# @desc     convert '[({ unicode nnn })]' tags input from app to '[i:nnn]'
#            nnn => class
#           OR convert docomo tag to unicode tag
#
#           incomming tags from app [({ unicode nnn })] and store it as [i:nnn] 
#           outputting tags to app, convert [i:nnn] to [({ unicode nnn })]
#
# @param    hash { in_out => IN|OUT, type => [bbs|sns] , text => string }
#            in case of no type sns is set for default
#
#******************************************************
my $EMOJI;
sub emoji_unicode_2_emoji_docomo {
    my ( $self, $emoji_text ) = @_;

    return if !exists( $emoji_text->{text} ) || '' eq $emoji_text->{text};

    $emoji_text->{type} ||= 'sns';

    $EMOJI = Emoji->new if ! $EMOJI;
    return (
        $emoji_text->{in_out} eq 'IN'  ? $EMOJI->unicodetag2docomotag( $emoji_text->{type}, $emoji_text->{text} ) :
        $emoji_text->{in_out} eq 'OUT' ? $EMOJI->tag2emoji('class', $emoji_text->{text}, 'utf8') :
        ""
     );
    #my $emoji = Emoji->new;
    #return (
    #	$emoji_text->{in_out} eq 'IN'  ? $emoji->unicodetag2docomotag( $emoji_text->{type}, $emoji_text->{text} ) :
    #	$emoji_text->{in_out} eq 'OUT' ? $emoji->tag2emoji('class', $emoji_text->{text}, 'utf8') :
    #	""
    # );
}

#******************************************************
# @access
# @desc	 レスポンスデータにデバッグ情報を追加する。
# @desc	 コンフィグレーション設定項目DEBUG_MODEが1の場合のみ情報が付加される。
# @param	hash
# @param	hash 追加情報
# @return   hash
#******************************************************
sub debug_mode {
	my ( $self, $obj, $arg ) = @_;

	if ( $self->cfg->param('DEBUG_MODE') ) {
		my $key = '__DEBUG__';
		map { $obj->{ $key . $_ } = $arg->{$_} } keys %{$arg};
		map { $obj->{ $key . 'SelfData' }->{$_} = $self->self_data->{$_} }
		  keys %{ $self->self_data };
		$obj->{ $key . 'SelfData' }->{sid} = $self->sid;

	}
	return $obj;
}

sub sns_store_image {
	my $self   = shift;
	my @imagef = $self->query->upload('image');

	foreach my $fh (@imagef) {
		my $mime_type = $self->query->uploadInfo($fh)->{'Content-Type'};

		$mime_type =~ s!(^image/)x-(png)$!$1$2!;
		$mime_type =~ s!(^image/).+?(jpeg)$!$1$2!;

	}
}

#******************************************************
# @access
# @desc	  設定ファイルのキーを引数に対応した値を取得
#			キーが存在しない場合undefを返す
#			引数が複数の場合(リストコンテキスト)は配列で値を返す
#			引数が単一の場合(スカラコンテキスト)はスカラで値を返す
#
# @param	 char	$configrationkey
# @return	char/undef	$configrationvalue
#******************************************************
sub CONFIGURATION_VALUE {
	my $self = shift;

	return undef if 1 > @_;

	my %CONFIGRATIONKEY = $self->cfg->vars();

	return (
		1 == @_
		? (
			$self->{CONFIGURATION_VALUE}->{ $_[0] } =
			  exists( $CONFIGRATIONKEY{ $_[0] } )
			? $CONFIGRATIONKEY{ $_[0] }
			: undef
		  )
		: (
			map {
				$self->{CONFIGURATION_VALUE}->{$_} =
				  ( exists( $CONFIGRATIONKEY{$_} ) )
				  ? $CONFIGRATIONKEY{$_}
				  : undef
			} @_
		)
	);
}

#******************************************************
# @access   public
# @desc	 ikuyo_sns_config.cfgから値を取得して配列で返す
# @param	key
# @return   array
#******************************************************
sub fetchArrayValuesFromConf {
	my $self = shift;
	unless (@_) { return; }

	my $name = shift;
	my @values = split( /,/, $self->cfg->param($name) );

	return (@values);
}

#******************************************************
# 実行中のメソッド名取得
#******************************************************
sub _myMethodName {
    my @stack = caller(1);
    my $methodname = $stack[3];
    $methodname =~ s{\A .* :: (\w+) \z}{$1}xms;
    return $methodname;
}

#******************************************************
# @access    private
# @desc        呼び出しメソッド名やパッケージ名
# @param    
# @return    hashobj {package, filename, line, methodname}
#******************************************************
sub _myCallerMethodName {
    my $callerref;
    ( $callerref->{package}, $callerref->{filename}, $callerref->{line}, $callerref->{method} ) = caller(1);

	( $callerref->{base_class_name}, $callerref->{sub_class_name} ) = split('::', $callerref->{package});

    return $callerref;
}


1;
__END__
