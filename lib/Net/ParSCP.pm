package Net::ParSCP;
use strict;
use warnings;

use Set::Scalar;
use IO::Select;
use Pod::Usage;
#use Sys::Hostname;

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(
  parpush
  exec_cssh
  help
  version
  usage 
  $VERBOSE
  $DRYRUN
);

our $VERSION = '0.11';
our $VERBOSE = 0;
our $DRYRUN = 0;

# Create methods for each defined machine or cluster
sub create_machine_alias {
  my %cluster = @_;

  my %method; # keys: machine addresses. Values: the unique name of the associated method

  no strict 'refs';
  for my $m (keys(%cluster)) {
    my $name  = uniquename($m);
    *{__PACKAGE__.'::'.$name} = sub { 
      $cluster{$m} 
     };
    $method{$m} = $name;
  }

  return \%method;
}

# Return an array with the relevant lines of the config file
sub read_configfile {
  my $configfile = $_[0];


  if (defined($configfile) && -r $configfile) {
    open(my $f, $configfile);
    my @desc = <$f>;
    chomp(@desc);
    return @desc;
  }

  # Configuration file not found. Try with ~/.csshrc of cssh
  $configfile = $_[0] = "$ENV{HOME}/.csshrc";
  if (-r $configfile) {
    open(my $f, $configfile);

    # We are interested in lines matching 'option = values'
    my @desc = grep { m{^\s*(\S+)\s*=\s*(.*)\s*} } <$f>;
    close($f);
    chomp(@desc);

    my %config = map { m{^\s*(\S+)\s*=\s*(.*)\s*} } @desc;

    # Get the clusters. It starts 'cluster = ... '
    my $regexp = $config{clusters};

    # create regexp (^beo\s*=)|(^be\s*=)
    $regexp =~ s/\s*(\S+)\s*/(^$1\\s*=)|/g;
    $regexp =~ s/[|]\s*$//;

    # Select the lines that correspond to clusters
    return grep { m{$regexp}x } @desc;
  }

  usage('Error. Configuration file not found!') unless -r $configfile;
}

############################################################
sub parse_configfile {
  my $configfile = $_[0];
  my %cluster;

  my @desc = read_configfile($_[0]);

  for (@desc) {
    next if /^\s*(#.*)?$/;

    my ($cluster, $members) = split /\s*=\s*/;
    die "Error in configuration file $configfile invalid cluster name $cluster" unless $cluster =~ /^[\w.]+$/;

    my @members = split /\s+/, $members;

    for my $m (@members) {
      die "Error in configuration file $configfile invalid name $m" unless $m =~ /^[\@\w.]+$/;
      $cluster{$m} = Set::Scalar->new($m) unless exists $cluster{$m};
    }
    $cluster{$cluster} = Set::Scalar->new(@members);
  }

  # keys: machine and cluster names; values: name of the associated method 
  my $method = create_machine_alias(%cluster); 

  return (\%cluster, $method);
}

############################################################
sub version {
  my $errmsg = shift;

  print "Version: $VERSION\n";
  pod2usage(
    -verbose => 99, 
    -sections => "AUTHOR|COPYRIGHT AND LICENSE", 
    -exitval => 0,
  );
}


############################################################
sub usage {
  my $errmsg = shift;

  warn "$errmsg\n";
  pod2usage(
    -verbose => 99, 
    -sections => "NAME|SYNOPSIS|OPTIONS", 
    -exitval => 1,
  );
}

sub help {
  pod2usage(
    -verbose => 99, 
    -sections => "NAME|SYNOPSIS|OPTIONS", 
    -exitval => 0,
  );
}


############################################################
{
  my $pc = 0;

  sub uniquename {
    my $m = shift;

    $m =~ s/\W/_/g;
    $pc++;
    return "_$pc"."_$m";
  }
}

sub exec_cssh {
  my @machines = @_;

  my $csshcommand  = 'cssh ';
  $csshcommand .= "$_ " for @machines;
  warn "Executing system command:\n\t$csshcommand\n" if $VERBOSE;
  my $pid;
  exec("$csshcommand &");
  die "Can't execute cssh\n";
}

sub warnundefined {
  my ($configfile, @errors) = @_;

  local $" = ", ";
  my $prefix = (@errors > 1) ?
      "Machine identifiers (@errors) do"
    : "Machine identifier (@errors) does";
  warn "$prefix not correspond to any cluster or machine defined in ".
       " cluster description file '$configfile'.\n";
}

sub non_declared_machines {
  my $configfile = shift;
  my $clusterexp = shift;
  my %cluster = @_;

  my @unknown;
  my @clusterexp = $clusterexp =~ m{([a-zA-Z_][\w.\@]*)}g;
  if (@unknown = grep { !exists($cluster{$_}) } @clusterexp) {
    warnundefined($configfile, @unknown) if $VERBOSE;
  }
  return @unknown;
}

sub wait_for_answers {
  my $readset = shift;
  my %proc = %{shift()};

  my $np = keys %proc; # number of processes
  my %output;
  my @ready;

  my %result;
  for (my $count = 0; $count < $np; ) {
    push @ready, $readset->can_read unless @ready;
    my $handle = shift @ready;

    my $name = $proc{0+$handle};

    unless (defined($name) && $name) {
      warn "Error. Received message from unknown handle\n";
      $name = 'unknown';
    }

    my $partial = '';
    my $numBytesRead;
    $numBytesRead = sysread($handle,  $partial, 65535, length($partial));

    $output{$name} .= $partial;

    if (defined($numBytesRead) && !$numBytesRead) {
      # eof
      if ($VERBOSE) {
        print "$name output:\n";
        $output{$name} =~ s/^/$name:/gm if length($output{$name});
        print "$output{$name}\n";
      }
      $readset->remove($handle);
      $count ++;
      if (close($handle)) {
        $result{$name} = 1;
      }
      else {
        warn $! ? "Error closing scp to $name $!\n" 
                : "Exit status $? from scp to $name\n";
        print "$output{$name}\n" unless $VERBOSE;
        $result{$name} = 0;
      }
    }
  } 
  return \%result;
}

# Find out what source machines are involved 
# %source is returned. machine => [ paths ]
# key '' represents the local machine
{
  my $nowhitenocolons = '(?:[^\s:]|\\\s)+'; # escaped spaces are allowed

  sub parse_sourcefile {
    my $sourcefile = shift;

    my @externalmachines = $sourcefile =~ /($nowhitenocolons):($nowhitenocolons)/g;
    my @localpaths = $sourcefile =~ /(?:^|\s) # begin or space
                                     ($nowhitenocolons)
                                     (?:\s|$) # end or space
                                    /xg;
    
    my %source;
    $source{''} = \@localpaths if @localpaths; # '' is the local machine
    while (my ($clusterexp, $path) = splice(@externalmachines, 0, 2)) {
      if (exists $source{$clusterexp} ) {
        push @{$source{$clusterexp}}, $path;
      }
      else {
        $source{$clusterexp} = [ $path ]
      }
    }
    return %source;
  }
}

# Autodeclare unknown machine identifiers
sub translate {
  my ($configfile, $clusterexp, $cluster, $method) = @_;

  my @unknown = non_declared_machines($configfile, $clusterexp, %$cluster);
  my %unknown = map { $_ => Set::Scalar->new($_)} @unknown;
  %$cluster = (%$cluster, %unknown); # union
  %$method = (%$method, %{create_machine_alias(%unknown)});

  $clusterexp =~ s/(\w[\w.\@]*)/$method->{$1}()/g;
  my $set = eval $clusterexp;

  unless (defined($set) && ref($set) && $set->isa('Set::Scalar')) {
    $clusterexp =~ s/_\d+_//g;
    $clusterexp =~ s/[()]//g;
    warn "Error. Expression '$clusterexp' has errors. Skipping.\n";
    return;
  }
  return $set;
}

# Gives the same value for entries $entry1 and $entry2 
# in the hash referenced by $rh
sub make_synonymous {
  my ($rh, $entry1, $entry2, $defaultvalue) = @_;

  if (exists $rh->{$entry1}) {
    $rh->{$entry2} = $rh->{$entry1} 
  }
  elsif (exists $rh->{$entry2}) {
    $rh->{$entry1} = $rh->{$entry2};
  }
  else { 
    $rh->{$entry1} =  $rh->{$entry2} = $defaultvalue;
  }
}

sub spawn_secure_copies {
  my %arg = @_;
  my $readset = $arg{readset};
  my $configfile = $arg{configfile};
  my $destination = $arg{destination};
  my @destination = ref($destination)? @$destination : $destination;
  my %cluster = %{$arg{cluster}};
  my %method = %{$arg{method}};
  my $scp = $arg{scp} || 'scp';
  my $scpoptions = $arg{scpoptions} || '';
  my $sourcefile = $arg{sourcefile};
  my $name = $arg{name};

  # hash source: keys: source machines. values: lists of source paths for that machine
  my (%pid, %proc, %source);

  my $sendfiles = sub {
    my ($m, $cp) = @_;

    # @= is a macro and means "the name of the target machine"
    my $targetname = exists($name->{$m}) ? $name->{$m} : $m;
    $cp =~ s/@=/$targetname/g;

      # @# stands for source machine: decompose transfer
      for my $sm (keys %source) {
        my $sf = $sm? "$sm:@{$source{$sm}}" : "@{$source{$sm}}"; # $sm: source machine
        my $fp = $cp;                   # $fp: path customized for this source machine

        # what if it is $sm eq '' the localhost?
        my $sn = $sm;
        $sn = $name->{$sm} if (exists $name->{$sm});
        $fp =~ s/@#/$sn/g;

        my $target = ($m eq 'localhost')? $fp : "$m:$fp";
        warn "Executing system command:\n\t$scp $scpoptions $sf $target\n" if $VERBOSE;
        unless ($DRYRUN) {
          my $pid = open(my $p, "$scp $scpoptions $sf $target 2>&1 |");
          if (exists $pid{$m}) {
            push @{$pid{$m}}, $pid;
          }
          else {
            $pid{$m} = [ $pid ];
          }

          warn "Can't execute scp $scpoptions $sourcefile $target", next unless defined($pid);

          $proc{0+$p} = $m;
          $readset->add($p);
        }
      }
  };

  # '' and 'localhost' are synonymous
  make_synonymous($name, '', 'localhost', 'localhost');

  $VERBOSE++ if $DRYRUN;

  # @# stands for the source machine: decompose the transfer, one per source machine
  %source = parse_sourcefile($sourcefile); #  if "@destination" =~ /@#/;

  # expand clusters in sourcefile
  for my $ce (keys %source) {
    next unless $ce; # go ahead if local machine
    my $set = translate($configfile, $ce, \%cluster, \%method);

    # leave it as it is if is a single node
    next unless $set->members > 1;

    my $paths = $source{$ce};
    $source{$_} = $paths for $set->members;
    delete $source{$ce};
  }

  for (@destination) {

    my ($clusterexp, $path);
    unless (/^([^:]*):([^:]*)$/) {
      warn "Error. Destination '$_' must have no more than one colon (:). Skipping transfer.\n";
      next;
    }

    if ($1) {  # There is a target machine
      ($clusterexp, $path) = split /\s*:\s*/;

      my $set = translate($configfile, $clusterexp, \%cluster, \%method);
      next unless $set;

      $sendfiles->($_, $path) for ($set->members);

    }
    else { # No target cluster: target is the local machine
      $path = $2;
      $scpoptions .= '-r';
      $sendfiles->('localhost', $path);
    }
  } # for @destination

  return (\%pid, \%proc);
}

sub parpush {
  my %arg = @_;

  my ($cluster, $method) = parse_configfile($arg{configfile});

  my $readset = IO::Select->new();

  # $proc is a hash ref. keys: memory address of some IO stream. 
  # Values the name of the assoc. machine. 
  # $pid is a hash ref
  # keys: machine names. Values: process Ids
  my ($pid, $proc) = spawn_secure_copies(
    readset => $readset, 
    cluster => $cluster,
    method => $method,
    %arg,
  );

  my $okh = {};
  $okh = wait_for_answers($readset, $proc) unless $DRYRUN;;

  return wantarray? ($okh, $pid) : $okh;
}

1;

__END__
