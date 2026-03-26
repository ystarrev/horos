#!/usr/bin/perl

use strict;
use File::Copy;
use File::Basename;
use File::Path qw(make_path);
my $destination = "$ENV{TARGET_BUILD_DIR}/$ENV{PUBLIC_HEADERS_FOLDER_PATH}";

make_path($destination) unless -d $destination;
open my $horos_h, ">", "$destination/Horos.h" or die $!;

print {$horos_h} "#ifndef __Horos_API\n#define __Horos_API\n\n";

my @fromdirs = ( "$ENV{PROJECT_DIR}/Nitrogen/Sources", "$ENV{PROJECT_DIR}/Nitrogen/Sources/JSON", "$ENV{PROJECT_DIR}/Horos/Sources" );
# TODO: "$ENV{PROJECT_DIR}/cocoahttpserver",

print STDERR "API-Headers.pl debug\n";
print STDERR "TARGET_BUILD_DIR=$ENV{TARGET_BUILD_DIR}\n";
print STDERR "PUBLIC_HEADERS_FOLDER_PATH=$ENV{PUBLIC_HEADERS_FOLDER_PATH}\n";
print STDERR "DESTINATION=$destination\n";
print STDERR "PROJECT_DIR=$ENV{PROJECT_DIR}\n";

foreach my $root (@fromdirs) {
    opendir(DIR, $root);
    
    my @files = readdir(DIR);
    foreach (@files) {
        my $filename = $_;
        next unless -f "$root/$filename" && $filename =~ /\.h$/s;
        print STDERR "Copying $root/$filename -> $destination/".(basename $filename)."\n";
        copy("$root/$filename", "$destination/".(basename $filename))
            or die "Copy failed for $root/$filename: $!";
        print {$horos_h} "#include <Horos/$filename>\n";
    }
    
    closedir(DIR);
}

print {$horos_h} "\n#endif\n";
close $horos_h;

chdir "$ENV{TARGET_BUILD_DIR}/$ENV{FULL_PRODUCT_NAME}";
unlink "Headers" if -e "Headers" || -l "Headers";
symlink "Versions/Current/Headers", "Headers" or die "Failed to create Headers symlink: $!";

exit 0;
