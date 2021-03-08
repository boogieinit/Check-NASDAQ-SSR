#!/bin/bash
#
# CheckSSR.sh
#	
#	Pull SSR list from NASDAQ, interrogate for owned positions, notify
#
#	Sheduled cron to run weekdays at 5am CT (supress emails)
#	Cron: 0 5 * * 1-5	/home/[USER]/bin/QuerySSR.sh	>/dev/null 2>&1
#
# Changelog:
# 20210227 - 	Created.
# 20210306 - 	Changed wget to curl. Now sending hits as attachment
# 20210307 - 	Added pre-flight check
# 20210308 - 	optional to send results in body or as attachment (still in progress)
# 		Added perl line to clean up $HITS so it can be cat'd into an email
# 
#
# Info:
# NASDAQ URL: https://nasdaqtrader.com/dynamic/symdir/shorthalts/shorthaltsYYYYMMDD.txt
# The file is created by NASDAQ about 5am ET each day but can also be created after market close.
#
#
# Requires:
#	List of ticker symbols to look for  (one ticker per line)
#		file: /home/[USER]/cooking/QuerySSR/positions.txt
#	User dir for the executable
#		dir:  /home/[USER]/bin/






############################################
# Config
############################################

# User config
WRKDIR=/home/creeves/cooking/stonks/CheckSSR  # created automatically
MAILTO=crdaytrading@gmail.com

# How do you want "hits" emailed?
# (0=in body, 1=as attachment)
SENDSTYLE=1


# ----------------------------------------------- #
# -------------- DO NOT EDIT BELOW -------------- #
# ----------------------------------------------- #


# Global config
TODAY=$(date +%Y%m%d)


#######################
# Weekend testing - manually set date for non-market days
#TODAY=20210305
#######################


MAINURL="https://www.nasdaqtrader.com/trader.aspx?id=ShortSaleCircuitBreaker"
FILEBASE="https://www.nasdaqtrader.com/dynamic/symdir/shorthalts"
SSRFILE=shorthalts$TODAY.txt
FILEURL=$FILEBASE/$SSRFILE
HITS=$WRKDIR/hits.txt
STOCKS=$WRKDIR/positions.txt

REQPKGS="mailx sendmail curl"
MAILSUBJECT="Positions found on SSR"


function preflight_check {
	# am I root?
	[[ $UID -eq 0 ]] && echo "Can't be root!" && exit 1

	# Have required packages?
	for pkg in $REQPKGS ; do
		if ! rpm -qa | grep  $pkg > /dev/null ; then
			echo "$pkg is required...install and try again!"
			exit 1
		fi
	done

	# Got ticker list?
	if ! [ -f $STOCKS ] ; then
		echo "$STOCKS not found...create it and try again!"
		echo ; exit 1
	fi
}

function getfile {
	mkdir -p $WRKDIR
	cd $WRKDIR
	# meaningless curl on $MAINURL first to pass 'SAMEORIGIN' req for the file pull
	curl $MAINURL >/dev/null 2>&1 && curl -silent $FILEURL > $SSRFILE
}


function search {
	# was it denied due to too many hits on the site
	if grep "SAMEORIGIN" $SSRFILE > /dev/null ; then
		echo  | mail -s "Could not pull SSR file" $MAILTO
		exit 1
	fi
	
	for n in `cat $STOCKS` ; do
		grep $n $SSRFILE >> $HITS
	done
}


function notify {
	if [ -s "$HITS" ] ; then
		if [ $SENDSTYLE -eq "1" ] ; then
			echo "See attached" | mail -a $HITS -s "$MAILSUBJECT" $MAILTO

		elif [ $SENDSTYLE -eq "0" ] ; then
			perl -p -e 's/\r\n/\n/g' $HITS > $HITS.$$
#			perl -pi -e 's/\r\n/\n/g' $HITS > $HITS.$$
			cat $HITS.$$ | mail -s "$MAILSUBJECT" $MAILTO
			rm -f $HITS.$$
		fi
	fi
}


#function notify {   # list in body method
#	if [ -s "$HITS" ] ; then
#	perl -pi -e 's/\r\n/\n/g' $HITS
#	cat $HITS | mail -s "Positions on SSR" $MAILTO
#	fi
#}



####################################################
# doit
####################################################
preflight_check
getfile
search
notify

# Cleanup
rm -f $SSRFILE
rm -f $HITS
