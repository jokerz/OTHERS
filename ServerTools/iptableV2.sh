#*******************************
# @file    /etc/sysconfig/jokerz2-iptables.sh
# @desc    A Script File Configure ipatables
# @create  2012/11/04
#*******************************

#---- ここからがshell script ---------------------------------->

#!/bin/bash

# $Id: jokerz2-iptables.sh,v 1.0 2012/11/04 1:00 ryo Exp $

# Stop FireWall(Make Rules clean)
/etc/init.d/iptables stop

# Name of the Interface
LAN=eth0

# 内部ネットワークのネットマスク取得
LOCALNET_MASK=`ifconfig $LAN|sed -e 's/^.*Mask:\([^ ]*\)$/\1/p' -e d`

# 内部ネットワークアドレス取得
LOCALNET_ADDR=`netstat -rn|grep $LAN|grep $LOCALNET_MASK|cut -f1 -d' '`
LOCALNET=$LOCALNET_ADDR/$LOCALNET_MASK

# 読み込み対象モジュールに必須FTPヘルパーモジュールを追加
sed -i '/IPTABLES_MODULES/d' /etc/sysconfig/iptables-config
echo "IPTABLES_MODULES=\"ip_conntrack_ftp\"" >> /etc/sysconfig/iptables-config

# デフォルトルール(以降のルールにマッチしなかった場合に適用するルール)設定
iptables -P INPUT   DROP   # 受信はすべて破棄
iptables -P OUTPUT  ACCEPT # 送信はすべて許可
iptables -P FORWARD DROP   # 通過はすべて破棄

# SYN Cookiesを有効にする
# ※TCP SYN Flood攻撃対策
sysctl -w net.ipv4.tcp_syncookies=1 > /dev/null
sed -i '/net.ipv4.tcp_syncookies/d' /etc/sysctl.conf
echo "net.ipv4.tcp_syncookies=1" >> /etc/sysctl.conf

# ブロードキャストアドレス宛pingには応答しない
# ※Smurf攻撃対策
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1 > /dev/null
sed -i '/net.ipv4.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
echo "net.ipv4.icmp_echo_ignore_broadcasts=1" >> /etc/sysctl.conf

# ICMP Redirectパケットは拒否
sed -i '/net.ipv4.conf.*.accept_redirects/d' /etc/sysctl.conf
for dev in `ls /proc/sys/net/ipv4/conf/`
do
    sysctl -w net.ipv4.conf.$dev.accept_redirects=0 > /dev/null
    echo "net.ipv4.conf.$dev.accept_redirects=0" >> /etc/sysctl.conf
done

# Source Routedパケットは拒否
sed -i '/net.ipv4.conf.*.accept_source_route/d' /etc/sysctl.conf
for dev in `ls /proc/sys/net/ipv4/conf/`
do
    sysctl -w net.ipv4.conf.$dev.accept_source_route=0 > /dev/null
    echo "net.ipv4.conf.$dev.accept_source_route=0" >> /etc/sysctl.conf
done

# フラグメント化されたパケットはログを記録して破棄
iptables -N LOG_FRAGMENT
iptables -A LOG_FRAGMENT -j LOG --log-tcp-options --log-ip-options --log-prefix '[ipatables FRAGMENT] : '
iptables -A LOG_FRAGMENT -j DROP
iptables -A INPUT -f -j LOG_FRAGMENT

# 外部とのNetBIOS関連のアクセスはログを記録せずに破棄
iptables -A INPUT -s ! $LOCALNET -p tcp -m multiport --dports 135,137,138,139,445 -j DROP
iptables -A INPUT -s ! $LOCALNET -p udp -m multiport --dports 135,137,138,139,445 -j DROP
iptables -A OUTPUT -d ! $LOCALNET -p tcp -m multiport --sports 135,137,138,139,445 -j DROP
iptables -A OUTPUT -d ! $LOCALNET -p udp -m multiport --sports 135,137,138,139,445 -j DROP

# 1秒間に4回を超えるpingはログを記録して破棄
# ※Ping of Death攻撃対策
iptables -N LOG_PINGDEATH
iptables -A LOG_PINGDEATH -m limit --limit 1/s --limit-burst 4 -j ACCEPT
iptables -A LOG_PINGDEATH -j LOG --log-tcp-options --log-ip-options --log-prefix '[ipatables PINGDEATH] : '
iptables -A LOG_PINGDEATH -j DROP
iptables -A INPUT -p icmp --icmp-type echo-request -j LOG_PINGDEATH

# Synフラッド
#iptables -N LOG_SYN-FLOOD
#iptables -A LOG_SYN-FLOOD -m limit --limit 1/s --limit-burst 4 -j RETURN
#iptables -A LOG_SYN-FLOOD -i ppp0 -j LOG --log-level info --log-prefix '[iptables SYN-FLOOD] : '
#iptables -A LOG_SYN-FLOOD -j DROP
#iptables -A INPUT -p tcp --syn -j LOG_SYN-FLOOD
#iptables -A FORWARD -p tcp --syn -j LOG_SYN-FLOOD

# ポートスキャン
iptables -N LOG_PORT-SCAN
iptables -A LOG_PORT-SCAN -m limit --limit 1/s --limit-burst 4 -j RETURN
iptables -A LOG_PORT-SCAN -i ppp0 -j LOG --log-level info --log-prefix '[iptables PORT-SCAN] : '
iptables -A LOG_PORT-SCAN -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j LOG_PORT-SCAN
#iptables -A FORWARD -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j LOG_PORT-SCAN

# 自ホストからのアクセスをすべて許可
iptables -A INPUT -i lo -j ACCEPT

# 内部からのアクセスをすべて許可
iptables -A INPUT -s $LOCALNET -j ACCEPT

# 内部から行ったアクセスに対する外部からの返答アクセスを許可
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 全ホスト(ブロードキャストアドレス、マルチキャストアドレス)宛パケットはログを記録せずに破棄 ※不要ログ記録防止
iptables -A INPUT -d 255.255.255.255 -j DROP
iptables -A INPUT -d 224.0.0.1 -j DROP

# 113番ポート(IDENT)へのアクセスには拒否応答 ※メールサーバ等のレスポンス低下防止
iptables -A INPUT -p tcp --dport 113 -j REJECT --reject-with tcp-reset

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# 各種サービスの設定 BEGIN
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

# SSH 22
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth0 -p tcp -m tcp --dport 22 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth0 -p udp -m udp --dport 22 -j ACCEPT
## My Home
iptables -A INPUT -s 61.26.183.231 -i eth0 -p tcp -m tcp --dport 22 -j ACCEPT
iptables -A INPUT -s 61.26.183.231 -i eth0 -p udp -m udp --dport 22 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 22 -j LOG --log-level 6 --log-prefix "[ipatables SSH] : "
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 22 -j DROP

# HTTP 80
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# OutBand 587
iptables -A INPUT -p tcp --dport 587 -j ACCEPT

# POP 110
iptables -A INPUT -p tcp --dport 110 -j ACCEPT

# SMTP 25
iptables -A INPUT -s 193.168.1.0/255.255.255.0 -i eth0 -p tcp -m tcp --dport 25 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth0 -p udp -m udp --dport 25 -j ACCEPT
## jokerz.org
iptables -A INPUT -s 61.26.183.231 -i eth0 -p tcp -m tcp --dport 25 -j ACCEPT
iptables -A INPUT -s 61.26.183.231 -i eth0 -p udp -m udp --dport 25 -j ACCEPT
## jokerz.org smtproutes
iptables -A INPUT -s 210.197.72.170 -i eth0 -p tcp -m tcp --dport 25 -j ACCEPT
iptables -A INPUT -s 210.197.72.170 -i eth0 -p udp -m udp --dport 25 -j ACCEPT
iptables -A INPUT -s 58.93.255.219 -i eth0 -p tcp -m tcp --dport 25 -j ACCEPT
iptables -A INPUT -s 58.93.255.219 -i eth0 -p udp -m udp --dport 25 -j ACCEPT
## Modified Mobiles smtp servers ipaddress BEGIN 2010/11/15
# DoCoMo BEGINS
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 203.138.180.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 203.138.181.0/2 -j ACCEPT
# AU BEGINS
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 59.135.39.192/26 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 61.117.1.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 61.202.3.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 111.86.156.32/28 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 121.111.227.136/30 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.196.3.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.196.5.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.196.52.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.230.141.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 219.108.158.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 219.125.149.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 220.214.145.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 222.1.136.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 222.15.69.0/24 -j ACCEPT
# SoftBank BEGINS
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 123.108.236.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 202.179.203.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 202.179.204.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.146.60.128/25 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.169.176.0/24 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 210.175.1.128/25 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -s 123.108.239.0/24 -j ACCEPT
## Modified Mobiles smtp servers ipaddress END 2010/11/15
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -j LOG --log-level 4 --log-prefix "[iptables SMTP] : "
iptables -A INPUT -i eth0 -p tcp -m tcp --dport 25 -j DROP

# TELNET 21
iptables -A INPUT -p tcp -m tcp --dport 21 -j DROP
iptables -A INPUT -p udp -m udp --dport 21 -j DROP

# FTP 23
iptables -A INPUT -p tcp -m tcp --dport 23 -j DROP
iptables -A INPUT -p udp -m udp --dport 23 -j DROP

# MySQL 3306
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth1 -p tcp -m tcp --dport 3306 -j ACCEPT
#iptables -A INPUT -s 61.26.183.231 -i eth1 -p tcp -m tcp --dport 3306 -j ACCEPT
iptables -A INPUT -i eth1 -p tcp -m tcp --dport 3306 -j LOG --log-level 6
iptables -A INPUT -i eth1 -p tcp -m tcp --dport 3306 -j DROP
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth1 -p tcp -m tcp --dport 11211 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/255.255.255.0 -i eth1 -p udp -m udp --dport 11211 -j ACCEPT
iptables -A INPUT -i eth1 -p tcp -m tcp --dport 11211 -j LOG --log-level 6
iptables -A INPUT -i eth1 -p tcp -m tcp --dport 11211 -j DROP

iptables -A INPUT -p udp -m udp --dport 137 -j DROP
iptables -A INPUT -p udp -m udp --dport 138 -j DROP
iptables -A INPUT -p tcp -m tcp --dport 139 -j DROP
iptables -A INPUT -p tcp -m tcp --dport 199 -j DROP
iptables -A INPUT -p udp -m udp --dport 161 -j DROP
iptables -A INPUT -p tcp -m tcp --dport 631 -j DROP
iptables -A INPUT -p udp -m udp --dport 631 -j DROP
iptables -A INPUT -p udp -m udp --dport 445 -j DROP
iptables -A INPUT -p tcp -m tcp --dport 445 -j DROP

#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# 各種サービスの設定 END
#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<


# 拒否IPアドレスからのアクセスはログを記録せずに破棄
# ※拒否IPアドレスは/root/deny_ipに1行ごとに記述しておくこと
# 特定のIPアドレスからのメールを拒否する場合もここで指定する
# (/root/deny_ipがなければなにもしない)
if [ -s /root/deny_ip ]; then
    for ip in `cat /root/deny_ip`
    do
        iptables -I INPUT -s $ip -j DROP
    done
fi

# 指定した国からのアクセスはログを記録せずに破棄
# ※COUNTRYLISTにスペース区切りでアクセスを拒否したいCountry Code(ここでは中国と韓国)を指定
# ※各国割当てIPアドレス情報はAPNIC(http://www.apnic.net/)より最新版を取得
# ※Country Codeと国名の対応(例:JP<==>日本) http://www.nsrc.org/codes/country-codes.html#contry%20codes
COUNTRYLIST='CN KR'
wget -q http://ftp.apnic.net/stats/apnic/delegated-apnic-latest
iptables -N OTHERFILTER
iptables -A OTHERFILTER -j DROP
for country in $COUNTRYLIST
do
    for ip in `cat delegated-apnic-latest | grep "apnic|$country|ipv4|"`
    do
        FILTER_ADDR=`echo $ip |cut -d "|" -f 4`
        TEMP_CIDR=`echo $ip |cut -d "|" -f 5`
        FILTER_CIDR=32
        while [ $TEMP_CIDR -ne 1 ];
        do
            TEMP_CIDR=$((TEMP_CIDR/2))
            FILTER_CIDR=$((FILTER_CIDR-1))
        done
        iptables -I INPUT -s $FILTER_ADDR/$FILTER_CIDR -j OTHERFILTER
    done
done
rm -f delegated-apnic-latest

# 上記のルールにマッチしなかったアクセスはログを記録して破棄
iptables -A INPUT -j LOG --log-tcp-options --log-ip-options --log-prefix '[iptables INPUT] : '
iptables -A INPUT -j DROP
iptables -A FORWARD -j LOG --log-tcp-options --log-ip-options --log-prefix '[iptables FORWARD] : '
iptables -A FORWARD -j DROP


# 再起動時にも上記設定が有効となるようにルールを保存
/etc/rc.d/init.d/iptables save

# ファイアウォール起動
/etc/rc.d/init.d/iptables start
