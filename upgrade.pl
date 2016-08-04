use strict;
use warnings;
use List::Util qw(first);
use File::Fetch;
use File::Copy;
use File::Temp;
use Archive::Tar;
use Cwd;


open my $fh, '/etc/apk/repositories' or die "$!";
my $url;

while (<$fh>) {
  $url = $1 and last if (m#://(.+/alpine)/v[\d\.]+/main\Z#);
}
 

my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
my $old_dir = getcwd;
chdir $tmpdir;

my $ff = File::Fetch->new(uri => "http://$url" . "/latest-stable/main/x86/APKINDEX.tar.gz");
my $apkindex = $ff->fetch( to => $tmpdir ) or die $ff->error;

my $tar_apkindex = Archive::Tar->new;

$tar_apkindex->read($apkindex);
$tar_apkindex->extract();

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

open my $fh_back, '>', '/etc/apk/repositories.bak' or die "$!";

while (<$fh>) {
  s#(?<=/alpine/)v[\d\.]+(?=/\w+\Z)#v$latest_ver#;
  print $fh_back $_;
}

close $_ for $fh,$fh_back;

move("/etc/apk/repositories.bak","/etc/apk/repositories") or die "$!";

system('apk', 'upgrade' ,'--update-cache', '--available');

open my $lbu_conf, '/etc/lbu/lbu.conf' or die "$!";

my $media;
while (<$lbu_conf>) {
  $media = $1 and last if /LBU_MEDIA=(.+)\b/;
}

close $lbu_conf;

system('mount', '-oremount,rw' ,"/media/$media") == 0
        or die "$?";


my @packages = qw/linux-grsec xtables-addons-grsec linux-firmware/;
system('apk', 'fetch' ,@packages) == 0
        or die "$?";
        

my @filenames = <*.apk>;

move("$_","$_" . '.old') for glob 
            "{/media/$media/boot/}{System.map-grsec,config-grsec,grsec,grsec.gz,grsec.modloop.squashfs,vmlinuz-grsec}";

my $tar = Archive::Tar->new;
print "Extracting:\n";
for (@filenames) { 
  print " $_\n";
  $tar->read("$_");
  $tar->extract();
}

my @boot_files = <boot/*>;
copy("$_", "/media/$media/$_") for @boot_files;
move("lib/firmware", "lib/modules/firmware");


system("mksquashfs", "lib/", "/media/$media/boot/grsec.modloop.squashfs", '-comp', 'xz') == 0
        or die "$?";

system("umount", "-l", '/.modloop/') == 0
        or die "$?";

system("mount", "/media/$media/boot/grsec.modloop.squashfs", '/.modloop/') == 0
        or die "$?";

my $kernel_ver = first { m#\A/.modloop/modules/[\d\.-]+grsec\Z# } </.modloop/modules/*>;
system('mkinitfs', '-F "ata base bootchart cdrom squashfs ext2 ext3 ext4 floppy raid scsi usb virtio"' ,'-o',
          "/media/$media/boot/grsec.gz", substr "$kernel_ver",18) == 0
        or die "$?";

chdir $old_dir;
undef $tmpdir;

system @{$_->{command}} for { command => ['sync'] }, { command => ['lbu','ci'] };
unlink '/etc/issue';

system("umount", "-l", '/.modloop/') == 0
        or die "$?";
        
system('mount', '-oremount,ro' ,"/media/$media") == 0
        or die "$?";
        
system("mount", "/media/$media/boot/grsec.modloop.squashfs", '/.modloop/');