# CheckSSR
Bash script to pull the NASDAQ Short Sale Restriction list, check for any open positions, and notify via email if any positions are found to be on the list.
You need to populate a list of tickers to check the SSR list against.
This should be scheduled in crontab so you get the updated file each morning by pre-market open.
NASDAQ only updated this file prior to US market open days. For example: You will not get a file pull on a Saturday because the file availablre will not match the $DATE variable in the script.

Requires:
  Sendmail
  Mailx
  Curl
  bash
  

**BUGS:**
The option for putting the "hits" in the body of the notification email vs sending as an attachment is not eworking due to line endings on the grep output.
I'm testing fixing it with a perl one-liner (or tr).
