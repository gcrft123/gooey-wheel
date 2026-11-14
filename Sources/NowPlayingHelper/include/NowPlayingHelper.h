#ifndef NOW_PLAYING_HELPER_H
#define NOW_PLAYING_HELPER_H

/// Reports what is playing, one JSON object per line on standard output, until standard input
/// closes. Each line of standard input is a MediaRemote command number to send to the app
/// playing. Never returns.
///
/// It runs inside /usr/bin/perl, which loads this library: since macOS 15.4 MediaRemote only
/// answers processes signed by Apple, and perl is one that can load a library of ours. The
/// idea comes from ungive/mediaremote-adapter (BSD-3-Clause).
void gooey_now_playing_run(void);

#endif
