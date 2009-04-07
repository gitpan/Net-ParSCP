use warnings;
use strict;
use Test::More tests => 4;
BEGIN { use_ok('Net::ParSCP') };

#########################

SKIP: {
  skip("Developer test", 3) unless ($ENV{DEVELOPER} && -x "script/parpush" && ($^O =~ /nux$/));

     my $output = `script/parpush -v 'orion:.bashrc beowulf:.bashrc' europa:/tmp/bashrc.@# 2>&1`;
     like($output, qr{scp\s+beowulf:.bashrc\s+europa:.tmp.bashrc.beowulf}, 'using macro for source machine: remote target');
     like($output, qr{scp\s+orion:.bashrc europa:/tmp/bashrc.orion}, 'using macro for source machine: remote target');
     ok(!$?, 'macro for source machine: status 0');

}



