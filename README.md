# CheckSSR
Bash script to pull the NASDAQ Short Sale Restriction list, check for any open positions, and notify via email if any positions are found to be on the list.
You need to populate a list of tickers to check against the SSR list.
This should be a scheduled task so you get the updated file each morning just after market open in order to capture tickers form the previous day but also any that were restricted at market open.
You will not get a file pull and email on the weekends.

For MacOS only
