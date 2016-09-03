#!/bin/bash
#
# moviecrunch.sh
#
# Recompresses a DVD rip from MPEG2 straight off the disc to something in the
# MP4 family of containers, preferably using h.264 encoding to do some serious
# squeezins.
#
# This script is designed to be driven from `xargs`, and as such, will not
# do any parallelization on its own. You have been warned.

#
# Sanity checks
#

# Do we have the required software installed?
BINS=(mplayer ffmpeg)
for bin in ${BINS[@]}; do
    which $bin 2> /dev/null > /dev/null
    if [[ "$?" != "0" ]]; then
        echo "Binary $bin not found, exiting."
        exit 1
    fi
done

# Only *one* filename on the command line for processing.
if [[ "$#" != "1" ]]; then
	echo "Only one file at a time."
	exit 1
fi

# Does the file we want to process even exist?
if [[ ! -s "$1" ]]; then
	echo "File: $1 doesn't appear readable, wtf."
	exit 2
fi

# Sleep for a random number of seconds to prevent race conditions
sleep $(( $RANDOM % 10 ))

BN=$(basename "$1" .mpg)
DN=$(dirname "$1")
BASE="${DN}/${BN}"

# Does a lock file exist?
LOCK="${BASE}.lock"
echo "Checking for lock file at: $LOCK"
if [[ -f "${LOCK}" ]]; then
    echo "Lock file exists. exiting."
    exit 3
else
        echo "Locking: $1"
    echo $$ > "${LOCK}"
fi

#
# Automatic crop detection
#

# Does a pre-existing file with crop parameters already exist?
CROPFILE="${BASE}.crop"
if [[ -s "${CROPFILE}" ]]; then
	CROP=$(cat "${CROPFILE}")
else
	# nope, better start crop-detecting.  And since this is kind of a gnarly
	# expression, let me break it down here...
	# * mplayer
	#   -vf cropdetect :: Tells mplayer to run the cropdetect video filter.  It should
	#                     use the reasonable defaults for the limit, roud and reset
	#                     parameters.  Especially since we're not touching files with
	#                     channel logos in it.
	#   -sstep 600     :: Skip 600 frames every frame.  This basically fast forwards through
    #                     the movie, so you should look at frames from the entire sequence,
    #                     one frame every 10 minutes.
	#   -vo null       :: Don't bother trying to output any video during detection.
	#   -nosound       :: Don't bother trying to output any audio during detection.
	#
	# * egrep -o -- '\(.*\).$'      :: Capture only the values output by mplayer during capture.
	# * sed -r -e 's/(\(|\)|\.)//g' :: Remove the parenthesis from the output.
	# * sort | uniq -c | sort -nr   :: Tally the votes for the output, sorting by the most commonly detected.
	# * head -1                     :: Pick the most popular. This, I imagine, would be the most accurate.
	# * awk '{print $3}'            :: Only output the actual crop parameters.
	#
	# The end result output looks something like this: 'crop=720:480:0:0' (it used to prepend '-vf ', but
	# I decided against using `mencoder` for the final encoding, opting for `ffmpeg` instead).
	mplayer -vf cropdetect -sstep 100 -vo null -nosound "$1" 2>/dev/null | egrep -o -- '\(.*\).$' | sed -r -e 's/(\(|\)|\.)//g' | sort | uniq -c | sort -nr | head -1 | awk '{print $3}' > "${CROPFILE}"
	if [[ "$?" != 0 ]]; then
		echo "Crop detection failed for $1"
		exit 4
	fi
	CROP=$(cat "${CROPFILE}")
fi

#
# ENCODING!!!!  (This is the big one and should take the lion's share of the CPU time)
#

echo "Encoding: $1"

# *n.b.:* the purpose of -passlogfile here is to make sure that >1 copies of
# this utility working in the same directory at once, don't stomp all over
# Eachother's 2-pass log files.

# First pass (write out to /dev/null, no audio encoding at all)
BITRATE="700k"
ffmpeg -y -i "$1" -threads 1 -filter:v "$CROP" -c:v libx264 -preset slow -b:v $BITRATE -pass 1 -passlogfile "${BASE}" -an -f mp4 /dev/null 2> /dev/null
if [[ "$?" != 0 ]]; then
	echo "Failed on first pass of $1"
	exit 5
fi

# Second pass (write out to actual file)
ffmpeg -y -i "$1" -strict -2 -threads 1 -filter:v "$CROP" -c:v libx264 -preset slow -b:v $BITRATE -pass 2 -passlogfile "${BASE}" -c:a aac -b:a 144k -f mp4 "${BASE}.mp4" 2> /dev/null
if [[ "$?" != 0 ]]; then
	echo "Failed on second pass of $1"
	exit 6
else
	echo "Successfully 2-pass encoded: $1"
	exit 0
fi

