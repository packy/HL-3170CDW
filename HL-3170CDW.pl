#!/usr/bin/env perl
use strict;
use warnings;
use v5.10;

use Data::Dumper::Concise;
use File::stat;
use HTTP::Client;
use List::Util qw{ sum };
use Storable;

my $data_file = shift @ARGV;
my $command   = shift @ARGV;

if (my($host, $max_age) = $command =~ m{refresh\[([^\]]+)\]\[([^\]]+)\]}) {
  # if there's non-numeric data in $data_max_age
  if ($max_age =~ /\D/) {
    $max_age = dhms2sec($max_age);
  }

  exit if -f $data_file && (time - stat($data_file)->mtime < $max_age);

  refresh_data($host);
  exit;
}

die "$data_file not found!\n"
  unless -f $data_file;

my $data = retrieve($data_file);

if ($command eq 'dump') {
  print Dumper($data);
}
elsif (my($get) = $command =~ m{get\[(.+)\]}) {
  my @keys = split /\]\[/, $get;
  my $ptr = $data;
  my @breadcrumbs;
  foreach my $key ( @keys ) {
    if ( ref($ptr) eq 'HASH' ) {
      if (exists $ptr->{$key}) {
        if (ref($ptr->{$key}) eq 'HASH' ||
            ref($ptr->{$key}) eq 'ARRAY') {
          $ptr = $ptr->{$key};
          push @breadcrumbs, $key;
          next;
        }
        print $ptr->{$key};
        last;
      }
    }
    elsif ( ref($ptr) eq 'ARRAY' && $key =~ /^\d+$/ ) {
      if (ref($ptr->[$key]) eq 'HASH' ||
          ref($ptr->[$key]) eq 'ARRAY') {
        $ptr = $ptr->[$key];
        push @breadcrumbs, $key;
        next;
      }
      print $ptr->[$key];
      last;
    }
    my $crumbs = join '][', @breadcrumbs, $key;
    die "ERROR: no key [$crumbs]\n"
  }
}
else {
  say "UNKNOWN COMMAND: $command";
}

#
# functions
#

sub key_sub {
  my $key = shift;
  return 'total' if ($key eq 'Total Paper Jams' || $key eq 'Total');
  return 'Hagaki/Japanese Postcard/4R' if ($key eq 'Hagaki');
  return 'Paper Feeding Kit 1' if ($key eq 'PF Kit 1');
  $key =~ s/Drum\s*//;
  $key =~ s/\s*Unit\s*//;
  return $key;
}

sub dhms2sec {
  my $sec = 0;
  my $string = shift;
  if ($string =~ /(\d+)\s*s/) { $sec += $1; }
  if ($string =~ /(\d+)\s*m/) { $sec += $1 * 60; }
  if ($string =~ /(\d+)\s*h/) { $sec += $1 * 3600; }
  if ($string =~ /(\d+)\s*d/) { $sec += $1 * 86400; }
  if ($string =~ /(\d+)\s*w/) { $sec += $1 * 604800; }
  return $sec;
}

sub refresh_data {
  my $host     = shift;
  my $url      = "http://$host/etc/mnt_info.csv";
  my $client   = HTTP::Client->new();
  my $response = $client->get($url);

  my($header_line, $value_line) = split /\n/, $response;
  my @headers = map { substr($_, 0, 1, ''); substr($_, -1, 1, ''); $_} split /,/, $header_line;
  my @values  = map { substr($_, 0, 1, ''); substr($_, -1, 1, ''); $_} split /,/, $value_line;
  my $data = {};

  foreach my $i (0 .. $#values) {
    my $header = $headers[$i];
    my $value  = $values[$i];
    my $key;
    if (($key) = $header =~ /Remaining Life\(([^\)]+)\)/) {
      $key = key_sub($key);
      $data->{units}{$key}{'Remaining Life'} = $value;
    }
    elsif (($key) = $header =~ /% of Life Remaining\(([^\)]+)\)/) {
      $key = key_sub($key);
      if ($key =~ /Toner/) {
        $key =~ s/Toner\s*//;
        $data->{toner}{$key}{'Remaining Life %'} = $value;
      }
      else {
        $data->{units}{$key}{'Remaining Life %'} = $value;
      }
    }
    elsif (($key) = $header =~ /Replace Count\(([^\)]+)\)/) {
      $key = key_sub($key);
      if ($key =~ /Toner/) {
        $key =~ s/\s*Toner//;
        $data->{toner}{$key}{'Replace Count'} = $value;
      }
      else {
        $data->{units}{$key}{'Replace Count'} = $value;
      }
    }
    elsif (($key) = $header =~ /Page Counter (.+)/) {
      $data->{counts}{page}{$key} = $value;
    }
    elsif (($key) = $header =~ /Image Count (.+)/) {
      $data->{counts}{image}{key_sub($key)} = $value;
    }
    elsif (($key) = $header =~ /Drum Count (.+)/) {
      $data->{counts}{drum}{$key} = $value;
    }
    elsif (($key) = $header =~ /Error(\d+)/) {
      $data->{errors}[$key-1]{err} = $value;
    }
    elsif (($key) = $header =~ /Error Count (\d+)/) {
      $data->{errors}[$key-1]{count} = $value;
    }
    elsif ($header =~ m{Plain|Thick|Label|Hagaki|Glossy|Envelopes/}) {
      $data->{counts}{printed}{type}{$header} = $value;
    }
    elsif ($header =~ m{Letter|Legal|Executive|Envelopes|A5|Others}) {
      $data->{counts}{printed}{size}{key_sub($header)} = $value;
    }
    elsif ($header =~ m{Model|Serial|Firmware|Memory|Node|Location|IP Address|Contact}) {
      $data->{info}{$header} = $value;
    }
    elsif ($header =~ m{Jam}) {
      $header =~ s/^Jam\s+//;
      $data->{counts}{jams}{key_sub($header)} = $value;
    }
  }
  foreach my $type (qw/ page drum /) {
    $data->{counts}{$type}{total} = sum(values %{$data->{counts}{$type}});
  }

  store $data, $data_file;
}
