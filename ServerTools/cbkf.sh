#!/bin/sh

# make file/directory copy with timestamp
# if -c option is given make copy with compression

while getopts "c:" opts
do
	case $opts in
		c)
			with_compression=1
			target=$OPTARG
			echo "copying $target with compression"
			;;
	esac
done

if [ -z $with_compression ]
then
	target=$1
fi


if [ -e $target ]
then
	if [ -f $target ]
	then
		if [ -z $with_compression ]
		then
			cp $target $target.$(date +%Y%m%d)
		else
			tar czf $target.$(date +%Y%m%d).tar.gz $target
		fi
	elif [ -d $target ]
	then
		if [ -z $with_compression ]
		then
			cp -R $target $target.$(date +%Y%m%d)
		else
			tar czf $target.$(date +%Y%m%d).tar.gz $target
		fi
	fi
else
	echo "$target NOT FOUND"
fi

exit 0

