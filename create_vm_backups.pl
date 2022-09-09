#!/usr/bin/perl -w
#
# Author: Lars Vogdt
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the Novell nor the names of its contributors may be
#   used to endorse or promote products derived from this software without
#   specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

use strict;
use warnings;
use Carp;
use Config::Simple;
use Getopt::Long;
use POSIX qw(strftime);
use Pod::Usage;

my %machines;
my $logfile="/tmp/create_virsh_backup.log";
my $backupdir='/home/backup/vms';
my $config='/etc/create_vm_backup.conf';
my $pid=$$;
my $loglevel=3;
my $verbose=0;
my $print_help='';
my %conf;

sub logfile($$) {
    my ($action,$conf) = @_;
    if (("$action" eq "open" ) || ("$action" eq "new" )) {
        open (LOGFILE, ">>$conf{'logfile'}") || warn "Couldn't open $conf{'logfile'} !\n";
        flock(LOGFILE,2)             || warn "Can't get lock for $conf{'logfile'} !\n";
    } else {
        close LOGFILE;
    }
}

sub LOG {
  my $message = shift;
  my $level   = shift || 0;
  my $time = localtime(time);
  print "DEBUG: $message\n" if ($verbose);
  if ( $level <= $loglevel ) {
      print LOGFILE "[$time] [$pid] $message\n";
  }
}

sub getVmPartitions($){
	my ($name)=@_;
	open(BLOCK,"virsh domblklist $name |") or carp "Failed to run virsh domblklist command : $!\n";
	my %blocks;
	while (<BLOCK>){
		next if /^Target/;
		next if /^----/;
		next if (/^\s*$/);
		my ($name,$id,$foo)=split('\s+', $_);
		$blocks{$name}=$id;
	}
	return \%blocks;
}

sub read_config($){
	my ($file)=@_;
	my @keys=qw(backupdir verbose loglevel logfile vm);
	my %config;
	my $cfg = new Config::Simple("$file") or croak "Could not open $file : $!\n";
	for my $key (@keys) {
		if ( defined( $cfg->{'_DATA'}{'default'}{$key}[0] )){
			$config{$key}=$cfg->{'_DATA'}{'default'}{$key}[0];
		}
	}
	# exclude_disk holds more than one value: get the complete array
	if ( defined( $cfg->{'_DATA'}{'default'}{'exclude_disk'})){
		$config{'exclude_disk'}=$cfg->{'_DATA'}{'default'}{'exclude_disk'};
	}
	return(%config);
}

###############################################################################
# Main
###############################################################################

Getopt::Long::Configure('bundling','pass_through');

GetOptions(
    'c=s'            => \$config,
    'config=s'       => \$config,
    'h'              => \$print_help,
    'help'           => \$print_help,
    'v|verbose'      => \$verbose,
    'l=i'            => \$loglevel,
    'loglevel=i'     => \$loglevel,
);

pod2usage(  -exitstatus => 0,
            -verbose => 1,  # 2 to print full pod
         ) if $print_help;

if (-r "$config" ){
	%conf=read_config($config);
}

if (defined($loglevel)){
	$conf{'loglevel'}=$loglevel;
}

if (defined($verbose)){
	$conf{'verbose'}=$verbose;
}

if (defined($ARGV[0]) && ( "$ARGV[0]" ne "")){
    foreach my $machine (@ARGV) {
        $machines{$machine}{'name'}= "$machine";
    }
}
elsif (defined($conf{'vm'}) && ("$conf{'vm'}" ne "")){
  foreach my $machine ($conf{'vm'}){
        $machines{$machine}{'name'}= "$machine";
  }
}
else {
  open(VMS,"virsh list --name|") or die "Could not get list of virtual machines : $!\n";
  while (<VMS>){
	next if (/^\s*$/);
	chomp;
	$machines{$_}{'name'}= "$_";
  }
  close(VMS);
}

foreach my $vm (keys %machines){
	$machines{$vm}{'blockids'}=getVmPartitions($vm);
}

if ($verbose){
	use Data::Dumper;
	print "Current configuration contains:\n";
	print STDERR Data::Dumper->Dump([\%conf]);
	print "Commandline options:\n";
	print STDERR Data::Dumper->Dump([\@ARGV]);
	print "I have the following information about the VMs:\n";
	print Dumper([\%machines]);
}

logfile('open',\%conf);
my $date=strftime "%Y-%m-%d", localtime;
my $fullbackupdir="$backupdir/$date";
use Data::Dumper;
print Data::Dumper->Dump([$conf{'exclude_disk'}]);

foreach my $vm (keys %machines){
	LOG("Creating backup directory: $fullbackupdir/$vm",2);
	`mkdir -p $fullbackupdir/$vm`;
	LOG("Dumping XML data for machine $vm",3);
	`virsh dumpxml $vm > $fullbackupdir/$vm/$vm.xml`;
	foreach my $blockid (keys(%{$machines{$vm}->{'blockids'}})){
		my $lvname=$machines{$vm}{'blockids'}{$blockid};
		if ( my ($matched) = grep $_ eq $lvname, @{ $conf{'exclude_disk'} }){
			LOG("Skipping $lvname, as it is excluded via exclude_disk parameter in $config");
			next;
		}
		LOG("Creating LVM snapshot for $vm - $blockid",3);
		LOG("lvcreate -s -L 2G -n $vm-snap $lvname",4);
		my $snapshotname="${vm}-snap-${blockid}";
		`lvcreate -s -L 2G -n $snapshotname $lvname`;
		LOG("Creating backup image in $fullbackupdir/$vm/$blockid.img",4);
		my ($foo,$dev,$vgname,$part)=split(/\//,$lvname);
		if ( -x '/usr/bin/xz'){
##			`cat $machines{$vm}{'blockids'}->{$blockid} > $fullbackupdir/$vm/$blockid.img`;
			`dd status=none if=/$dev/$vgname/$vm-snap-$blockid | xz > $fullbackupdir/$vm/$blockid.img.xz`;
		}
		else {
			LOG "xz not found - could not compress the image\n";
			`cat /$dev/$vgname/$snapshotname > $fullbackupdir/$vm/$blockid.img`;
		}
		LOG("Removing LVM snapshot",4);
		`lvremove -f /$dev/$vgname/$snapshotname`;
	}
}
logfile('close',\%conf);

__END__

=head1 Create backups of virtual machines

Create backups of virtual machines managed by libvirt and running on LVM volumes.

=head1 SYNOPSIS

./create_vm_backups.pl [OPTIONS] [machine1] [machine2] [...]

=head1 OPTIONS

=over 8

=item B<--config> F<file> | B<-c> F<file>

Use configfile F<file> (FIXME: not implemented yet).

=item B<--help> | B<-h>

This output.

=item B<--debug> | B<-d>

Print debugging information.

=back

=head1 DESCRIPTION

This script creates a Live-Backup via lvm snapshot from virtual machines running on the host.

In general, the script works like this:

=over 8
 
=item Get list of running machines

virsh list

=item Create an XML dump of the machines

virsh dumpxml $machine

=item Create a LVM snapshot of the used volumes

lvcreate -s -L 2G -n $machine-snap /dev/vg1/$machine

=item Dump the snapshot into a local file (might take time!)

cat /dev/vg1/$machine-snap > $blockid-name.img

=item Remove the snapshot 

lvremove -f /dev/vg1/$machine-snap

=back

=head1 RESTORE

If you want to restore the backup, just have a look in the (sub-)directory of your backup directories with the 
machine name. Here you should find the images and the xml:

=over 8

=item Restore file systems

(repeat for all image files):
cat $backupdir/$blockid-name.img > /dev/vg1/$machine

=item Re-create the virtual machine

virsh define $backupdir/$machine.xml

=back

=head1 AUTHORS

This script was written by Lars Vogdt <lars@linux-schulserver.de> for own purposes, but maybe used by others.

=cut

