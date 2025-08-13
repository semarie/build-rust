#!/bin/ksh -eu
#
#  Copyright (c) 2024 Anthony Bocci <anthony.bocci+buildrust@protonmail.com>
#
#  Permission to use, copy, modify, and distribute this software for any
#  purpose with or without fee is hereby granted, provided that the above
#  copyright notice and this permission notice appear in all copies.
#
#  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
#  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
#  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
#  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
#  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
PATH=/bin:/usr/bin:/usr/sbin:/usr/local/bin
current_script=$(basename $0)

# Display usage information
usage() {
    echo "Find beta or nightly rustc packages"
    echo ""
    echo "Usage: $current_script <month> [<year>] [<first-day>] [<target>]"
    echo "<month> is the month to check. Example: 03 for March."
    echo "<year> is the year to check. Example 2024. Default to the current year."
    echo "<first-day> is the first day of the month to try. Default to 1."
    echo "<target> is either beta or nightly. Default to beta."
}

if [ "$#" -lt 1 ]; then
    usage
    exit 0
fi

month="$(($1+0))"
year=$(date '+%Y')
first_day=1
target=beta
last_day=31

if [ "$#" -gt 1 ]; then
    year="$(($2+0))"
fi

if [ "$#" -gt 2 ]; then
    first_day="$(($3+0))"
fi

if [ "$#" -gt 3 ]; then
    target="$4"
fi

# Ensure arguments are numbers
if [[ $month -eq 0 ]] || [[ $year -eq 0 ]] || [[ $first_day -eq 0 ]]; then
    usage
    exit 1
fi

tmp_dir="/tmp/build-rust-archives"
archive_name="rustc-$target-src.tar.gz"
extracted_dir="rustc-$target-src"
mkdir -p $tmp_dir

# Loop over each day of the given month / year and check if an archive exists
for day in $(seq $first_day 1 $last_day); do
    day_str=$(printf "%02d" $day)
    month_str=$(printf "%02d" $month)
    url="https://static.rust-lang.org/dist/$year-$month_str-$day_str"

    http_response=$(curl -s -I "$url/$archive_name")
    status_code=$(echo $http_response | head -n 1 | cut -d' ' -f2)
    # Get the remote file length. Grep behaves strangely with \r\n, so they
    # are replaced with \n. One is added at the end of the input, otherwise
    # grep doesn't capture the last line.
    remote_file_length=$(echo "$http_response\n" | tr '\r\n' '\n' | grep -i 'content-length' | cut -d' ' -f2)
    remote_file_length=$(($remote_file_length + 0))
    # There is no archive at this URL, skip this day
    if [ $status_code != '200' ]; then
	continue
    fi
    out_dir="$tmp_dir/$year-$month_str-$day_str"
    mkdir -p $out_dir
    cd "$out_dir"

    # If the archive file is there but incomplete, remove it
    # It happens when the download is interrupted
    if [ -f $archive_name ]; then
	local_file_length=$(stat -f '%z' $archive_name)
	local_file_length=$(($local_file_length + 0))
	if [ $local_file_length -lt $remote_file_length ]; then
	    rm "$archive_name"
	fi
    fi

    # Download the archive only if it's not already there
    if [ ! -f $archive_name ]; then
	echo "Downloading $url/$archive_name at $out_dir/$archive_name..."
	curl -s -o "$archive_name" "$url/$archive_name"
    fi

    if [ ! -d $extracted_dir ]; then
	echo "Extracting version file from $archive_name..."
	tar -xzf "$archive_name" "$extracted_dir/version"
    fi

    if [ -f "$extracted_dir/version" ]; then
	rustc_version=$(cat "$extracted_dir/version")
	echo -e "$rustc_version, $url\n"
    fi
done
