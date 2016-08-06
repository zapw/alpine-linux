#!/usr/bin/env perl
use strict;
use warnings;
use List::Util qw(first);
use File::Fetch;
use File::Copy;
use File::Path 'remove_tree';
use File::Temp;
use Archive::Tar;
use Scalar::Util 'reftype';
use Cwd;


open my $fh, '/etc/apk/repositories' or die $!;
my $url;

while (<$fh>) {
  $url = $1 and last if (m#://(.+/alpine)/v[\d\.]+/main\Z#);
}

sub mypopd (+@);

my @dirs;
mypopd @dirs, getcwd, File::Temp::tempdir( CLEANUP => 1 );

my $ff = File::Fetch->new(uri => "http://$url" . "/latest-stable/main/x86/APKINDEX.tar.gz");
my $apkindex = $ff->fetch( to => $dirs[-1] ) or die $ff->error;

Archive::Tar->extract_archive($apkindex) or die $Archive::Tar::error;

open my $apkindex_fh, 'APKINDEX';

my $latest_ver;
while (<$apkindex_fh>) {
        if (/\AP:alpine-base\Z/ ... /\AV:[\d\.]+/ and /\AV:[\d\.]+/) {
           $latest_ver = join '.',(split /(?:V:|\.)/)[1,2];
           last;
        }
}

seek $fh,0,0;
close $apkindex_fh;

open my $fh_back, '>', '/etc/apk/repositories.bak' or die $!;

while (<$fh>) {
  s#(?<=/alpine/)v[\d\.]+(?=/\w+\Z)#v$latest_ver#;
  print $fh_back $_;
}
close $_ for $fh,$fh_back;

move("/etc/apk/repositories.bak","/etc/apk/repositories") or die $!;
system('apk', 'upgrade' ,'--update-cache', '--available');

open my $lbu_conf, '/etc/lbu/lbu.conf' or die $!;
my $media;
while (<$lbu_conf>) {
  $media = $1 and last if /LBU_MEDIA=(.+)\b/;
}
close $lbu_conf;

system('mount', '-oremount,rw' ,"/media/$media") == 0
        or die $?;

my @packages = qw/linux-grsec linux-grsec-dev xtables-addons-grsec linux-firmware/;
system('apk', 'fetch' ,@packages) == 0
        or die $?;

system('mount', '-t', 'tmpfs', '-oremount,size=2G' ,'/') == 0
        or die $?;

my @filenames = <*.apk>;
print "Extracting:\n";
for (@filenames) {
          print " $_\n";
  Archive::Tar->extract_archive($_) or die $Archive::Tar::error;
}

move("$_","$_" . '.old') for glob
            "{/media/$media/boot/}{System.map-grsec,config-grsec,grsec,grsec.gz,grsec.modloop.squashfs,vmlinuz-grsec}";


system("apk", "add", 'git') == 0
        or die $?;

my $rtlwifi_new = 'https://github.com/lwfinger/rtlwifi_new';
system("git", "clone", $rtlwifi_new) == 0
        or die $?;

my $linux_ver = <lib/modules/*-grsec>;
mypopd @dirs, 'rtlwifi_new';

system("make") == 0
        or die $?;

copy($_, "../lib/modules/$linux_ver/kernel/drivers/net/wireless/realtek/rtlwifi/$_")
        for <*.ko rtl8192cu/*.ko btcoexist/*.ko>;

mypopd @dirs;
copy($_, "/media/$media/$_") for <boot/*>;
move("lib/firmware", "lib/modules/firmware");

my $linux_headers = glob 'usr/src/linux-headers*';
remove_tree('/' . $linux_headers) if defined $linux_headers;
move("usr/src","/usr/src");

system("mksquashfs", "lib/", "/media/$media/boot/grsec.modloop.squashfs", '-comp', 'xz') == 0
        or die $?;

mypopd @dirs;

system("umount", "-l", '/.modloop/') == 0
        or die $?;

system("mount", "/media/$media/boot/grsec.modloop.squashfs", '/.modloop/') == 0
        or die $?;

my $kernel_ver = first { m#\A/.modloop/modules/[\d\.-]+grsec\Z# } </.modloop/modules/*>;
system('mkinitfs', '-F "ata base bootchart cdrom squashfs ext2 ext3 ext4 floppy raid scsi usb virtio"' ,'-o',
          "/media/$media/boot/grsec.gz", substr "$kernel_ver",18) == 0
        or die $?;

undef @dirs;

system @{$_->{command}} for { command => ['sync'] }, { command => ['lbu','ci'] };
unlink '/etc/issue';

system('mount', '-oremount,ro' ,"/media/$media") == 0
        or die $?;

sub mypopd (+@) {
        my $aref = shift;
        die "Not an array or arrayref" unless reftype $aref eq 'ARRAY';
        @_ ? push @$aref, @_ : pop @$aref;

        chdir $aref->[-1] or die $@;
}