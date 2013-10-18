#******************************************************
# @desc	   194964SNS日記
# @package	SNS::SNSPostCommentDiaryList
# @access	 public
# @author	 Iwahase Ryo
# @create	 2013/03/13
# @version	1.00
# @update use Carp ();$SIG{__WARN__} = \&Carp::cluck;
#
# @update    2013/09/11 Optimize code and SQL 
# @update
#******************************************************
package SNS::SNSPostCommentDiaryList;

our $VERSION = '1.00';

use strict;
use warnings;

use parent qw(SNS);

use Plugin::Adjuster qw(areaCode2MasterID);

#******************************************************
# @access	public
# @desc		コンストラクタ
# @param
# @return
#******************************************************
sub new {
	my ( $class, $cfg ) = @_;
	return $class->SUPER::new($cfg);
}

#******************************************************
# dispatch
#******************************************************
sub run {
	my $self = shift;

	my $error_custom_code;
	if ($error_custom_code = $self->SUPER::run()) {
		return $self->custom_error($error_custom_code);
	}
	else {
		$self->set_self_data_by_sid();
		return $self->custom_error($self->error_response) if $self->error_response;
		$self->sns_post_comment_diary_list();
	}
}

#******************************************************
# @access
# @desc	 fetch diary data which you have post
# @param
# @param
# @return
#******************************************************
sub sns_post_comment_diary_list {
    my $self = shift;

    # Modified 2013/08/26 本番サーバー参照テスト用に空のエンティティを返す仕様 BEGIN
=pod
    my $retobj = {
        SNSDiaryList    => [],
    };
    return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => $retobj } );
=cut
    # Modified 2013/08/26 本番サーバー参照テスト用に空のエンティティを返す仕様 END

    my $obj;

    my $sid         = $self->sid();
    my $appid       = $self->appid();
    my $c_member_id = $self->self_data->{snsMemberId};
    my $memno       = $self->self_data->{memNo};
    my $areaid      = $self->self_data->{areaId};
    my $name        = $self->self_data->{name};
    my $age         = $self->self_data->{age};
    my $gender      = $self->self_data->{sex};
    my $play_city   = $self->self_data->{playCity};

    my $c_member_table          = $self->cfg->param('SNS_MYSQL_TABLE_MEMBER');
    my $c_diary_table           = $self->cfg->param('SNS_MYSQL_TABLE_DIARY');
    my $c_diary_comment_table   = $self->cfg->param('SNS_MYSQL_TABLE_DIARY_COMMENT');
    my $ikuyo_profile_table     = $self->cfg->param('SNS_MYSQL_TABLE_IKUYO_PROFILE');

## Modified 2013/10/15
    my $diary_id_2_next         = $self->cgi->param('lastDiaryId') || 0;

    my $offset          = $self->cgi->param('offset') || 0;
    my $record_limit    = 
            !$self->cgi->param('count')    ? 5 :
            1 > $self->cgi->param('count') ? 5 :
            $self->cgi->param('count')
            ;

    my $condition_limit     = $record_limit + 1;

## 2013/09/11 Optimize SQL BEGIN
    my $memcached_key_base  = $self->cfg->param('MEMCACHED_KEY4_SNS_DIARY_RECEIVED_COMMENT_COUNT');

## Modified 2013/10/15 BEGIN
        my $ignore_list;

    # get both ignore and ignored 
        my $tmp_ignorelist = $self->ignore_list(1);
        map { $ignore_list->{$_} = 1 } @{ $tmp_ignorelist->{ignore_list} };

    ## 自分自身の日記を表示させないため
        $ignore_list->{$c_member_id} = 1;

        my $sql_ids = sprintf("SELECT D.c_member_id, D.c_diary_id FROM %s  DC
 STRAIGHT_JOIN %s D
  ON D.c_diary_id = DC.c_diary_id
    LEFT JOIN %s M
      ON M.c_member_id = D.c_member_id
  WHERE DC.c_member_id = ?
   GROUP BY DC.c_diary_id ORDER BY D.u_datetime DESC", $c_diary_comment_table, $c_diary_table, $c_member_table);
   #GROUP BY DC.c_diary_id ORDER BY DC.c_diary_comment_id DESC", $c_diary_comment_table, $c_diary_table, $c_member_table);
        my $arrayref = $self->dbhFTSR->{DBHandle}->selectall_arrayref( $sql_ids, { Columns => {} }, $c_member_id );

        my @c_diary_ids;

        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } ) if 1 > scalar @{ $arrayref } or !defined $arrayref;

        map {
            push (@c_diary_ids, $arrayref->[$_]->{c_diary_id}) if  !$ignore_list->{ $arrayref->[$_]->{c_member_id} };
        } 0..$#{ $arrayref };

        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } ) if !@c_diary_ids;

        # nextDiaryIdが利いてない対応
        # @c_diary_idから$diary_id_2_nextでの指定部分までを削除する
        my @c_diary_id;
        my @c_diary_ids_tmp;
        if($diary_id_2_next ne '' && $diary_id_2_next ne '0'){
        	my $outPutLine = 0;
			for (my $i=0; $i<@c_diary_ids; $i++){
				if($outPutLine == 1){
					# リストに追加
					push(@c_diary_ids_tmp, $c_diary_ids[$i]);
				}
				if($c_diary_ids[$i] eq $diary_id_2_next){
					# ここまでは前回出力済み
					$outPutLine = 1;
				}
			}
			@c_diary_id  = $record_limit < scalar @c_diary_ids_tmp ? @c_diary_ids_tmp[0..$record_limit] : @c_diary_ids_tmp;
		}
		else{
			@c_diary_id  = $record_limit < scalar @c_diary_ids ? @c_diary_ids[0..$record_limit] : @c_diary_ids;
		}
		
=pod
        my @c_diary_id  = $record_limit < scalar @c_diary_ids ? @c_diary_ids[0..$record_limit] : @c_diary_ids;
=cut

        my $sql = sprintf("SELECT 
 M.nickname           AS targetName
, M.ikuyo_area_id     AS targetAreaId
, M.ikuyo_memno       AS targetMemNo
, M.ikuyo_area_code   AS targetPrefCode
, M.gender            AS targetSex
, M.is_age_verified   AS isAgeVerified
, D.c_member_id       AS snsMemberId
, D.c_diary_id        AS diaryId
, D.subject           AS diaryTitle
, D.body              AS diary
, D.category          AS adultFlag
, D.pv_count          AS pageViewCount
, D.r_datetime        AS createdDateTime
, D.r_date            AS createdDate
, D.image_filename_1  AS imageFileName1
, D.image_filename_2  AS imageFileName2
, D.image_filename_3  AS imageFileName3
, D.is_checked        AS isChecked
, D.public_flag       AS openAreas
, D.comment_settings  AS commentAllowed
, D.is_enable_trial   AS isEnableTrial
, D.u_datetime        AS upDatedTime
, D.is_suspend        AS isSuspend
 FROM %s DC
  STRAIGHT_JOIN %s D
   ON D.c_diary_id = DC.c_diary_id
      LEFT JOIN %s M
        ON M.c_member_id = D.c_member_id
    WHERE DC.c_diary_id IN(%s) 
      GROUP BY DC.c_diary_id ORDER BY D.u_datetime DESC", $c_diary_comment_table, $c_diary_table, $c_member_table, join(',', @c_diary_id));
#      GROUP BY DC.c_diary_id ORDER BY DC.c_diary_comment_id DESC", $c_diary_comment_table, $c_diary_table, $c_member_table, join(',', @c_diary_id));

    my $maxrec_sql = sprintf("SELECT COUNT(D.c_diary_id) AS MAXREC FROM %s DC STRAIGHT_JOIN %s D
   ON D.c_diary_id = DC.c_diary_id
      LEFT JOIN %s M
        ON M.c_member_id = D.c_member_id
    WHERE DC.c_diary_id IN(%s) GROUP BY DC.c_diary_id", $c_diary_comment_table, $c_diary_table, $c_member_table, join(',', @c_diary_ids));

    $self->dbhR->setEncodeFrom('utf8');
    $self->dbhR->setEncodeTo('utf8');
    $obj->{SNSDiaryList} = $self->dbhR->executeReadPlus(
        'DBServerSNSDiary',
        'stage194master',
        $c_diary_table,
        $areaid,
        $memno,
        $sql, undef,
        {
            placeholder => [ ]
        },
    );

    $obj->{maxrec} = $self->dbhR->executeReadPlus_with_row_or_col( {
                        dbi_method      => 'row',
                        condition       => {
                            sql_statement   => $maxrec_sql,
                        }
                    } );

    # 日記データがある
    if ( defined( $obj->{SNSDiaryList} ) ) {
        if ( $record_limit < scalar @{ $obj->{SNSDiaryList} } ) {
            pop @{ $obj->{SNSDiaryList} };
            $obj->{diaryId2Next} = !exists( $obj->{diaryId2Next} ) ? $obj->{SNSDiaryList}->[-1]->{diaryId} : $obj->{diaryId2Next} ;
        }

        $obj->{lastDiaryId} = $diary_id_2_next;
        $obj->{count}       = $record_limit;

        # make sql ready in case of no cache for receive commment count
        $sql = sprintf("SELECT COUNT(c_diary_comment_id) AS receivedCommentCount FROM %s WHERE c_diary_id = ? AND is_suspend = 0;", $c_diary_comment_table );
        my $sth = $self->dbhR->{DBHandle}->prepare($sql);

        ## set server connections beforehand
        $self->set_db_server_connection( qw/SERVER_PREFIX_IKUYOBBS SERVER_PREFIX_REIKUYO SERVER_PREFIX_GEO/ );

        map {
            my $idx = $_;
           ## convert prefcode to master.xml pref id
            $obj->{SNSDiaryList}->[$idx]->{targetPrefCode} = areaCode2MasterID($obj->{SNSDiaryList}->[$idx]->{targetPrefCode});

            # First get data for received Comment from cache 2013/09/11
            # if no cache then do SQL and set it to cache
            my $memcached_key_4receivedCommentCount = sprintf( "%s%d", $memcached_key_base, $obj->{SNSDiaryList}->[$idx]->{diaryId} );
            if ( !( $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount} = $self->sns_memcached->get($memcached_key_4receivedCommentCount))) {
                $sth->execute( $obj->{SNSDiaryList}->[$idx]->{diaryId} );
                $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount} = $sth->fetchrow_array();
                $self->sns_memcached_write->set($memcached_key_4receivedCommentCount, $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount}, 600);
            }

            # プロフィール画像取得
            my $tmp = $self->get_getImageUrl( {
                member_data => {
                            memno           => $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
                            areaid          => $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
                            sns_member_id   => $obj->{SNSDiaryList}->[$idx]->{snsMemberId},
            },
                type        => 1,
                id_for_type => $obj->{SNSDiaryList}->[$idx]->{snsMemberId},
                flag        => 1,
                size        => 133,
            } );
            my $imageUrl  = 'pictureUrl';
            map {
                $obj->{SNSDiaryList}->[$idx]->{ $imageUrl  . ($_+1) } = $tmp->[$_]->{image_url};
            } 0..$#{ $tmp };

        ## get the value of is_suspend
            my $isSuspend = $self->get_getSuspendOfDiaryImageFile(
                        {
                            memno           => $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
                            areaid          => $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
                            sns_member_id   => $obj->{SNSDiaryList}->[$idx]->{snsMemberId},
                            imageFileName1  => $obj->{SNSDiaryList}->[$idx]->{imageFileName1},
                            imageFileName2  => $obj->{SNSDiaryList}->[$idx]->{imageFileName2},
                            imageFileName3  => $obj->{SNSDiaryList}->[$idx]->{imageFileName3},
                        }
                    );
            map { $obj->{SNSDiaryList}->[$idx]->{$_} = $isSuspend->{$_} } keys %{ $isSuspend };

            # リスト表示Icon情報取得処理
            my $icondata_ref = $self->fetch_member_icon_data_distance(
                {
                    sessiondata => $self->self_data,
                    memno		=> $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
                    areaid		=> $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
                    distanceOff => 1,
                }
            );

            map { $obj->{SNSDiaryList}->[$idx]->{$_} = $icondata_ref->{$_} } keys %{$icondata_ref};

            # 絵文字処理
            $obj->{SNSDiaryList}->[$idx]->{targetName}	= $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{targetName} } );
            $obj->{SNSDiaryList}->[$idx]->{diary}		= $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diary} } );
            $obj->{SNSDiaryList}->[$idx]->{diaryTitle}	= $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diaryTitle} } );

        } 0 .. $#{ $obj->{SNSDiaryList} };
    }
    else {
        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } );
    }

    my $retobj = $self->debug_mode( $obj, $self->sns_member_data);

    ## Modified 2013/05/21 disconnecting database servers
    #$self->disconnect_db_server_connections;
    #$self->disconnect_dbh(READ => 1); #$self->dbhR->{DBHandle}->disconnect();

    return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => $retobj } );
}


1;
__END__
