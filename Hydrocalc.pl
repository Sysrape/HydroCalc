#!/usr/bin/perl -Tw

# Copyright Michael J G Day, 2010

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use YAML;
use Math::Spline;
# set a constant PI = to pi
use constant PI => 4 * atan2(1, 1);
# set a value for nu, the kinematic viscosity of water
use constant nu => 0.00000131;
# set a value for the acceleration due to gravity
use constant g => 9.81;

#Declare vars for pipe diameter, gross head, pipe length, roughness,
#percentage of flow over Q95
#which are provide on the command line
my ($dia, $hg, $len, $eps, $perc, $limit, $percy, $sigmak) = @ARGV;
# perform a check to see we have the right number of vars passed in and give
# usage information if not.

my $usage = "This script requires 8 variables: Pipe diamter(m), gross head(m),
penstock length(m), pipe friction factor, % of flow allowed above Q95,
Qn for secondary %, % of flow allowed above Qn, Sum of headloss coeffcients.

Something like Hydrocalc.pl 0.5 23 250 0.06 50 60 60 1.15\n";
my $count = @ARGV;
die $usage unless $count == 8;

# Declare three vars for stuffing input into.
my ($hydra, $low, $dyfi);
# declare 2 vars for output
my ($energy,$answer);
# we now need to open the three different flow rate files.

open (my $lowin, '<',"lowflows.csv") or die "can't open lowflows";
open (my $hydrain, '<',"hydra.csv") or die "can't open hydra";
#open (DYFI, '<',"Dyfi.csv") or die "can't open Dyfi";

# We want to stuff the files into a hash of arrays, all nicely cleaned up
# and then w**k with the array as we need to do many passes over the data.

while (<$hydrain>){
	next unless m/[\d\.]+,[\d\.]+,[\d\.]+,[\d\.-]+/;
	chomp $_;
	my @input = split(/,/);
	$hydra->{$input[2]} = $input[1];
}
# we need to create a spline object for these data so we can find the 
my @hexceed = keys %$hydra;
my @hflows = values %$hydra;
my $hex = new Math::Spline (\@hexceed, \@hflows);
while (<$lowin>){
	next unless m/[\d\.]+,[\d\.]/;
	chomp $_;
	my @input = split(/,/);
	$low->{$input[0]} = $input[1];
}
my @lexceed = keys %$low;
my @lflows = values %$low;
my $lex = new Math::Spline (\@lexceed, \@lflows);
# we need a var with a sensible set of shaft speeds in it. Ideally we'd like
# 1500rpm but we can also easily do 2x that, and 3/4 2/3 1/2 1/3 1/4 with 
# a belt drive.
my @speeds = (3000,1500,1125,1000,750,500,375);
# we need to set $answer->{$turbine} to a low value for the first iteration
foreach (@speeds) {
	my $speed = $_;
	my @turbines = qw(pelton turgo cross francis prop);
	foreach (@turbines){ 
		$answer->{$speed}->{'hydra'}->{$_}->{'nrg'} = 0;
		$answer->{$speed}->{'low'}->{$_}->{'nrg'} = 0;
	}
}

# So we want to know the maximum annual energy output of a turbine
# installed on a river with the flows specified in the input files. 
# we need to choose a design flow and then iterate through flows 
# calculating the energy output until we find the maximum output.
# the max flowrate is for exceedence = 1.99%
for(my $Qdesign = 0.01; $Qdesign < $hydra->{'1.99'}; $Qdesign += 0.01){
	# we need to know the exceedence to calculate the power out
	my $exceed = $hex->evaluate($Qdesign);
	# so then we calculate the power output for that flow
	#print "Q: $Qdesign exceed: $exceed\n";
	my ($power,$head) = power($Qdesign,$exceed);
	#warn "$power $head\n";
	# from that we can workout which turbines we might use. We want to step
	# through the @speeds array and call the specific speed sub to give us
	# a list of possible trbines to use.
	my $turbines;
	foreach (@speeds){
		push (@{$turbines->{$_}}, speed($_,$power,$head));
	}
	#print Dump($turbines),"\n";
	# then we step through the generated list of turbines and workout the
	# annual energy output.
	foreach (@speeds){
		my $speed = $_;
		foreach my $turbine (@{$turbines->{$speed}}){
			# We need to set a value for last outside the loop.
			my $last = 100;
			# declare a var to pass the headloss to the user
			my $loss = 0;
			# Then step through the exceedence hash and tot up the energy.
			# we want the array sorted from high % to low
			foreach my $key (sort{$b <=> $a} keys (%$hydra)){
				# the flowrate can't be more than the design flowrate so we use
				# the Tenary operatory to ensure that.
				my $Q = $hydra->{$key} < $Qdesign ? $hydra->{$key} : $Qdesign;
				my ($p,$hn) = power($Q,$key);
				my $eff = eff($Qdesign,$Q,$turbine);
				#warn "Eff:$eff Q:$Q power:$p\n";
				# we want to work out the percentage of time the flow happens
				# so we need to subtract the last % from the current %
				$energy->{$turbine} += (($last-$key)/100)*$p*$eff;
				$last = $key;
				# also store the max head loss in $loss
				$loss = 1 - $hn/$hg if $loss < 1 - $hn/$hg && $hn != 0;
			}
			#print "$turbine: Q: $Qdesign Energy $energy->{$turbine}\n";
			# check to see if we've found a better Design flow and if so set
			# the answer energy and answer flowrate for the turbines in
			# question.
			unless ($answer->{$speed}->{'hydra'}->{$turbine}->{'nrg'}
			> $energy->{$turbine}*8760){
			 	$answer->{$speed}->{'hydra'}->{$turbine}->{'nrg'}
						= $energy->{$turbine}*8760;
				$answer->{$speed}->{'hydra'}->{$turbine}->{'QDesign'}
						= $Qdesign;
				$answer->{$speed}->{'hydra'}->{$turbine}->{'exceed'} = $exceed;
				$answer->{$speed}->{'hydra'}->{$turbine}->{'head loss'} = $loss;
				$energy->{$turbine} = 0;
			}
		}
	}
}
# and then do all that again with the lowflows stuff
#for(my $Qdesign = $low->{'50'}; $Qdesign < $low->{'5'};
for(my $Qdesign = 0.01; $Qdesign < $low->{'5'}; $Qdesign += 0.01){
	my $exceed = $lex->evaluate($Qdesign);
	my ($power,$head) = power($Qdesign,$exceed);
	my $turbines;
	foreach (@speeds){
		push (@{$turbines->{$_}}, speed($_,$power,$head));
	}
	foreach (@speeds){
		my $speed = $_;
		foreach my $turbine (@{$turbines->{$speed}}){
			my $last = 100;
			my $loss = 0;
			foreach my $key (sort{$b <=> $a}keys (%$low)){
				my $Q = $low->{$key} < $Qdesign ? $low->{$key} : $Qdesign;
				my ($p,$hn) = power($Q,$key);
				my $eff = eff($Qdesign,$Q,$turbine);
				$energy->{$turbine} += (($last-$key)/100)*$p*$eff;
				$last = $key;
				$loss = 1 - $hn/$hg if $loss < 1 - $hn/$hg && $hn != 0;
			}
			unless ($answer->{$speed}->{'low'}->{$turbine}->{'nrg'}
				> $energy->{$turbine}*8760){
			 	$answer->{$speed}->{'low'}->{$turbine}->{'nrg'}
					= $energy->{$turbine} * 8760;
				$answer->{$speed}->{'low'}->{$turbine}->{'QDesign'} = $Qdesign;
				$answer->{$speed}->{'low'}->{$turbine}->{'exceed'} = $exceed;
				$answer->{$speed}->{'low'}->{$turbine}->{'head loss'} = $loss;
				$energy->{$turbine} = 0;
			}
		}
	}
}

# print out the answer

print Dump($answer);

# We need a specific speed subroutine that works out the specific speed of
# the turbine and returns what types of turbine would be suitable for that
# specific speed.
sub speed {
	my $rpm = shift;
	my $power = shift;
	my $h = shift;
	my $speed = 1.2*$rpm*$power**0.5/$h**1.5;	
	my @turbines;
	if ($speed > 12 && $speed < 30){push (@turbines,'pelton');}
	if ($speed > 20 && $speed < 70){push (@turbines,'turgo');}
	if ($speed > 20 && $speed < 80){push (@turbines,'cross');}
	if ($speed > 80 && $speed < 400){push (@turbines,'francis');}
	if ($speed > 340 && $speed < 1000){push (@turbines,'prop');}
	return @turbines;
}


# we need a turbine efficiency subroutine that takes a design flowrate,
# an actual flowrate and a turbine type and does a cubic spline on the
# table of part-efficiences returning the effciency for that flowrate
sub eff {
	my $Qdesign = shift;
	my $Q = shift;
	my $turbine = shift;
	# the pelton and the turgo share the same efficiency curve.
	$turbine = 'pelton' if $turbine eq 'turgo';
	# now we need to set up 'tables' for the cubic spline code to work on.
	# these valus have been read from the graph in the Micro Hydro design
	# book pg 156 which plots flow-fration against effciency.
	my $table;
	# first for the pelton/turgo
	push (@{$table->{'pelton'}->{'ff'}},
			(0.07,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0));
	push (@{$table->{'pelton'}->{'eff'}},
			(0,0.68,0.82,0.85,0.86,0.86,0.86,0.85,0.85,0.82,0.8));
	# then for an engineered cross-flow.
	push (@{$table->{'cross'}->{'ff'}},
			(0.07,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0));
	push (@{$table->{'cross'}->{'eff'}},
			(0,0.63,0.75,0.78,0.79,0.80,0.81,0.81,0.79,0.78,0.82));
	# Francis
	push (@{$table->{'francis'}->{'ff'}},
			(0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0));
	push (@{$table->{'francis'}->{'eff'}},
			(0,0.40,0.59,0.70,0.78,0.86,0.91,0.91,0.86));
	# Prop
	push (@{$table->{'prop'}->{'ff'}}, (0.36,0.4,0.5,0.6,0.7,0.8,0.9,1.0));
	push (@{$table->{'prop'}->{'eff'}},
			(0,0.12,0.35,0.50,0.68,0.76,0.85,0.90));
	# we now need to create a Maths::Spline object for the correct turbine
	my $spline=new Math::Spline
			($table->{$turbine}->{'ff'},$table->{$turbine}->{'eff'});
	# calculate the efficiency value for the part-flow in question.
	my $eff = $spline->evaluate($Q/$Qdesign);
	# the spline gives us efficiency values < 0 which is meaningless so 
	# we set those to 0
	return $eff > 0 ? $eff : 0;
}

# We need a subroutine to calculate the power input to the turbine for a
# given flowrate.
sub power {
	my $Q = shift;
	my $exceed = shift;
	# call the flowr subroutine to scale the flow rate based on the flow
	# regime.
	$Q = flowr($Q, $exceed);
	# break out of calc and return 0 if the flowrate is 0
	return (0,0) if $Q == 0;
	# call the darcy sub to work out head loss due to friction
	my $hf = darcy($Q);
	# call the turbulence sub to work out head loss due to valves, bends &c.
	my $ht = turb($Q);
	# so the net head is the gross head minus the losses.
	my $hn = $hg-$ht-$hf ;
	# if the nethead/grosshead is less than 0.9 then we need to consider a
	# fatter pipe.
#	warn 'Warning unaccaptable losses ',1-$hn/$hg,
#									" loss try a fatter pipe \n" 
#		if $hn/$hg < 0.9;
	# now we can calulate the input power to the turbine at this flowrate
	# and return it. This is given by Gamma x Q x h where Gamma is 9.804
	# at 10 degrees C
	return (9.804*$Q*$hn,$hn);
}

# we need to take into account the flow regime allowed. We're not allowed
# any of the Q95 flow and the commandline vars in $perc, $limit, $percy 
# define the % over Q95 and the % over $limit we are allowed to take.
# this subroutine takes a pair of values, the flow rate and the exceedence
# for that flow rate and then modifies $Q to take into account the flow 
# regime and then returns that.
sub flowr {
	my $Q = shift;
	my $exceed = shift;
	$Q = 0 if $exceed >= 95;
	# $limit contains the Qn of the exceedence above which we can take
	# $percy percent. $perc is the percentage we're allowed over Q95
	if ($exceed >= $limit){
		$Q = $Q*$percy/100;
	}else{
		$Q = $Q*$perc/100;
	}
	return $Q;
}

# We want a function to calculate the Reynolds number

sub reynolds {
	my $Q = shift;
	return (4*$Q)/(PI*$dia*nu);
}

# then use the colebrook-white equation to get the Darcy friction factor

sub colebrook {
	my $Q = shift;
	my $Re = reynolds($Q);
	my $f = 1;
	my $fn = 0;
	my $step = 0.1;
	# use a while loop to iteratively solve the c-w equation using steps of
	while ($step > 0.0000001){
		while ($f > $fn){
			$fn = (1/(-2.0*log10($eps/(3.7*$dia)+2.51/($Re*$f**0.5))))**2;
			$f = $f - $step unless $f < $fn;
	#		print "F =$f \n";
		}
	$f += $step;
	$step = $step/10;
	#print "Fn = $fn F = $f\n";
	}
	return $fn;
}

# and the darcy-weisbach equation to get the headloss

sub darcy {
	my $Q = shift;
	my $f = colebrook($Q);
	my $V = $Q/(PI*($dia/2)**2);
	return ($f*$len*$V**2)/($dia*2*g);
}

# and one so we can take log10 

sub log10 {
	my $n = shift;
	return log($n)/log(10);
}

# and one for turbulent losses
sub turb {
	my $Q = shift;
	my $v = (4*$Q)/(PI*$dia**2);
	return $v**2*($sigmak)/(2*g);
}
