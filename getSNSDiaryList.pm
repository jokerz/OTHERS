#******************************************************
# @desc	   194964SNS日記リストの取得
# @package	SNS::getSNSDiaryList
# @access	 public
# @author	 Iwahase Ryo
# @create	 2012/12/03
# @version	1.00
# @update use Carp ();$SIG{__WARN__} = \&Carp::cluck;
#
# @update
# @update
#******************************************************
package SNS::getSNSDiaryList;

our $VERSION = '1.00';

use strict;
use warnings;

use parent qw(SNS);

use Plugin::Adjuster qw(areaCode2MasterID areaCode2MasterIDArray prefid2areacode);

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
        $self->sns_diary_list();
    }
}

#******************************************************
# @access
# @desc	 fetch diary data
# @update  2013/09/25  Logic Factory uda  出力パラメータ追加(画像の許可/不許可フラグ)
# @param
# @param
# @return
#******************************************************
sub sns_diary_list {
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

use Time::HiRes qw(gettimeofday tv_interval);
my $meth_start = [gettimeofday];

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
    my $c_friend_table          = $self->cfg->param('SNS_MYSQL_TABLE_FRIEND');
    my $ikuyo_sns_ignore_table  = 'ikuyo_sns_ignore'; 
    # for searching diaries
    my $target_memno            = $self->cgi->param('targetMemNo');
    my $ikuyo_area_code         = $self->cgi->param('ikuyoAreaCode');
    my $filter_area             = $self->cgi->param('filterArea');
    my $conditions              = $self->cgi->param('conditions');
  # IMPORTANT adult contents MUST NOT BE SEARCHED with iOS device 1 == pure / 2 == adult
    my $adult_flag              = $self->is_iOS ? 1 : $self->cgi->param('adultFlag');
    ## need set default value ( get diary list from 全体公開・会員のみ)
    my $open_areas              = $self->cgi->param('openAreas') || 6;# o 1 2 3 => 1 2 4 8 16 

    my $diary_id_2_next         = $self->cgi->param('lastDiaryId') || 0;

    my @err_msg;
    if ($adult_flag && 2 < $adult_flag ) {
        push @err_msg, 'adultFlag must be 1 OR 2';
    }
    if ($open_areas && ( 1 > $open_areas || 30 < $open_areas)) {
        push @err_msg, 'openAreas must be number between 1 and 4';
    }
    if ($open_areas && ( 30 == $open_areas && $memno != $target_memno )) {
        push @err_msg, 'openAreas 30 can be set when targetmemno is your memno';
    }
    if (0 < scalar(@err_msg)) {
        return $self->custom_error('SNS_CODE_3003');
    }

    my $offset       = $self->cgi->param('offset') || 0;
    ## Modified add max number for "count" no more than 30
    my $record_limit =
            !$self->cgi->param('count')     ? 5  :
            1  > $self->cgi->param('count') ? 5  :
            30 < $self->cgi->param('count') ? 30 :
            $self->cgi->param('count')
            ;

    my $condition_limit = $record_limit + 1;

    my $receive_commnet  = $self->cgi->param('receiveCommnet');
    my $current_location = $self->cgi->param('currentLocation');

    my $memcached_key;
    my $memcached_key_base = $self->cfg->param('MEMCACHED_KEY4_SNS_DIARY_RECEIVED_COMMENT_COUNT');

    my $multicondition;
    my @placeholder;
    my @whereSQL;
    my $sqltype;
    my $ignore_list;

## Modified 2013/10/07.8 BEGIN
    my $sql;
    my $maxrec_sql  = sprintf( "SELECT COUNT(D.c_diary_id) AS MAXREC FROM %s AS D LEFT JOIN %s AS M ON M.c_member_id = D.c_member_id", $c_diary_table, $c_member_table );
    my $prepare_sql;

    if ($target_memno) {

        $sqltype = 1;

        $sql = 'friend' eq $target_memno ? $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 }) : $self->build_base_diary_SQL({ NO194PROFILE => 1 });
        push( @whereSQL, "(D.is_suspend = 0 AND M.is_suspend = 0)" );

      # getting diary list of my friend
        if ('friend' eq $target_memno) {
        	# friendの場合 強制的にopenAreasを 2：全体公開 4：会員のみ 8：友達のみにする
        	$open_areas = '14';
        	
            $prepare_sql = sprintf("SELECT
 F.c_member_id_to
 FROM %s AS F
  WHERE c_member_id_from = ? ", $c_friend_table);

            my $friend_c_member_ids = $self->dbhR->{DBHandle}->selectcol_arrayref( $prepare_sql, undef, $c_member_id );

            $friend_c_member_ids->[-1]
                ?
            push( @whereSQL, sprintf("D.c_member_id IN(%s)", join(',', @{ $friend_c_member_ids })) )
                :
            return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } )
            ;
        }
        else {
            if ( $memno == $target_memno ) { ## 自分自身の場合
                push( @whereSQL,    " M.c_member_id = ?" );
                push( @placeholder, $c_member_id );
            }
            elsif ($target_memno && $ikuyo_area_code) { # 指定会員の情報を取得
                # 指定会員の情報を取得
                my @areaid_masterid = areaCode2MasterIDArray(prefid2areacode($ikuyo_area_code));
                $self->sns_member_data_by_memno( $target_memno,  $areaid_masterid[0]);

                return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } ) if !$self->sns_member_data;

                my $target_c_member_id = $self->sns_member_data->{sns_member_id};
                
                # 対象が友達の場合 強制的にopenAreasを 2：全体公開 4：会員のみ 8：友達のみにする
                my $c_member_id = $self->self_data->{snsMemberId};
                my $isFriendSql = sprintf("SELECT 1 FROM %s WHERE (c_member_id_from = ? AND c_member_id_to = ?) OR (c_member_id_from = ? AND c_member_id_to = ?)", $self->cfg->param('SNS_MYSQL_TABLE_FRIEND'));

                my $isFriendFlag = $self->dbhR->{DBHandle}->selectrow_array($isFriendSql, undef, $self->self_data->{snsMemberId}, $target_c_member_id, $target_c_member_id, $self->self_data->{snsMemberId});
                if($isFriendFlag eq '1'){
                    $open_areas = '14';
                }

                if ($target_c_member_id) {
                    ## 対象ユーザーから無視されてる場合は結果取得は０
                    if (!$self->is_ignored($target_c_member_id)) {
                        push( @whereSQL,	" M.c_member_id = ?" );
                        push( @placeholder, $target_c_member_id );
                    }
                    else {
                        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } );
                    }
                }
                else {
                    return $self->custom_error('SNS_CODE_3002');
                }
            }
            else {
                return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } );
            }

            if ($conditions) {
                 my $search_keywords = $self->emoji_unicode_2_emoji_docomo( { in_out => 'IN', type => 'sns', text => $conditions } );
                 $multicondition     = sprintf( "*W1,2 %s ", $search_keywords );
                 push( @whereSQL, 'MATCH(D.subject, D.body) AGAINST(? IN BOOLEAN MODE)' );
                 push( @placeholder, $multicondition );
            }

        }
    }
    elsif ( $conditions && !$target_memno ) {
        $sqltype = 2;

        $sql = $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 });
        push( @whereSQL, "(D.is_suspend = 0 AND M.is_suspend = 0)" );
        my $tmp_ignorelist = $self->ignore_list(1);
        map { $ignore_list->{$_} = 1 } @{ $tmp_ignorelist->{ignore_list} };

        my $search_keywords = $self->emoji_unicode_2_emoji_docomo( { in_out => 'IN', type => 'sns', text => $conditions } );
        $multicondition     = sprintf( "*W1,2 %s ", $search_keywords );
        push( @whereSQL, 'MATCH(D.subject, D.body) AGAINST(? IN BOOLEAN MODE)' );
        push( @placeholder, $multicondition );
    }

    if ( $filter_area && 1 < $filter_area ) {
        if (3 == $filter_area && 0 < $ikuyo_area_code) {
            push( @whereSQL,    "M.ikuyo_area_code = ?" );
            push( @placeholder, prefid2areacode($ikuyo_area_code) );
        } else {
            push( @whereSQL,    "M.ikuyo_area_id = ?" );
            push( @placeholder, $areaid  );
        }
    }

    if ( defined($adult_flag) ) {
        push( @whereSQL,    2 == $adult_flag ? "D.category = ?" : "( D.category = ? OR D.category = 0 )");
        push( @placeholder, $adult_flag );
    }

    if ( defined($open_areas) && 30 != $open_areas ) {
        push( @whereSQL,    'POW(2, 0+D.public_flag) & ?' );
        push( @placeholder, $open_areas );
    }

my $start = [gettimeofday];

    if (1 == $sqltype) {
       #############################
       # TYPE 1 対象会員が決定決まってるとき（自分自身、友達、指定会員)
       #############################
            $sql .= sprintf( " %s%s", ( ( 0 < @whereSQL && 0 < $diary_id_2_next ) ? sprintf("WHERE D.c_diary_id < %d AND ", $diary_id_2_next) : ( 0 < @whereSQL && 0 == $diary_id_2_next ) ?  "WHERE " : "" ), join( ' AND ', @whereSQL ) );
            $sql .= " ORDER BY D.r_datetime DESC";
            $sql .= sprintf( " LIMIT %d", $condition_limit );

            $self->dbhR->setEncodeFrom('utf8');
            $self->dbhR->setEncodeTo('utf8');

            $obj->{SNSDiaryList} = $self->dbhR->executeReadPlus(
                'DBServerSNSDiary',
                'stage194master',
                'c_diary',
                $areaid,
                $memno,
                $sql, undef,
                {
                    placeholder => [ @placeholder ]
                },
            );
    }
    elsif (2 == $sqltype) {
       #############################
       # TYPE 2 全文検索、地域検索のヒット率が低い時
       #############################
        my $whereSQL    = sprintf( " %s%s", ( ( 0 < @whereSQL && 0 < $diary_id_2_next ) ? sprintf("WHERE D.c_diary_id < %d AND ", $diary_id_2_next) : ( 0 < @whereSQL && 0 == $diary_id_2_next ) ?  "WHERE " : "" ), join( ' AND ', @whereSQL ) );
        my $sql_ids     = sprintf("SELECT 
D.c_member_id
,D.c_diary_id
FROM %s D 
 LEFT JOIN %s M ON M.c_member_id = D.c_member_id
 %s ORDER BY D.r_datetime DESC;", $self->cfg->param('SNS_MYSQL_TABLE_DIARY'), $self->cfg->param('SNS_MYSQL_TABLE_MEMBER'), $whereSQL );

        my $aryref      = $self->dbhFTSR->{DBHandle}->selectall_arrayref( $sql_ids, { Columns => {} }, @placeholder );
        my @c_diary_ids;
        map {
            push (@c_diary_ids, $aryref->[$_]->{c_diary_id}) if  !$ignore_list->{ $aryref->[$_]->{c_member_id} }; 
            #push (@ignoreDiaryIds, $aryref->[$_]->{c_diary_id}) if  $ignore_from->{$aryref->[$_]->{c_member_id}};  #デバッグ用にとりあえず
        } 0..$#{ $aryref };

        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } ) if !@c_diary_ids;

        my @c_diary_id  = $record_limit < scalar @c_diary_ids ? @c_diary_ids[0..$record_limit] : @c_diary_ids;

        my $sql_base   = $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 });
        $sql_base      .= sprintf(" WHERE D.c_diary_id IN(%s) AND (D.is_suspend = 0 AND M.is_suspend = 0) ORDER BY D.r_datetime DESC ", join(',', @c_diary_id));

        $obj->{SNSDiaryList} = $self->dbhFTSR->{DBHandle}->selectall_arrayref( $sql_base, { Columns => {} } );
    }
    else {
       #############################
       # TYPE 3 対象が大量の時
       #############################
        $obj = $self->diary_list(
                {
                    whereSQL    => sprintf( " %s", ( 0 < @whereSQL ? join( ' AND ', @whereSQL ) : "" ) ),
                    placeholder => [ @placeholder ],
                    limit       => $record_limit,
                    base_limit  => ($ikuyo_area_code ? 10000 : 1000),
               },
                $diary_id_2_next
            );
    }

my $end = [gettimeofday];
#$obj->{MAINLISTSQLBENCHTIME} = tv_interval $start, $end;

	# 日記データがある
    if ( defined( $obj->{SNSDiaryList} ) ) {
        if ( $record_limit < scalar @{ $obj->{SNSDiaryList} } ) {
            pop @{ $obj->{SNSDiaryList} };
            $obj->{diaryId2Next} = !exists( $obj->{diaryId2Next} ) ? $obj->{SNSDiaryList}->[-1]->{diaryId} : $obj->{diaryId2Next} ;
        }

        $obj->{lastDiaryId} = $diary_id_2_next;
        $obj->{count}       = $record_limit;

        $sql = sprintf("SELECT COUNT(c_diary_comment_id) AS receivedCommentCount FROM %s WHERE c_diary_id = ? AND is_suspend = 0;", $c_diary_comment_table );
        my $sth = $self->dbhR->{DBHandle}->prepare($sql);
        # to get data from ikuyo_profile
        my $sql194profile = sprintf("SELECT IK.gender AS targetSex, IK.age AS targetAge, IK.play_city AS targetPlayCity FROM %s AS IK WHERE IK.c_member_id = ?;", $ikuyo_profile_table);
        ## set server connections beforehand
        $self->set_db_server_connection( qw/SERVER_PREFIX_IKUYOBBS SERVER_PREFIX_REIKUYO SERVER_PREFIX_GEO/ );

        map {
            my $idx = $_;
## 無視状態をチェック
#$obj->{SNSDiaryList}->[$idx]->{IGNORED} = $ignore_list->{ $obj->{SNSDiaryList}->[$idx]->{snsMemberId} } ? 1 : '';

            $sth->execute( $obj->{SNSDiaryList}->[$idx]->{diaryId} );
            ( $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount} ) = $sth->fetchrow_array();

            ($obj->{SNSDiaryList}->[$idx]->{targetSex}, $obj->{SNSDiaryList}->[$idx]->{targetAge}, $obj->{SNSDiaryList}->[$idx]->{targetPlayCity}) = $self->dbhR->{DBHandle}->selectrow_array($sql194profile, undef, $obj->{SNSDiaryList}->[$idx]->{snsMemberId});
        ## convert prefcode to master.xml pref id
            $obj->{SNSDiaryList}->[$idx]->{targetPrefCode} = areaCode2MasterID($obj->{SNSDiaryList}->[$idx]->{targetPrefCode});

            # プロフィール画像取得
            my $tmp = $self->get_getImageUrl( {

                member_data => {
                            memno         => $memno,
                            areaid        => $areaid,
                            sns_member_id => $c_member_id,
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
                            memno           => $memno,
                            areaid          => $areaid,
                            sns_member_id   => $c_member_id,
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
                    memno       => $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
                    areaid      => $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
                    distanceOff => 1,
                }
            );

            map { $obj->{SNSDiaryList}->[$idx]->{$_} = $icondata_ref->{$_} } keys %{$icondata_ref};

            # 絵文字処理
            $obj->{SNSDiaryList}->[$idx]->{targetName}    = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{targetName} } );
            #$obj->{SNSDiaryList}->[$idx]->{diary}        = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diary} } );
            $obj->{SNSDiaryList}->[$idx]->{diaryTitle}    = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diaryTitle} } );
            $obj->{SNSDiaryList}->[$idx]->{diary}         = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diary} } ) if exists ($obj->{SNSDiaryList}->[$idx]->{diary});

            # キャッシュ処理：コメント数をキャッシュに追加
            $self->sns_memcached_write->set(
                sprintf( "%s%d",
                    $memcached_key_base,
                    $obj->{SNSDiaryList}->[$idx]->{diaryId} ),
                $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount},
                600
            );
        } 0 .. $#{ $obj->{SNSDiaryList} };
    }
    else {
        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } );
    }
## Modified 2013/10/07.8 END
my $meth_end = [gettimeofday];
#$obj->{TOTALBENCHTIME} = tv_interval $meth_start, $meth_end;

    my $retobj = $self->debug_mode( $obj, $target_memno ? $self->sns_member_data : undef );

    return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => $retobj } );
}


1;
__END__
=pod
	# Build SQL for Diary list BEGIN
	my $sql			= $self->build_base_diary_SQL();
	my $maxrec_sql	= sprintf( "SELECT COUNT(D.c_diary_id) AS MAXREC FROM %s AS D LEFT JOIN %s AS M ON M.c_member_id = D.c_member_id", $c_diary_table, $c_member_table );

	push( @whereSQL, "(D.is_suspend = 0 AND M.is_suspend = 0)" );

	# get data from ikuyo_sns_ignore
	push( @whereSQL, sprintf("D.c_member_id NOT IN(
           SELECT CASE
               WHEN target_c_member_id = ? THEN c_member_id
               WHEN c_member_id = ? THEN target_c_member_id
               ELSE 0
             END AS ignore_c_member_id
           FROM %s
             WHERE target_c_member_id= ? OR c_member_id= ?
		)", $ikuyo_sns_ignore_table)
	);
	push( @placeholder, $c_member_id, $c_member_id, $c_member_id, $c_member_id );


## Build search condition for WHERE SQL BEGIN

  # getting diary list of my friend
	if ('friend' eq $target_memno) {
		push( @whereSQL, sprintf("D.c_member_id IN( SELECT F.c_member_id_to FROM %s AS F WHERE c_member_id_from = ? )", $c_friend_table) );
		push( @placeholder, $c_member_id );
	}
=cut
=pod
    ## Modified 2013/09/20 Modify Step to Build SQL
    ## First of all get ignore list into array @ignore_c_member_ids
    ## Second of all get friend list into array @friend_c_member_ids
    ## Finally push the array record to Main SQL

    # Build SQL for Diary list BEGIN
    #my $sql        = $self->build_base_diary_SQL({NO194PROFILE => 1 });

## Modified 2013/10/05 
    my $sql        = $self->build_base_diary_SQL({ NOBODYNO194PROFILE => 1 });
    my $maxrec_sql = sprintf( "SELECT COUNT(D.c_diary_id) AS MAXREC FROM %s AS D LEFT JOIN %s AS M ON M.c_member_id = D.c_member_id", $c_diary_table, $c_member_table );

    push( @whereSQL, "(D.is_suspend = 0 AND M.is_suspend = 0)" );

    # get data from ikuyo_sns_ignore
    my $prepare_sql;
    $prepare_sql = sprintf("SELECT CASE
 WHEN target_c_member_id = ? THEN c_member_id
 WHEN c_member_id = ? THEN target_c_member_id
 ELSE 0
 END AS ignore_c_member_id
  FROM %s
   WHERE target_c_member_id= ? OR c_member_id= ?", $ikuyo_sns_ignore_table);

    my $ignore_c_member_ids = $self->dbhR->{DBHandle}->selectcol_arrayref( $prepare_sql, undef, $c_member_id, $c_member_id, $c_member_id, $c_member_id );
    push( @whereSQL, sprintf("D.c_member_id NOT IN(%s)", join(',', @{ $ignore_c_member_ids })) ) if $ignore_c_member_ids->[-1];

  # getting diary list of my friend
    if ('friend' eq $target_memno) {
        $prepare_sql = sprintf("SELECT
 F.c_member_id_to
 FROM %s AS F
  WHERE c_member_id_from = ? ", $c_friend_table);

        my $friend_c_member_ids = $self->dbhR->{DBHandle}->selectcol_arrayref( $prepare_sql, undef, $c_member_id );

        $friend_c_member_ids->[-1]
            ?
        push( @whereSQL, sprintf("D.c_member_id IN(%s)", join(',', @{ $friend_c_member_ids })) )
            :
        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } )
        ;
    }
    else {
  # 指定会員の日記リスト取得の場合 target_memnoを条件にc_member_idを取得する
  # memnoが無い場合でfilter_areaが指定されてる場合：
  #    3の場合はパラメータのikuyo_area_idで地域を設定
  #    2もしくは以外は自分のセッション情報のarea_idを地域に設定
        if ($target_memno) {
        # 指定会員の情報を取得
            $self->sns_member_data_by_memno( $target_memno, ( ( $ikuyo_area_code && 0 < $ikuyo_area_code ) ? $ikuyo_area_code : $areaid ) );
            my $target_c_member_id = $self->sns_member_data->{sns_member_id};
            push( @whereSQL,    " M.c_member_id = ?" );
            push( @placeholder, $target_c_member_id );
        }
        else {
            if ( $filter_area && 1 < $filter_area ) {
                if (3 == $filter_area && 0 < $ikuyo_area_code) {
                    push( @whereSQL,    "M.ikuyo_area_code = ?" );
                    push( @placeholder, prefid2areacode($ikuyo_area_code) );
                } else {
                    push( @whereSQL,    "M.ikuyo_area_id = ?" );
                    push( @placeholder, $areaid  );
                }
            }
        }

        if ( defined($adult_flag) ) {
            push( @whereSQL,    2 == $adult_flag ? "D.category = ?" : "( D.category = ? OR D.category = 0 )");
            push( @placeholder, $adult_flag );
        }

        if ( defined($open_areas) && 30 != $open_areas ) {
            push( @whereSQL,    'POW(2, 0+D.public_flag) & ?' );
            push( @placeholder, $open_areas );
        }

        if ($conditions) {
            my $search_keywords = $self->emoji_unicode_2_emoji_docomo( { in_out => 'IN', type => 'sns', text => $conditions } );
            $multicondition     = sprintf( "*W1,2 %s ", $search_keywords );
            push( @whereSQL, 'MATCH(D.subject, D.body) AGAINST(? IN BOOLEAN MODE)' );
            push( @placeholder, $multicondition );
        }
    }

    $sql .= sprintf( " %s%s",
        ( 0 < @whereSQL ? "WHERE " : "" ),
        join( ' AND ', @whereSQL ) );
    $sql .= " ORDER BY D.c_diary_id DESC";
    $sql .= sprintf( " LIMIT %d, %d", $offset, $condition_limit );

    $maxrec_sql .= sprintf( " %s%s",
        ( 0 < @whereSQL ? "WHERE " : "" ),
        join( ' AND ', @whereSQL ) );

    # 日記リストsql生成 END
    $self->dbhR->setEncodeFrom('utf8');
    $self->dbhR->setEncodeTo('utf8');
    $obj->{SNSDiaryList} = $self->dbhR->executeReadPlus(
        'DBServerSNSDiary',
        'stage194master',
        'c_diary',
        $areaid,
        $memno,
        $sql, undef,
        {
            placeholder => [ @placeholder ]
        },
    );

	# 日記データがある
    if ( defined( $obj->{SNSDiaryList} ) ) {
        if ( $record_limit < scalar @{ $obj->{SNSDiaryList} } ) {
            $obj->{offset2nex} =
                ( 0 < $offset )
              ? ( $offset + $condition_limit - 1 )
              : $record_limit;    # if $record_limit == $obj->{maxrec};

            pop @{ $obj->{SNSDiaryList} };
        }

        $obj->{offset}     = $offset;
        $obj->{offset2pre} = ( $offset - $condition_limit + 1 ) if $record_limit <= $offset;
        $obj->{count}      = $record_limit;

        $sql = sprintf("SELECT COUNT(c_diary_comment_id) AS receivedCommentCount FROM %s WHERE c_diary_id = ? AND is_suspend = 0;", $c_diary_comment_table );
        my $sth = $self->dbhR->{DBHandle}->prepare($sql);
        # to get data from ikuyo_profile
        my $sql194profile = sprintf("SELECT IK.gender AS targetSex, IK.age AS targetAge, IK.play_city AS targetPlayCity FROM %s AS IK WHERE IK.c_member_id = ?;", $ikuyo_profile_table);
        ## set server connections beforehand
        $self->set_db_server_connection( qw/SERVER_PREFIX_IKUYOBBS SERVER_PREFIX_REIKUYO SERVER_PREFIX_GEO/ );

        map {
            my $idx = $_;
            $sth->execute( $obj->{SNSDiaryList}->[$idx]->{diaryId} );
            ( $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount} ) = $sth->fetchrow_array();

            ($obj->{SNSDiaryList}->[$idx]->{targetSex}, $obj->{SNSDiaryList}->[$idx]->{targetAge}, $obj->{SNSDiaryList}->[$idx]->{targetPlayCity}) = $self->dbhR->{DBHandle}->selectrow_array($sql194profile, undef, $obj->{SNSDiaryList}->[$idx]->{snsMemberId});
        ## convert prefcode to master.xml pref id
            $obj->{SNSDiaryList}->[$idx]->{targetPrefCode} = areaCode2MasterID($obj->{SNSDiaryList}->[$idx]->{targetPrefCode});

# 2013/08/28  uda  プロフ画像取得の際の会員情報をターゲット会員から参照者に変更
            # プロフィール画像取得
            my $tmp = $self->get_getImageUrl( {
#                member_data => {
#                                  memno            => $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
#                                  areaid            => $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
#                                  sns_member_id    => $obj->{SNSDiaryList}->[$idx]->{snsMemberId},
#                },
                member_data => {
                            memno         => $memno,
                            areaid        => $areaid,
                            sns_member_id => $c_member_id,
                },
                type        => 1,
                id_for_type => $obj->{SNSDiaryList}->[$idx]->{snsMemberId},
                flag        => 1,
            } );
###
            my $imageUrl  = 'pictureUrl';
            map {
                $obj->{SNSDiaryList}->[$idx]->{ $imageUrl  . ($_+1) } = $tmp->[$_]->{image_url};
            } 0..$#{ $tmp };

        ## get the value of is_suspend
            my $isSuspend = $self->get_getSuspendOfDiaryImageFile(
                        {
                            memno           => $memno,
                            areaid          => $areaid,
                            sns_member_id   => $c_member_id,
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
                    memno       => $obj->{SNSDiaryList}->[$idx]->{targetMemNo},
                    areaid      => $obj->{SNSDiaryList}->[$idx]->{targetAreaId},
                    distanceOff => 1,
                }
            );

            map { $obj->{SNSDiaryList}->[$idx]->{$_} = $icondata_ref->{$_} } keys %{$icondata_ref};

            # 絵文字処理
            $obj->{SNSDiaryList}->[$idx]->{targetName}    = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{targetName} } );
            #$obj->{SNSDiaryList}->[$idx]->{diary}        = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diary} } );
            $obj->{SNSDiaryList}->[$idx]->{diaryTitle}    = $self->emoji_unicode_2_emoji_docomo( { in_out => 'OUT', text => $obj->{SNSDiaryList}->[$idx]->{diaryTitle} } );
    ## Modified 2013/09/20 No need to escape (Appication handles it)
            #$self->cgi->charset('utf-8');
            #$obj->{SNSDiaryList}->[$idx]->{targetName}    = $self->cgi->escapeHTML($obj->{SNSDiaryList}->[$idx]->{targetName});
            #$obj->{SNSDiaryList}->[$idx]->{diary}        = $self->cgi->escapeHTML($obj->{SNSDiaryList}->[$idx]->{diary});
            #$obj->{SNSDiaryList}->[$idx]->{diaryTitle}    = $self->cgi->escapeHTML($obj->{SNSDiaryList}->[$idx]->{diaryTitle});

            # キャッシュ処理：コメント数をキャッシュに追加
            $self->sns_memcached_write->set(
                sprintf( "%s%d",
                    $memcached_key_base,
                    $obj->{SNSDiaryList}->[$idx]->{diaryId} ),
                $obj->{SNSDiaryList}->[$idx]->{receivedCommentCount},
                600
            );
        } 0 .. $#{ $obj->{SNSDiaryList} };
    }
    else {
        return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => { maxrec => 0, message => 'RESULT : 0 HIT' } } );
    }

    my $retobj = $self->debug_mode( $obj, $target_memno ? $self->sns_member_data : undef );

    return ( { api_name => $self->_myCallerMethodName->{sub_class_name}, dataobject => $retobj } );
}
=cut
