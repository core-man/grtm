#!/usr/bin/perl
#
# perl code for computing Green's functions using GRTM.
#
#      Zhengbo Li and Yunyi Qian

use strict;
my $r0 = 6371.;

#========= default values
my $grt = "../bin/grtm";		# main program of GRTM
my $dt = 0.2;		# sampling interval.
my $smth = 1;		# densify the output samples by a factor of smth.
my $m = 9;		# number of points = 2 ^m.
my $taper = 0.3;	# for low-pass filter, 0-1.
my ($f1,$f2) = (0,0);	# for high-pass filter transition band, in Hz.
my $tb=150;		# num. of samples before the first arrival.
my $deg2km=1;
my $flat=0;		# Earth flattening transformation.
my $r_depth = 0.;	# receiver depth.
my $rdep = "";
my $updn = 0;		# 1=down-going wave only; -1=up-going wave only.
my $kappa = 0;		# the input model 3rd column is vp, not vp/vs ratio.
my $j;
###################################### end of parameter list

my ($model, $s_depth);
# command line options
@ARGV > 1 or die "Usage: grtm.pl -Mmodel/depth[/f_or_k] [-D]  [-Nm/dt/taper] [-Rrdep] distances ...
-M: model name and source depth in km. f triggers earth flattening (off), k indicates that the 3rd column is vp/vs ratio (vp).
    model has the following format (in units of km, km/s, g/cm3):
	thickness vs vp_or_vp/vs [rho Qs Qp]
	rho=0.77 + 0.32*vp if not provided or the 4th column is larger than 20 (treated as Qs).
	Qs=500, Qp=2*Qs, if they are not specified.
	If the first layer thickness is zero, it represents the top elastic half-space.
	Otherwise, the top half-space is assumed to be vacuum and does not need to be specified.
	The last layer (i.e. the bottom half space) thickness should be always be zero.
-D: use degrees instead of km (off).
-N: m is the number of points(2^m).
    dt is the sampling interval ($dt sec).
    taper applies a low-pass cosine filter at fc=(1-taper)*f_Niquest ($taper).
-R: receiver depth ($r_depth).

Examples
* To compute Green's functions up to 5 Hz with a duration of 51.2 s and at a dt of 0.1 s every 5 kms for a 15 km deep source in the HK model, use
grtm.pl -Mhk/15/k -N9/0.1 05 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80
* To compute static Green's functions for the same source, use
grtm.pl -Mhk/15/k -N2 05 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 > st.out
or use
grtm.pl -Mhk/15/k -N1 05 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 > st.out
* To compute Green's functions every 10 degrees for a 10 km deep source in the PREM model.
grtm.pl -Mprem/10/f -D 10 20 30 40 50 60\n";

foreach (grep(/^-/,@ARGV)) {
   my $opt = substr($_,1,1);
   my @value = split(/\//,substr($_,2));
   if ($opt eq "D") {
     $deg2km = 6371*3.14159/180.;
   } elsif ($opt eq "H") {
     $f1 = $value[0]; $f2 = $value[1];
   } elsif ($opt eq "M") {
     $model = $value[0];
     $s_depth = $value[1] if $#value > 0;
     $flat = 1 if $value[2] eq "f";
     $kappa = 1 if $value[2] eq "k";
   } elsif ($opt eq "N") {
     $m = $value[0];
     $dt = $value[1] if $#value > 0;
     $taper = $value[2] if $#value > 3;  # TODO: value > 1???
   }elsif ($opt eq "R") {
     $r_depth = $value[0];
     $rdep = "_$r_depth";
   }elsif ($opt eq "U") {
     $updn = $value[0];
   } elsif ($opt eq "X") {
     $grt = $value[0];
   } else {
     print STDERR "Error **** Wrong options\n";
     exit(0);
   }
}
my (@dist) = grep(!/^-/,@ARGV);


my $dirnm = "${model}_$s_depth";
mkdir ($dirnm,0777) unless -d $dirnm or $m <= 2;

if ($flat) {
   $s_depth = $r0*log($r0/($r0-$s_depth));
   $r_depth = $r0*log($r0/($r0-$r_depth));
}

# input velocity model
my (@th,@z, @vs, @vp, @rh, @qa, @qb);
my ($src_layer, $rcv_layer);
&read_model();

my $freeSurf = $th[0]>0. || $#th<1 ? 1 : 0;
if ( $freeSurf && ($s_depth<0. || $r_depth<0.) ) {
   print STDERR "Error **** The source or receivers are located in the air.\n";
   exit(0);
}
if ($s_depth<$r_depth) {
   $src_layer = insert_intf($s_depth);
   $rcv_layer = insert_intf($r_depth);
} else {
   $rcv_layer = insert_intf($r_depth);
   $src_layer = insert_intf($s_depth);
}

if ($src_layer==0) {
    $src_layer=1}

my $num_layer = $#th + 1;
$z[0] = 0.0;
for($j=1;$j<$num_layer;$j++){
   $z[$j] = $z[$j-1] + $th[$j-1]
}

for (my $j=0;$j<$num_layer;$j++) {
   printf "%11.4f%11.4f%11.4f%11.4f%10.3e%10.3e\n",$z[$j],$vp[$j],$vs[$j],$rh[$j],$qa[$j],$qb[$j];
}
# compute first arrival times
my (%t0, %sac_com);
&ps_arr();

foreach (@dist) {
    printf "%10.3f%10.3f $dirnm/$_$rdep.grn.\n",$_*$deg2km,$t0{$_};
}

# run GRTM
 open(REFL,"| $grt") or die "couldn't run $grt\n";
 printf REFL "%d $s_depth $r_depth\n",$num_layer;
 for (my $j=0;$j<$num_layer;$j++) {
    printf REFL "%11.4f%11.4f%11.4f%11.4f%10.3e%10.3e\n",$z[$j],$rh[$j],$vs[$j],$vp[$j],$qb[$j],$qa[$j];
    }
    printf REFL "%d $dt $taper $f1 $f2\n",$m;
    printf REFL "%5d\n",$#dist+1;
    foreach (@dist) {
        printf REFL "%10.3f%10.3f $dirnm/$_$rdep.grn.\n",$_*$deg2km,$t0{$_}-$dt*$tb;
        }
        close(REFL);
exit(0) unless $m > 2 and $grt ne "cat";

# save tp and ts into the sac header of Greens' functions
foreach (@dist) {
#   system("sachd $sac_com{$_} f $dirnm/$_$rdep.grn.0 $dirnm/$_$rdep.grn.1 $dirnm/$_$rdep.grn.3 $dirnm/$_$rdep.grn.4 $dirnm/$_$rdep.grn.5");
  system("sacch $sac_com{$_} $dirnm/$_$rdep.grn.0 $dirnm/$_$rdep.grn.1 $dirnm/$_$rdep.grn.3 $dirnm/$_$rdep.grn.4 $dirnm/$_$rdep.grn.5");
}

exit(0);

sub read_model {
   open(MODEL,"$model") or die "could not open $model\n";
   my $fl = 1.;
   my $r = $r0;
   my $i = 0;
   while (<MODEL>){
      ($th[$i], $vs[$i], $vp[$i], $rh[$i], $qb[$i], $qa[$i]) = split;
      $r -= $th[$i];
      $fl = $r0/($r + 0.5*$th[$i]) if $flat;
      $th[$i] *= $fl;
      $vs[$i] *= $fl;
      if ($kappa) {
         $vp[$i] = $vp[$i]*$vs[$i];	# 3rd column is Vp/Vs
      } else {
         $vp[$i] *= $fl;
      }
      if (!$rh[$i] or $rh[$i] > 20.) {	# 4th column is Qs
         $qb[$i] = $rh[$i];
         $rh[$i] = 0.77 + 0.32*$vp[$i];
      }
      $qb[$i] = 500 unless $qb[$i];
      $qa[$i] = 2*$qb[$i] unless $qa[$i];
      $i++;
   }
   close(MODEL);
   $th[$i-1] = 0.;
}

sub insert_intf {
   my ($zs) = @_;
   my $n = $#th + 1;
   my $dep = 0.;
   my $i = 0;
   for(; $i<$n; $i++) {
      $dep += $th[$i];
      last if $dep>$zs || $i==$n-1;
   }
   my $intf = $i;
   return $intf if ($i>0 && $zs==$dep-$th[$i]) || ($i==0 && $zs==0.);
   my $dd = $dep-$zs;
   for($i=$n; $i>$intf; $i--) {
       $th[$i] = $th[$i-1];
       $vs[$i] = $vs[$i-1];
       $vp[$i] = $vp[$i-1];
       $rh[$i] = $rh[$i-1];
       $qa[$i] = $qa[$i-1];
       $qb[$i] = $qb[$i-1];
   }
   $th[$intf]  -= $dd;
   $th[$intf+1] = $dd if $dd>0.;
   if ($th[0]<0.) {
      $s_depth -= $th[0];
      $r_depth -= $th[0];
      $th[0]=0.;
   }
   return $intf+1;
}

sub ps_arr {
   my ($j, $tp, $ts, $pa, $sa, $dn, @aaa);

   # calculate arrival time for P and S
   open(TRAV,"| ../bin/trav > junk.p") or die "couldn't run trav\n";
   printf TRAV "%d %d %d\n", $num_layer,$src_layer,$rcv_layer;
   for ($j=0;$j<$num_layer;$j++) {
      printf TRAV "%11.4f %11.4f\n",$th[$j],$vp[$j];
   }
   printf TRAV "%d\n",$#dist + 1;
   foreach (@dist) {
       printf TRAV "%10.4f\n",$_*$deg2km;
   }
   close(TRAV);
   open(TRAV,"| ../bin/trav > junk.s") or die "couldn't run trav\n";
   printf TRAV "%d %d %d\n", $num_layer,$src_layer,$rcv_layer;
   for ($j=0;$j<$num_layer;$j++) {
      printf TRAV "%11.4f %11.4f\n",$th[$j],$vs[$j];
   }
   printf TRAV "%d\n",$#dist + 1;
   foreach (@dist) {
       printf TRAV "%10.4f\n",$_*$deg2km;
   }
   close(TRAV);

   open(TRAV,"paste junk.p junk.s |");
   $j=0;
   while (<TRAV>) {
     @aaa = split;
     $tp = $aaa[1];
     if ($aaa[2]>$tp && $aaa[3]<1/7.) { # down going Pn
        $pa = $vp[$src_layer]*$aaa[3]; $dn=1;
     } else {
        $pa = $vp[$src_layer]*$aaa[4]; $dn=-1;
     }
     $pa = atan2($pa,$dn*sqrt(abs(1.-$pa*$pa)))*180/3.14159;
     $ts = $aaa[6];
     if ($aaa[7]>$ts && $aaa[8]<1/4.) { # down going Sn
        $sa = $vs[$src_layer]*$aaa[8]; $dn=1;
     } else {
        $sa = $vs[$src_layer]*$aaa[9]; $dn=-1;
     }
     $sa = atan2($sa,$dn*sqrt(abs(1.-$sa*$sa)))*180/3.14159;
   #   $sac_com{$dist[$j]}=sprintf("t1 $tp t2 $ts user1 %6.2f user2 %6.2f",$pa,$sa);
     $sac_com{$dist[$j]}=sprintf("t1=$tp t2=$ts user1=%.2f user2=%.2f",$pa,$sa);
     $t0{$dist[$j]} = $tp;
#    printf "t0 %f\n",$tp;
#    print STDERR "$sac_com{$dist[$j]} $t0{$dist[$j]}\n";
     print STDERR "$tp $ts $pa $sa\n";
     $j++;
   }
   close (TRAV);

}
