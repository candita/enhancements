#!/bin/bash

set -o pipefail
set -x

SECONDS_PER_DAY=86400
REPORT_FILE=$(date +%F).md
DAYSBACK="$1"

if [ -z "$DAYSBACK" ]; then
    # Look for files that appear to start with a year and include
    # month and day as well (have a "-" in the name after the year) to
    # avoid the annual summary files. Also ignore the report we're
    # working on today, in case there is a preview version of that
    # file present from an earlier run. Then take the last file in the
    # list and remove the ".md" suffix to give us the date the file
    # was created.
    latest=$(basename $(ls -1a this-week/ \
                            | grep '^20[[:digit:]][[:digit:]]-' \
                            | grep -v $REPORT_FILE \
                            | tail -n 1) .md)
    latest_num=$(expr $(date --date "${latest}" "+%s") / $SECONDS_PER_DAY )
    today_num=$(expr $(date "+%s") / $SECONDS_PER_DAY )
    DAYSBACK=$(expr ${today_num} - ${latest_num})
fi

(cd ./tools; go run ./main.go report --days-back $DAYSBACK) > this-week/${REPORT_FILE}
