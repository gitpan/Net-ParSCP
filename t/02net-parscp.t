use warnings;
use strict;

our $totaltests;
BEGIN { $totaltests = 27; }
use Test::More tests => $totaltests;

BEGIN { use_ok('Net::ParSCP') };

#########################

SKIP: {
  skip("Developer test", $totaltests-1) unless ($ENV{DEVELOPER} && -x "script/parpush" && ($^O =~ /nux$/));

     my $output = `script/parpush -v 'orion:.bashrc beowulf:.bashrc' europa:/tmp/bashrc.@# 2>&1`;
     like($output, qr{scp\s+beowulf:.bashrc\s+europa:.tmp.bashrc.beowulf}, 'using macro for source machine: remote target');
     like($output, qr{scp\s+orion:.bashrc europa:/tmp/bashrc.orion}, 'using macro for source machine: remote target');
     ok(!$?, 'macro for source machine: status 0');

     $output = `script/parpush -n =europa -v MANIFEST  beo-europa:/tmp/@# 2>&1`;
     ok(!$?, 'macro from local to remote: status 0');
     like($output, qr{scp  MANIFEST beowulf:/tmp/europa}, 'using -n =europa and macro from local machine: remote target');
     like($output, qr{scp  MANIFEST orion:/tmp/europa}, 'using -n  =europa and macro from local machine: remote target');

     $output = `script/parpush -v MANIFEST  beo-europa:/tmp/@# 2>&1`;
     ok(!$?, 'macro from local to remote: status 0');
     like($output, qr{scp  MANIFEST beowulf:/tmp/localhost}, 'using macro from local machine: remote target');
     like($output, qr{scp  MANIFEST orion:/tmp/localhost}, 'using macro from local machine: remote target');

     $output = `script/parpush -n localhost=orionbashrc -v orion:.bashrc :/tmp/@= 2>&1`;
     ok(!$?, 'macro target from remote to local: status 0');
     like($output, qr{scp -r orion:.bashrc /tmp/orionbashrc}, 'using -n localhost=orionbashrc with target macro to local machine');

     $output = `script/parpush -n orion=orionbashrc -v orion:.bashrc :/tmp/@# 2>&1`;
     ok(!$?, 'macro source with -n from remote to local: status 0');
     like($output, qr{Executing system command:\s+scp -r orion:.bashrc /tmp/orionbashrc}, 'using -n orion=orionbashrc with source macro to local machine');

     $output = `script/parpush -n orion=ORION -n beowulf=BEO -v 'orion:.bashrc beowulf:.bashrc' europa:/tmp/bashrc.@# 2>&1`;
     ok(!$?, 'macro for source with 2 -n options: status 0');
     like($output, qr{scp  beowulf:.bashrc europa:/tmp/bashrc.BEO}, 'macro for source with 2 -n options: correct command 1');
     like($output, qr{scp  orion:.bashrc europa:/tmp/bashrc.ORION}, 'macro for source with 2 -n options: correct command 2');
     
     $output = `script/parpush -n orion=ORI -n beowulf=BEOW -v 'orion:.bashrc beowulf:.bashrc' :/tmp/bashrc.@# 2>&1`;
     ok(!$?, 'macro for source with 2 -n options (to local): status 0');
     like($output, qr{scp -r beowulf:.bashrc /tmp/bashrc.BEOW}, 'macro for source with 2 -n options (to local): correct command 1');
     like($output, qr{scp -r orion:.bashrc /tmp/bashrc.ORI}, 'macro for source with 2 -n options (to local): correct command 2');
     ok(-e '/tmp/bashrc.BEOW', '/tmp/bashrc.BEOW remote file transferred');
     ok(-e '/tmp/bashrc.ORI', 'remote file transferred');

     $output = `script/parpush -h`;
     ok(!$?, 'help: status 0');
     like($output, qr{Name:\s+parpush - Secure transfer of files via SSH},'help:Name');
     like($output, qr{Usage:\s+parpush}, 'help: Usage');
     like($output, qr{Options:\s+--configfile file}, 'help:Options');
     like($output, qr{--xterm}, 'help: xterm option');
}



