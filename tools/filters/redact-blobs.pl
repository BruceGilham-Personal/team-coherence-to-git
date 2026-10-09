# Content filter for TCMigrator --filter: redacts secrets in every blob before it reaches git.
#
#   TCMigrator ... --filter D:\migration\scrub\redact-blobs.pl
#
# Put this file next to a rules.pl of your own. rules.pl must define
#
#   sub redact { my ($ref, $counts) = @_; ... }
#
# which edits the scalar $$ref in place and adds 1 to $counts->{<rule name>} for each change.
# The rules are yours and stay out of this repository: they describe what your secrets look
# like. Write them to replace each secret with characters of the SAME length, so binaries
# that carry a secret keep their layout.
#
# TCMigrator runs this once per batch with one argument: a list file of "<input>TAB<output>"
# lines. Each input is read as bytes, redacted, and written to its output. Only counts are
# printed - never a value.
use strict; use warnings;
# rules.pl from this script's own folder. Not FindBin: Git for Windows' perl, given the
# script as a Windows path (C:\...), resolves FindBin to the current folder instead.
my $dir = $0;
$dir =~ s{[\\/][^\\/]*$}{} or $dir = '.';
require "$dir/rules.pl";

my $list = shift or die "usage: perl redact-blobs.pl <list file>\n";
open my $lf, '<:encoding(UTF-8)', $list or die "list: $!\n";
my ($files, $changed, %counts) = (0, 0);
while (my $line = <$lf>) {
  $line =~ s/[\r\n]+$//;
  next if $line eq '';
  my ($in, $out) = split /\t/, $line, 2;
  die "bad list line\n" unless defined $out;
  open my $i, '<:raw', $in or die "read $in: $!\n";
  local $/; my $data = <$i>; close $i;
  $data = '' unless defined $data;
  my $n = length $data;
  my %c; redact(\$data, \%c);
  # rules that change a length would shift every byte after them in a binary
  die "a rule changed the length of $in\n" if length($data) != $n;
  if (%c) { $changed++; $counts{$_} += $c{$_} for keys %c; }
  open my $o, '>:raw', "$out.partial" or die "write $out: $!\n";
  print $o $data; close $o or die "write $out: $!\n";
  rename "$out.partial", $out or die "rename $out: $!\n";
  $files++;
}
printf "%d file(s), %d redacted%s\n", $files, $changed,
  join('', map { "; $_ x$counts{$_}" } sort keys %counts);
