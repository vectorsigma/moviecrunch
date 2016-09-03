# MovieCrunch

This small little utility's main purpose in life is to help go from straight
MPEG2 DVD rips (good quality, way too much disk space) to MPEG4 movies using
h.264 encoding (still pretty good quality, 70% less disk space).

While simply encoding one movie into another in and of itself is trivial,
doing so en masse, with automated crop detection and parallelism control is
non-trivial.

If you happen to have a *lot* of files that fit this bill, you want to bring
all of your cores to bear upon it, hence the need for "Fire and forget" 
capability of things like crop detection and not accidentally doing the same
work twice.

## One file at a time...

The utility itself will only operate one file at a time.  All parallelism will
be controlled outside, probably by some combination of `find` or `ls -1` and
`xargs -Pn -n 1`.  At least for groups of files already grouped by directory,
say, a given season of a TV show.  At that point, there's a natural break for
splitting work up between physical machines, where one machine could work on
dir1 and the other could work on dir2.

But if you need to operate on files in the same directory, you must develop a
way to signal from one app to another "hey, this file's mine, step off."

There are 2 basic concurrent programming methodologies from which all others
flow, at least from my experience (and a [fantastic talk](https://www.socallinuxexpo.org/sites/default/files/presentations/2015-scale-13.pdf) at SCaLE13x):

1. shared, mutable state
2. message passing

I chose 1.  Because the only signal I need to communciate between machines is
"this file is in the process of being encoded."  And that signal is as simple
as the presence of a lock file named the same as the file's basename with a
different extension. 

Of course, this presumes that the filesystem itself has become the shared,
mutable state in this paradigm.  To that end, every remote system must be
working off of the same filesystem. Either via NFS, or whatever distributed
or clustered filesystem you choose.

But this is better than writing some "web-scale" abomination with python,
redis, oh and a blockchain, etc. ...

### Invocation

Assuming you're in the directory you want to be in:

```
find -type f -name "*.mpg" -print0 | xargs -0 -P $(grep ^processor /proc/cpuinfo | wc -l) -n 1 -iblah ./moviecrunch.sh "blah"
```

### Assumptions: File names, formats, meaning, etc.

All of the original files are `*.mpg`, and `basename *.mpg` will be used to
prefix all of the working filenames.

* Lock files will be `basename.lock`
* Crop parameters will be `basename.crop`
* Transcoded video will be `basename.avi`

The reason to keep these files, is that it's possible that the auto-detected
parameters for cropping will be wrong.  You might want to be able to review
each encoded film, and make sure that nothing got, well, obviously missed.

With the detection code as it is, you can manually edit any screw ups, and
then re-encode skipping the problematic crop detection for hand-edited files.

### Automatic crop selection

Using `mencoder`s `-crop-detect` feature is the first step.  This gives a
format identical to what `ffmpeg` expects.

The first trick will be estimating *where* the best place to do crop detection
is in a given stream.  This is non-trivial.  You need to have what would appear
to be the brightest possible frames for say, 10 seconds, to get the best 
result without accidentally making a file that's too small.  Well, in short,
that's a tough thing to do without analyzing every frame.

So what's done here, is that we pick every say, 100th frame, run the crop
detection algorithm, and output to disk.  Once that's done, over the whole
stream, we simply count the detected values, sort, and choose the most
popular crop.

Lastly, this tool might have to be run a second time on a file.  There can
exist a case where the `basename.crop` file exists, but the `basename.lock`
file does not.  In this case, the auto-detection should shortcut and use the
pre-existing file.  That file has likely been hand edited to ensure that it
is correct.

### Not stepping on eachother's toes

The next question to solve is how to make sure one process doesn't do anything
stupid.  Specifically, to not re-encode the same file more than once.  And
to do that, each script is going to have to be smart enough to see if a file
it's being asked to encode has been done already.

The simple solution here is lock files.  If a $FILE.lock exists, just exit.

Now, you might think that `xargs` can manage the parallelism entirely on its
own, so why the hell are you even thinking about this in this manner?  Well,
xargs scales to the number of cores on a single machine.  Someone might have
one directory that they'll need all cores (local and remote) working together
to get it done in a reasonable amount of time.

Each machine will get the same list of files to start from.  So what we have
then is a race condition for which remote system will get the first file in
the directory.  So to prevent stupidity like that, when the utility first
starts up, there will be a random sleep value between 1 and 10 seconds to help
each script back off each other.

### Performance

A brief test with the `threads=6` parameter showed that ffmpeg is not at all
efficient at spreading the encoding load for a single video over multiple
cores.  So the decision was made early on to use only single threaded mode,
and to encode multiple movies at once.  This makes the best use of all
cores that are available.
